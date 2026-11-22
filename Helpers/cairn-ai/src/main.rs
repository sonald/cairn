//! Cairn's AI helper. One process per app; Cairn talks to it over stdin/stdout,
//! one JSON object per line. The helper keeps each conversation's history
//! (including provider-specific reasoning and signatures) and streams one
//! model round per request; Cairn runs the tools and decides when to stop.
//!
//! In (Cairn → helper):
//!   {"type":"ask","conversation":ID,"config":{"protocol":"openai"|"anthropic"|"chatgpt","base_url":S,"model":S,"api_key":S},
//!    "system":S,"tools":[{"name":S,"description":S,"schema":{...}}],"text":S,"trim_above":N}
//!       Creates the conversation on first use (system and tools are fixed then), appends the user text
//!       and runs a round. When the last round's input passed `trim_above` tokens, every earlier tool
//!       result is first replaced by a note saying how to get it back (see `trim`). A first round the
//!       provider rejects as too long is trimmed and sent once more.
//!   {"type":"tool_results","conversation":ID,"results":[{"call_id":S,"content":S}]}
//!       Appends the results of the last round's calls as one message and runs the next round.
//!   Both may carry "round":N, which every event of that round echoes, so late events of a cancelled
//!   round can be told apart.
//!   {"type":"cancel","conversation":ID}   Stops the running round; the conversation stays usable.
//!   {"type":"close","conversation":ID}    Stops it and forgets it.
//!   {"type":"list_models","conversation":ID,"config":{...}}   Asks the endpoint which models it offers
//!       (`model` may be empty); answered with one "models" or "error" event under that ID.
//!
//! Out (helper → Cairn), each carrying "conversation" and "round":
//!   {"type":"text","delta":S} · {"type":"reasoning","delta":S}
//!   {"type":"tool_calls","calls":[{"call_id":S,"name":S,"arguments":{...}}],"input_tokens":N}
//!                                                                            round ended, run these
//!   {"type":"done","input_tokens":N,"output_tokens":N}                        round ended with the answer
//!   {"type":"models","models":[S]}                                           answer to list_models, sorted
//!   {"type":"error","message":S}
//!
//! The API key lives only in memory, for the conversation it came with; nothing is written to disk.

use futures::StreamExt;
use genai::adapter::AdapterKind;
use genai::chat::{
    ChatMessage, ChatOptions, ChatRequest, ChatRole, ChatStreamEvent, ContentPart, StopReason, Tool, ToolResponse,
};
use genai::resolver::{AuthData, Endpoint, ProviderConfig, ServiceTargetResolver};
use genai::{Client, ModelIden, ServiceTarget};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;

#[derive(Deserialize, Clone)]
struct Config {
    protocol: String,
    base_url: String,
    #[serde(default)]
    model: String,
    api_key: String,
}

#[derive(Deserialize)]
struct ToolSpec {
    name: String,
    description: String,
    schema: Value,
}

