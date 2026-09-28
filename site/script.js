// Small progressive enhancements; the page reads fine without them.

// Hero trail: click to replay the drawing animation.
const trail = document.getElementById("trail");
trail?.addEventListener("click", () => {
  trail.querySelectorAll(".trail-cover, .stop").forEach(el => {
    el.style.animation = "none";
    void el.getBoundingClientRect();
    el.style.animation = "";
  });
});

// Reader demo: real output from `codeinsight callers`, `resolve` and `exact-def`
// on sonald/knuth-rs @ fac975a (crates/knuth-agent/src/harness.rs), Safe mode.
const EXACT = "rust-analyzer ✓ same target";
const SAFE = "Safe · build scripts & proc macros off";
const SYMBOLS = {
  running_invocation: {
    results: [["handle_tool_input_prepared", "harness.rs:883", "ok", "strong"], ["handle_tool_result_finalized", "harness.rs:1002", "ok", "strong"], ["handle_tool_finished", "harness.rs:1066", "ok", "strong"]],
    evidence: [["index", "strong · direct"], ["target", "harness.rs:856"], ["exact", EXACT], ["mode", SAFE]]
  },
  update_invocation_state: {
    results: [["handle_tool_input_prepared", "harness.rs:973", "ok", "strong"], ["handle_tool_finished", "harness.rs:1085", "ok", "strong"]],
    evidence: [["index", "strong · direct"], ["target", "harness.rs:833"], ["exact", EXACT], ["mode", SAFE]]
  },
  handle_tool_result_finalized: {
    results: [["handle", "harness.rs:300", "ok", "strong"], ["handle_tool_finished", "harness.rs:1095", "ok", "strong"]],
    evidence: [["index", "strong · direct"], ["target", "harness.rs:996"], ["exact", EXACT], ["mode", SAFE]]
  },
  hook_context: {
    results: [["prepare_context", "harness.rs:467", "ok", "strong"], ["prepare_tool_calls", "harness.rs:682", "ok", "strong"], ["handle_tool_finished", "harness.rs:1105", "ok", "strong"]],
    evidence: [["index", "strong · direct"], ["target", "harness.rs:341"], ["exact", EXACT], ["mode", SAFE]]
  },
  after_tool_use: {
    results: [["after_hooks_can_rewrite_the_result", "hooks/registry.rs:427", "warn", "probable"], ["after_hooks_see_the_executed_tool_call", "hooks/registry.rs:460", "warn", "probable"], ["handle_tool_finished", "harness.rs:1108", "no", "possible"]],
    evidence: [["index", "possible · dynamic dispatch"], ["why", "matched by method name only"], ["target", "hooks/registry.rs:113"], ["exact", "rust-analyzer ✓ confirms target"], ["mode", SAFE]]
  }
};
const results = document.getElementById("results");
const inspector = document.getElementById("inspector");
const symbols = document.querySelectorAll(".sym");
function showSymbol(name) {
  const data = SYMBOLS[name];
  symbols.forEach(s => s.setAttribute("aria-pressed", String(s.dataset.s === name)));
  results.innerHTML = data.results.map(([caller, location, kind, label], i) =>
    `<div class="res" style="animation-delay:${i * 60}ms"><b>${caller}</b><span class="badge ${kind}">${label}</span><small>${location}</small></div>`).join("");
  inspector.innerHTML = `<h3>INSPECTOR · ${name}</h3><dl>` +
    data.evidence.map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join("") + "</dl>";
}
symbols.forEach(s => s.addEventListener("click", () => showSymbol(s.dataset.s)));
if (results) showSymbol("after_tool_use");

// Snapshot timeline: the real history of HookContext in sonald/knuth-rs
// (crates/knuth-agent/src/hooks/types.rs); the last entry is main @ fac975a.
const HISTORY = [
  ["pub struct HookContext {", "    pub session_id: SessionId,", "    pub invocation_id: Option<ToolInvocationId>,", "    pub cancel: CancellationToken,", "}"],
  ["pub struct HookContext {", "    pub session_id: SessionId,", "    /// available only for tool use hooks", "    pub invocation_id: Option<ToolInvocationId>,", "    pub cancel: CancellationToken,", "}"],
  ["pub struct HookContext {", "    pub session_id: SessionId,", "    /// available only for tool use hooks", "    pub invocation_id: Option<ToolInvocationId>,", "    pub workspace: PathBuf,", "    pub cancel: CancellationToken,", "}"],
  ["pub struct HookContext {", "    pub session_id: SessionId,", "    /// available only for tool use hooks", "    pub invocation_id: Option<ToolInvocationId>,", "    pub workspace: PathBuf,", "    pub cancel: CancellationToken,", "}"]
];
const commits = document.querySelectorAll(".commit");
const escapeHTML = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
function showCommit(i) {
  const head = HISTORY[HISTORY.length - 1];
  const old = HISTORY[i];
  document.getElementById("left").innerHTML = old.map(l => `<div${head.includes(l) ? "" : ' class="d"'}>${escapeHTML(l)}</div>`).join("");
  document.getElementById("right").innerHTML = head.map(l => `<div${old.includes(l) ? "" : ' class="a"'}>${escapeHTML(l)}</div>`).join("");
  document.getElementById("left-sha").textContent = commits[i].querySelector(".sha").textContent;
  commits.forEach((c, j) => c.setAttribute("aria-pressed", String(j === i)));
}
commits.forEach(c => c.addEventListener("click", () => showCommit(+c.dataset.i)));
if (commits.length) showCommit(0);
