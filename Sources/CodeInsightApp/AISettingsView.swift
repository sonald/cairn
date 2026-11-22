import AppKit
import CodeInsightAI
import SwiftUI

/// Settings → AI: the one provider profile. The key goes to the Keychain;
/// "Test connection" asks the endpoint for a tool call, which questions about
/// code need. The endpoint's model list is fetched once there is a key, to
/// choose from; any name can still be typed. The Jev key, for Overview
/// scoring, is a Keychain item of its own. The ChatGPT protocol replaces the
/// address and key with signing in to a ChatGPT account.
struct AISettingsView: View {
    @State private var settings = AIProviderSettings.load()
    @State private var keyDraft = ""
    @State private var hasKey = AIKeychain.exists()
    @State private var checking = false
    @State private var checkResult: String?
    @State private var checkPassed = false
    @State private var confirmsRevoke = false
    @State private var models: [String] = []
    @State private var modelsError: String?
    @State private var loadingModels = false
    /// Bumped on every save, so replacing a saved key fetches the list again.
    @State private var keyRevision = 0
    @State private var jevKeyDraft = ""
    @State private var hasJevKey = AIKeychain.jev.exists()
    @State private var signedIn = ChatGPTAccount.isSignedIn()
    @State private var signingIn: Task<Void, Never>?
    @State private var signInError: String?
    /// The first sign-in says once that requests now use the ChatGPT plan.
    @AppStorage("ai.chatgpt.welcomed") private var welcomed = false
    @State private var showsWelcome = false

    private var isChatGPT: Bool { settings.wireProtocol == .chatGPT }

    /// What the model list depends on; a change fetches it again.
    private var modelSource: String {
        [settings.wireProtocol.rawValue, settings.host ?? "", settings.baseURL, String(isChatGPT ? signedIn : hasKey),
         String(keyRevision)].joined(separator: "\n")
    }