#[derive(Deserialize)]
struct ToolResult {
    call_id: String,
    content: String,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Request {
    Ask {
        conversation: String,
        config: Config,
        #[serde(default)]
        system: String,
        #[serde(default)]
        tools: Vec<ToolSpec>,
        text: String,
        #[serde(default)]
        round: u64,
        trim_above: Option<i32>,
    },
    ToolResults {
        conversation: String,
        results: Vec<ToolResult>,
        #[serde(default)]
        round: u64,
    },
    Cancel {
        conversation: String,
    },
    Close {
        conversation: String,
    },
    ListModels {
        conversation: String,
        config: Config,
    },
}

struct Conversation {
    config: Config,
    request: ChatRequest,
    round: Option<JoinHandle<()>>,
    /// Input tokens of the last round that finished.
    last_input: i32,
}

type Conversations = Arc<Mutex<HashMap<String, Conversation>>>;
type Out = mpsc::UnboundedSender<Value>;

/// Follows the official SDKs' base-URL conventions: OpenAI-compatible bases
/// already end in the version (`…/v1`, or DeepSeek's bare host); Anthropic
/// bases are the host, and the helper adds `/v1/`.
fn endpoint(config: &Config) -> String {
    // A ChatGPT sign-in token is only ever sent to OpenAI's own API.
    if config.protocol == "chatgpt" {
        return "https://api.openai.com/v1/".to_string();
    }
    let base = config.base_url.trim().trim_end_matches('/');
    if config.protocol == "anthropic" && !base.ends_with("/v1") {
        format!("{base}/v1/")
    } else {
        format!("{base}/")
    }
}

fn adapter_kind(config: &Config) -> AdapterKind {
    match config.protocol.as_str() {
        "anthropic" => AdapterKind::Anthropic,
        // A ChatGPT plan is used through the Responses API only.
        "chatgpt" => AdapterKind::OpenAIResp,
        _ => AdapterKind::OpenAI,
    }
}

fn client(config: &Config) -> genai::Result<Client> {
    let kind = adapter_kind(config);
    let endpoint = endpoint(config);
    let key = config.api_key.clone();
    let resolver = ServiceTargetResolver::from_resolver_fn(
        move |target: ServiceTarget| -> Result<ServiceTarget, genai::resolver::Error> {
            Ok(ServiceTarget {
                endpoint: Endpoint::from_owned(endpoint.clone()),
                auth: AuthData::from_single(key.clone()),
                model: ModelIden::new(kind, target.model.model_name),
            })
        },
    );
    Client::builder().with_service_target_resolver(resolver).build()
}

fn send(out: &Out, conversation: &str, round: u64, mut event: Value) {
    event["conversation"] = json!(conversation);
    event["round"] = json!(round);
    let _ = out.send(event);
}

/// Streams one round and records the assistant's turn in the history.
async fn run_round(conversations: Conversations, out: Out, id: String, round: u64) {
    let send = |out: &Out, id: &str, event: Value| send(out, id, round, event);
    let (config, mut request) = {
        let map = conversations.lock().await;
        let Some(conversation) = map.get(&id) else { return };
        (conversation.config.clone(), conversation.request.clone())
    };
    let mut options = ChatOptions::default()
        .with_capture_content(true)
        .with_capture_tool_calls(true)
        .with_capture_reasoning_content(true)
        .with_capture_usage(true);
    // Anthropic requires a limit, and thinking counts against it: at 8192 a
    // long answer or tool call was cut off mid-way. Every current Claude model
    // allows at least 32000.
    if config.protocol == "anthropic" {
        options = options.with_max_tokens(32000);
    }
    // On api.openai.com genai otherwise asks for `prompt_cache_options`, which the
    // ChatGPT plan route rejects (400 on gpt-6.2-sol, 2026-11-22); a cache key
    // keeps rounds of one conversation cached without it.
    if config.protocol == "chatgpt" {
        options = options.with_prompt_cache_key(id.clone());
    }
    let mut retried = false;
    let end = loop {
        match stream_round(&config, request.clone(), &options, &out, &id, round).await {
            Ok(Some(end)) => break end,
            Ok(None) => return send(&out, &id, json!({"type": "error", "message": "the stream ended without a final event"})),
            // A question's first round may carry a long history: clear the old tool results
            // and try once more. Later rounds would need the current round's thinking edited.
            Err(error) if !retried && too_long(&error.to_string()) && matches!(request.messages.last(), Some(m) if matches!(m.role, ChatRole::User)) => {
                retried = true;
                let mut map = conversations.lock().await;
                let Some(conversation) = map.get_mut(&id) else { return };
                conversation.request = trim(conversation.request.clone(), &config.protocol);
                request = conversation.request.clone();
            }
            Err(error) => return send(&out, &id, json!({"type": "error", "message": error.to_string()})),
        }
    };
    let usage = end.captured_usage.clone();
    let tokens = |f: fn(&genai::chat::Usage) -> Option<i32>| usage.as_ref().and_then(f).unwrap_or(0);
    let truncated = matches!(end.captured_stop_reason, Some(StopReason::MaxTokens(_)));
    let calls: Vec<Value> = end
        .captured_tool_calls()
        .unwrap_or_default()
        .into_iter()
        .map(|call| json!({"call_id": call.call_id, "name": call.fn_name, "arguments": call.fn_arguments}))
        .collect();
    let message = if calls.is_empty() {
        let reasoning = end.captured_reasoning_content.clone();
        end.captured_into_first_text().map(|text| ChatMessage::assistant(text).with_reasoning_content(reasoning))
    } else {
        end.into_assistant_message_for_tool_use()
    };
    {
        let mut map = conversations.lock().await;
        let Some(conversation) = map.get_mut(&id) else { return };
        if let Some(message) = message {
            conversation.request = conversation.request.clone().append_message(message);
        }
        conversation.round = None;
        conversation.last_input = tokens(|u| u.prompt_tokens);
    }
    if calls.is_empty() {
        send(&out, &id, json!({
            "type": "done",
            "input_tokens": tokens(|u| u.prompt_tokens),
            "output_tokens": tokens(|u| u.completion_tokens),
        }));
    } else if truncated {
        // A call cut off at the limit has incomplete arguments; running it would
        // act on whatever part arrived. The next ask drops the unanswered call.
        send(&out, &id, json!({"type": "error", "message": "the model's reply was cut off at the output limit"}));
    } else {
        send(&out, &id, json!({"type": "tool_calls", "calls": calls, "input_tokens": tokens(|u| u.prompt_tokens)}));
    }
}

/// Streams one request, forwarding text and reasoning as they come.
async fn stream_round(
    config: &Config, request: ChatRequest, options: &ChatOptions, out: &Out, id: &str, round: u64,
) -> genai::Result<Option<genai::chat::StreamEnd>> {
    let send = |event: Value| send(out, id, round, event);
    let mut stream = client(config)?.exec_chat_stream(&config.model, request, Some(options)).await?.stream;
    while let Some(event) = stream.next().await {
        match event? {
            ChatStreamEvent::Chunk(chunk) => send(json!({"type": "text", "delta": chunk.content})),
            ChatStreamEvent::ReasoningChunk(chunk) => send(json!({"type": "reasoning", "delta": chunk.content})),
            ChatStreamEvent::End(end) => return Ok(Some(end)),
            _ => {}
        }
    }
    Ok(None)
}

/// Whether the provider refused the request for being longer than the model's context.
/// ponytail: matched on the error text, which genai passes through; add a phrase when a
/// provider words it differently.
fn too_long(message: &str) -> bool {
    let message = message.to_lowercase();
    ["prompt is too long", "context length", "context_length", "context window", "maximum context"]
        .iter()
        .any(|phrase| message.contains(phrase))
}

const CLEARED: &str = "[This result was cleared to keep the conversation short. Make the same call again to see it.]";

/// Replaces every tool result with `CLEARED`. On Anthropic it also drops every thinking
/// block: Claude binds each block to everything sent before it, so after an edit the later
/// blocks are rejected (a 400 on claude-haiku-5-5 with the check on, 2026-11-21), and blocks
/// can only be removed from the front, so all go. Other protocols keep their reasoning.
fn trim(mut request: ChatRequest, protocol: &str) -> ChatRequest {
    let anthropic = protocol == "anthropic";
    for message in &mut request.messages {
        let parts = std::mem::take(&mut message.content).into_parts();
        let kept: Vec<ContentPart> = parts
            .into_iter()
            .filter_map(|part| match part {
                ContentPart::ToolResponse(mut response) => {
                    response.content = CLEARED.to_string();
                    Some(ContentPart::ToolResponse(response))
                }
                ContentPart::ReasoningContent(_) | ContentPart::ThoughtSignature(_) if anthropic => None,
                ContentPart::Custom(custom)
                    if anthropic
                        && matches!(custom.data.get("type").and_then(Value::as_str), Some("thinking" | "redacted_thinking")) =>
                {
                    None
                }
                ContentPart::ToolCall(mut call) if anthropic => {
                    call.thought_signatures = None;
                    Some(ContentPart::ToolCall(call))
                }
                other => Some(other),
            })
            .collect();
        message.content = kept.into();
    }
    request
}

async fn list_models(out: Out, id: String, config: Config) {
    let provider = ProviderConfig::from_endpoint(Endpoint::from_owned(endpoint(&config)))
        .with_auth(AuthData::from_single(config.api_key.clone()));
    let models = async { Client::new()?.all_model_names(adapter_kind(&config), provider).await }.await;
    match models {
        Ok(mut models) => {
            models.sort();
            models.dedup();
            send(&out, &id, 0, json!({"type": "models", "models": models}));
        }
        Err(error) => send(&out, &id, 0, json!({"type": "error", "message": error.to_string()})),
    }
}

/// A round left half done (cancelled while Cairn ran the tools) would leave
/// tool calls without results, which every provider rejects on the next ask.
fn drop_unanswered_calls(request: ChatRequest) -> ChatRequest {
    let mut request = request;
    if let Some(last) = request.messages.last()
        && matches!(last.role, ChatRole::Assistant)
        && !last.content.tool_calls().is_empty()
    {
        request.messages.pop();
    }
    request
}

async fn handle(line: &str, conversations: &Conversations, out: &Out) {
    let request: Request = match serde_json::from_str(line) {
        Ok(request) => request,
        Err(error) => return send(out, "", 0, json!({"type": "error", "message": format!("bad request: {error}")})),
    };
    let mut map = conversations.lock().await;
    let (id, round) = match request {
        Request::Ask { conversation, config, system, tools, text, round, trim_above } => {
            let entry = map.entry(conversation.clone()).or_insert_with(|| {
                let tools = tools
                    .into_iter()
                    .map(|t| Tool::new(t.name).with_description(t.description).with_schema(t.schema))
                    .collect::<Vec<_>>();
                let mut request = ChatRequest::default().with_tools(tools);
                if !system.is_empty() {
                    request = request.with_system(system);
                }
                Conversation { config: config.clone(), request, round: None, last_input: 0 }
            });
            if let Some(round) = entry.round.take() {
                round.abort();
            }
            entry.config = config;
            let mut request = drop_unanswered_calls(entry.request.clone());
            if trim_above.is_some_and(|limit| entry.last_input > limit) {
                request = trim(request, &entry.config.protocol);
                entry.last_input = 0;
            }
            entry.request = request.append_message(ChatMessage::user(text));
            (conversation, round)
        }
        Request::ToolResults { conversation, results, round } => {
            let Some(entry) = map.get_mut(&conversation) else {
                return send(out, &conversation, round, json!({"type": "error", "message": "unknown conversation"}));
            };
            let responses: Vec<ToolResponse> =
                results.into_iter().map(|r| ToolResponse::new(r.call_id, r.content)).collect();
            // Parallel calls' results must travel as one message (Anthropic rejects them split).
            entry.request = entry.request.clone().append_message(ChatMessage::from(responses));
            (conversation, round)
        }
        Request::Cancel { conversation } => {
            if let Some(round) = map.get_mut(&conversation).and_then(|c| c.round.take()) {
                round.abort();
            }
            return;
        }
        Request::Close { conversation } => {
            if let Some(round) = map.remove(&conversation).and_then(|c| c.round) {
                round.abort();
            }
            return;
        }
        Request::ListModels { conversation, config } => {
            tokio::spawn(list_models(out.clone(), conversation, config));
            return;
        }
    };
    let task = tokio::spawn(run_round(conversations.clone(), out.clone(), id.clone(), round));
    if let Some(entry) = map.get_mut(&id) {
        entry.round = Some(task);
    }
}

#[tokio::main]
async fn main() {
    let (out, mut outgoing) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(event) = outgoing.recv().await {
            let mut line = event.to_string();
            line.push('\n');
            if stdout.write_all(line.as_bytes()).await.is_err() || stdout.flush().await.is_err() {
                break;
            }
        }
    });
    let conversations: Conversations = Arc::default();
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    // Cairn closing stdin (or quitting) ends the helper.
    while let Ok(Some(line)) = lines.next_line().await {
        if !line.trim().is_empty() {
            handle(&line, &conversations, &out).await;
        }
    }
    drop(out);
    let _ = writer.await;
}