    var body: some View {
        Form {
            Picker(localized("settings.ai.protocol"), selection: $settings.wireProtocol) {
                Text(localized("settings.ai.protocol.openai")).tag(AIProviderSettings.WireProtocol.openAI)
                Text(localized("settings.ai.protocol.anthropic")).tag(AIProviderSettings.WireProtocol.anthropic)
                Text(localized("settings.ai.protocol.chatgpt")).tag(AIProviderSettings.WireProtocol.chatGPT)
            }
            if isChatGPT {
                chatGPTAccount
            } else {
                TextField(localized("settings.ai.baseURL"), text: $settings.baseURL,
                          prompt: Text(AIProviderSettings.defaultBaseURL(for: settings.wireProtocol)))
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                TextField(localized("settings.ai.model"), text: $settings.model)
                    .font(.system(.body, design: .monospaced))
                if loadingModels {
                    ProgressView().controlSize(.small)
                } else if !models.isEmpty {
                    Menu(localized("settings.ai.models.choose")) {
                        ForEach(models, id: \.self) { name in
                            Button {
                                settings.model = name
                            } label: {
                                if name == settings.model { Label(name, systemImage: "checkmark") } else { Text(name) }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            if loadingModels {
                Text(localized("settings.ai.models.loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let modelsError {
                Label(localizedFormat("settings.ai.models.failed", modelsError), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if !isChatGPT { HStack {
                SecureField(localized("settings.ai.key"), text: $keyDraft,
                            prompt: Text(hasKey ? localized("settings.ai.key.saved") : ""))
                    .onSubmit(saveKey)
                Button(localized("settings.ai.key.save"), action: saveKey)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasKey {
                    Button(localized("settings.ai.key.remove")) {
                        AIKeychain.write("")
                        hasKey = false
                    }
                }
            } }
            HStack(spacing: 10) {
                Button(localized("settings.ai.check")) { Task { await check() } }
                    .disabled(checking || !settings.isComplete)
                if checking { ProgressView().controlSize(.small) }
                if let checkResult {
                    Label(checkResult, systemImage: checkPassed ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(checkPassed ? Color.secondary : Color.orange)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Section {
                Text(localized("settings.ai.privacy"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(localized("settings.ai.consent.revoke")) { confirmsRevoke = true }
                    .confirmationDialog(localized("settings.ai.consent.revoke.confirm"),
                                        isPresented: $confirmsRevoke, titleVisibility: .visible) {
                        Button(localized("settings.ai.consent.revoke"), role: .destructive) {
                            AIConsentStore().revokeAll()
                        }
                        Button(localized("settings.cancel"), role: .cancel) {}
                    }
            }
            Section(localized("settings.jev.section")) {
                HStack {
                    SecureField(localized("settings.jev.key"), text: $jevKeyDraft,
                                prompt: Text(hasJevKey ? localized("settings.ai.key.saved") : ""))
                        .onSubmit(saveJevKey)
                    Button(localized("settings.ai.key.save"), action: saveJevKey)
                        .disabled(jevKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasJevKey {
                        Button(localized("settings.ai.key.remove")) {
                            AIKeychain.jev.write("")
                            hasJevKey = false
                        }
                    }
                }
                Text(localized(hasJevKey ? "settings.jev.key.configured" : "settings.jev.key.missing"))
                    .foregroundStyle(.secondary)
                Text(localized("settings.jev.privacy"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .alert(localized("settings.chatgpt.welcome.title"), isPresented: $showsWelcome) {
            Button(localized("settings.chatgpt.welcome.ok")) {}
        } message: {
            Text(localized("settings.chatgpt.welcome.body"))
        }
        .task(id: modelSource) { await loadModels() }
        .onChange(of: settings) { _, new in
            new.save()
            checkResult = nil
        }
    }

    /// Signed out: the sign-in button. Signed in: the account, its usage page and signing out.
    @ViewBuilder private var chatGPTAccount: some View {
        HStack(spacing: 10) {
            if signedIn {
                Label(localizedFormat("settings.chatgpt.connected", ChatGPTAccount.email ?? "ChatGPT"),
                      systemImage: "checkmark.circle")
                Spacer()
                Link(localized("settings.chatgpt.usage"), destination: ChatGPTAccount.usageURL)
                Button(localized("settings.chatgpt.signOut")) {
                    Task {
                        await ChatGPTAccount.signOut()
                        signedIn = false
                        checkResult = nil
                    }
                }
            } else if let signingIn {
                ProgressView().controlSize(.small)
                Text(localized("settings.chatgpt.waiting")).foregroundStyle(.secondary)
                Spacer()
                Button(localized("settings.cancel")) { signingIn.cancel() }
            } else {
                Button(localized("settings.chatgpt.signIn"), action: signIn)
            }
        }
        if let signInError {
            Label(signInError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Color.orange)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        Text(localized("settings.chatgpt.about"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func signIn() {
        signInError = nil
        signingIn = Task {
            do {
                try await ChatGPTAccount.signIn { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                signedIn = true
                checkResult = nil
                NSApp.activate()
                if !welcomed {
                    welcomed = true
                    showsWelcome = true
                }
            } catch is CancellationError {
            } catch {
                signInError = Self.describe(error)
            }
            signingIn = nil
        }
    }

    /// The ChatGPT failures that have text of their own; others as they came.
    static func describe(_ error: Error) -> String { describe(String(describing: error)) }

    static func describe(_ message: String) -> String {
        switch message {
        case "chatgptSignIn": localized("ai.error.chatgptSignIn")
        case "chatgptPlanNotShared": localized("ai.error.chatgptPlanNotShared")
        case "access_denied": localized("settings.chatgpt.denied")
        case let other: other
        }
    }

    private func loadModels() async {
        if isChatGPT { return await loadChatGPTModels() }
        guard settings.host != nil, hasKey || settings.isLocal else {
            models = []
            modelsError = nil
            loadingModels = false
            return
        }
        loadingModels = true
        modelsError = nil
        // A cancelled task (typing in Base URL restarts it) leaves the indicator to its successor.
        defer { if !Task.isCancelled { loadingModels = false } }
        // Wait for a pause in typing.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        guard let helper = try? AIHelper.shared() else {
            models = []
            modelsError = localized("ai.helper.missing")
            return
        }
        // A rebuilt app may have to ask for Keychain access; keep the window responsive meanwhile.
        let key = await Task.detached { AIKeychain.read() ?? "" }.value
        let result = await AIConversationModel.listModels(settings, apiKey: key, helper: helper)
        guard !Task.isCancelled else { return }
        switch result {
        case .models(let names):
            models = names
            modelsError = nil
        case .failed(let message):
            models = []
            modelsError = message == "timeout" ? localized("settings.ai.check.timeout") : message
        }
    }

    private func loadChatGPTModels() async {
        guard signedIn else {
            models = []
            modelsError = nil
            loadingModels = false
            return
        }
        loadingModels = true
        modelsError = nil
        defer { if !Task.isCancelled { loadingModels = false } }
        do {
            let names = try await ChatGPTAccount.models()
            guard !Task.isCancelled else { return }
            models = names
            // The account decides which models exist; start from its first.
            if settings.model.isEmpty || !names.contains(settings.model), let first = names.first { settings.model = first }
        } catch {
            guard !Task.isCancelled else { return }
            models = []
            modelsError = Self.describe(error)
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        hasKey = AIKeychain.write(key)
        keyRevision += 1
        keyDraft = ""
        checkResult = nil
    }

    private func saveJevKey() {
        let key = jevKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        hasJevKey = AIKeychain.jev.write(key)
        jevKeyDraft = ""
    }

    private func check() async {
        saveKey()
        checking = true
        defer { checking = false }
        let outcome: AIConversationModel.ConnectionCheck
        do {
            guard let helper = try AIHelper.shared() else {
                checkPassed = false
                checkResult = localized("ai.helper.missing")
                return
            }
            let key = isChatGPT ? try await ChatGPTAccount.accessToken() : AIKeychain.read() ?? ""
            outcome = await AIConversationModel.checkConnection(settings, apiKey: key, helper: helper)
        } catch {
            outcome = .failed(Self.describe(error))
        }
        switch outcome {
        case .ok:
            checkPassed = true
            checkResult = localized("settings.ai.check.ok")
        case .noToolCalls:
            checkPassed = false
            checkResult = localized("settings.ai.check.noTools")
        case .failed(let message):
            checkPassed = false
            checkResult = message == "timeout" ? localized("settings.ai.check.timeout") : message
        }
    }
}
