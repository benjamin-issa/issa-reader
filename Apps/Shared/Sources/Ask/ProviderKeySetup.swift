#if !os(tvOS)
import IssaAsk
import IssaCore
import IssaUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// "Your own AI keys", in Settings › Advanced.
///
/// Advanced because it is for the few: a reader who has an Anthropic or OpenAI
/// account and wants Ask answered there. Nothing about Ask changes until a key
/// is added here — no picker, no new wording — and adding one goes through a
/// screen that says what will be sent, to whom, and on whose bill, with
/// nothing saved until the reader agrees (App Review 5.1.2(i)).
struct ProviderKeyRows: View {
    @Environment(AskCoordinator.self) private var coordinator

    var body: some View {
        Text("Your own AI accounts")
            .overlineStyle()
        ForEach(ProviderKind.allCases, id: \.self) { kind in
            NavigationLink {
                ProviderKeyScreen(kind: kind).settingsPage()
            } label: {
                LabeledContent {
                    Text(coordinator.keys.registration(for: kind)?.model.displayName
                        ?? (kind == .openAI ? "Sign in or add key…" : "Add key…"))
                        .foregroundStyle(Palette.inkTertiary)
                } label: {
                    Text(kind.displayName)
                }
            }
            .accessibilityIdentifier("settings.aiKey.\(kind.rawValue)")
        }
        Text("Use your own Anthropic key, OpenAI key, or ChatGPT subscription for “Ask about this book”. Questions go there only when you choose it.")
            .font(Typography.footnote)
            .foregroundStyle(Palette.inkTertiary)
    }
}

/// One provider's key: added, or how it is set up and the way to change it.
struct ProviderKeyScreen: View {
    let kind: ProviderKind
    @Environment(AskCoordinator.self) private var coordinator
    @State private var replacing = false

    var body: some View {
        Group {
            if let registration = coordinator.keys.registration(for: kind), !replacing {
                ManageProviderKey(kind: kind, registration: registration, onReplace: { replacing = true })
            } else {
                AddProviderKey(kind: kind, onDone: { replacing = false })
            }
        }
        .navigationTitle(kind.displayName)
    }
}

// MARK: - Adding a key

/// Paste a key (or sign in with ChatGPT for OpenAI), check, choose a model,
/// agree. Nothing is saved before the last step.
private struct AddProviderKey: View {
    let kind: ProviderKind
    let onDone: () -> Void
    @Environment(AskCoordinator.self) private var coordinator

    private enum Credential: Equatable {
        case apiKey(String)
        case chatGPTOAuth(OpenAIOAuthSession)

        var isOAuth: Bool {
            if case .chatGPTOAuth = self { return true }
            return false
        }
    }

    private enum Step: Equatable {
        case enter
        case checking
        case signingInWithChatGPT
        case choose([ProviderModel])
        case consent(ProviderModel)
    }

    @State private var key = ""
    /// The credential the provider accepted. Saved in place of the field, which
    /// could be edited after the check.
    @State private var checked: Credential?
    @State private var step: Step = .enter
    @State private var problem: String?
    @State private var chosen: ProviderModel?

    private var isBusy: Bool {
        step == .checking || step == .signingInWithChatGPT
    }

    var body: some View {
        Form {
            switch step {
            case .enter, .checking, .signingInWithChatGPT:
                enter
            case let .choose(models):
                ProviderModelList(kind: kind, models: models, chosen: $chosen, isChatGPTPlan: checked?.isOAuth == true)
                Section {
                    Button("Continue") {
                        if let chosen { step = .consent(chosen) }
                    }
                    .disabled(chosen == nil)
                    .accessibilityIdentifier("aiKey.continue")
                }
            case let .consent(model):
                consent(model)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var enter: some View {
        if kind == .openAI {
            Section {
                Button {
                    signInWithChatGPT()
                } label: {
                    if step == .signingInWithChatGPT {
                        HStack(spacing: Metrics.spacing8) {
                            ProgressView()
                            Text("Signing in with ChatGPT…")
                        }
                    } else {
                        Label("Continue with ChatGPT", systemImage: "person.badge.key")
                    }
                }
                .disabled(isBusy)
                .accessibilityIdentifier("aiKey.signInWithChatGPT")
            } header: {
                Text("ChatGPT subscription")
            } footer: {
                Text("Use your ChatGPT Plus or Pro plan without an API key. Your session stays on this \(AskDevice.noun) only.")
            }
        }

        Section {
            SecureField("API key", text: $key)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .textContentType(.password)
                .disabled(isBusy)
                .accessibilityIdentifier("aiKey.field")
            PasteButton(payloadType: String.self) { strings in
                guard let pasted = strings.first else { return }
                Task { @MainActor in
                    key = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    ProviderKeyClipboard.clearAfterPaste()
                }
            }
            .disabled(isBusy)
            .accessibilityIdentifier("aiKey.paste")
            Button {
                check()
            } label: {
                if step == .checking {
                    ProgressView()
                } else {
                    Text("Check key")
                }
            }
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            .accessibilityIdentifier("aiKey.check")
            if let problem {
                Text(problem)
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("aiKey.problem")
            }
        } header: {
            if kind == .openAI {
                Text("Or use an API key")
            }
        } footer: {
            Text(kind.keyInstructions + " The key is kept on this \(AskDevice.noun) only.")
        }
    }

    private func signInWithChatGPT() {
        problem = nil
        step = .signingInWithChatGPT
        Task {
            do {
                let session = try await coordinator.signInWithChatGPT()
                let models = try await coordinator.models(for: .openAI, key: session.accessToken)
                checked = .chatGPTOAuth(session)
                chosen = models.first { $0.id == kind.preferredModelID } ?? models.first
                step = .choose(models)
            } catch let failure as OpenAIOAuth.Failure {
                problem = failure == .cancelled ? nil : failure.userMessage
                step = .enter
            } catch {
                problem = error.message(kind)
                step = .enter
            }
        }
    }

    private func check() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        problem = nil
        step = .checking
        Task {
            do {
                let models = try await coordinator.models(for: kind, key: candidate)
                checked = .apiKey(candidate)
                chosen = models.first { $0.id == kind.preferredModelID } ?? models.first
                step = .choose(models)
            } catch {
                problem = error.message(kind)
                step = .enter
            }
        }
    }

    /// What will happen, in full, before anything is saved: what is sent, to
    /// whom, when, and on whose bill. What the provider does with it is the
    /// provider's to say, so the screen points at its policy rather than
    /// speaking for it.
    private func consent(_ model: ProviderModel) -> some View {
        let isOAuth = checked?.isOAuth == true
        return Section {
            if isOAuth {
                Text("When you ask with ChatGPT, your question and the text of the book up to where you've read are sent to OpenAI.")
                Text("OpenAI decides how that is stored and used. Issa Reader has no control over it. Read OpenAI's privacy policy before you agree.")
                Text("Nothing goes to OpenAI unless you choose it for a question or make it your default. Questions count toward your ChatGPT plan's shared usage limit.")
            } else {
                Text("When you ask with this key, your question and the text of the book up to where you've read are sent to \(kind.displayName).")
                Text("\(kind.displayName) decides how that is stored and used. Issa Reader has no control over it. Read \(kind.displayName)'s privacy policy before you agree.")
                Text("Nothing goes to \(kind.displayName) unless you choose it for a question or make it your default. Each question is charged to your \(kind.displayName) account.")
            }
            Link("\(kind.displayName)'s privacy policy", destination: kind.privacyPolicyURL)
                .foregroundStyle(Palette.tangerine)
            Button(isOAuth ? "Agree and Connect ChatGPT" : "Agree and Add Key") {
                let saved: Bool
                switch checked {
                case let .apiKey(value) where !value.isEmpty:
                    saved = coordinator.keys.register(kind, key: value, model: model)
                case let .chatGPTOAuth(session):
                    saved = coordinator.keys.registerOAuth(kind, session: session, model: model)
                default:
                    saved = false
                }
                if saved {
                    key = ""
                    checked = nil
                    onDone()
                } else {
                    problem = isOAuth
                        ? "Your ChatGPT sign-in couldn't be saved on this \(AskDevice.noun). Try again."
                        : "The key couldn't be saved on this \(AskDevice.noun). Try again."
                    step = .enter
                }
            }
            .accessibilityIdentifier("aiKey.agree")
            Button("Cancel", role: .cancel) {
                key = ""
                checked = nil
                step = .enter
                onDone()
            }
            .accessibilityIdentifier("aiKey.cancel")
        } header: {
            Text(isOAuth ? "Before you connect ChatGPT" : "Before you add this key")
        }
    }
}

// MARK: - A key already added

private struct ManageProviderKey: View {
    let kind: ProviderKind
    let registration: AIKeys.Registration
    let onReplace: () -> Void
    @Environment(AskCoordinator.self) private var coordinator
    @Environment(PlaybackSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false

    private var isOAuth: Bool { registration.authMethod == .chatGPTOAuth }

    var body: some View {
        Form {
            Section {
                if isOAuth {
                    LabeledContent("Account", value: coordinator.keys.oauthAccountEmail(for: kind) ?? "ChatGPT")
                }
                NavigationLink {
                    ChangeProviderModel(kind: kind, current: registration.model, isChatGPTPlan: isOAuth).settingsPage()
                } label: {
                    LabeledContent("Model", value: registration.model.displayName)
                }
                .accessibilityIdentifier("aiKey.changeModel")
                Button(isOAuth ? "Reconnect or Use API Key…" : "Replace Key…", action: onReplace)
                    .accessibilityIdentifier("aiKey.replace")
            } footer: {
                if isOAuth {
                    Text("Questions you send to OpenAI go there with the book so far, using your ChatGPT plan.")
                } else {
                    Text("Questions you send to \(kind.displayName) go there with the book so far, billed to your account.")
                }
            }
            Section {
                if confirmingRemoval {
                    Text(isOAuth
                        ? "Sign out of ChatGPT on this \(AskDevice.noun)? Questions can't be sent to OpenAI until you sign in or add a key again."
                        : "Remove the \(kind.displayName) key from this \(AskDevice.noun)? Questions can't be sent to \(kind.displayName) until you add one again.")
                    Button(isOAuth ? "Sign Out" : "Remove Key", role: .destructive) {
                        coordinator.removeKey(kind)
                        if settings.askDefaultProvider == kind.rawValue { settings.askDefaultProvider = nil }
                        dismiss()
                    }
                    .accessibilityIdentifier("aiKey.remove.confirm")
                    Button("Keep It") { confirmingRemoval = false }
                } else {
                    Button(isOAuth ? "Sign Out of ChatGPT…" : "Remove Key…", role: .destructive) { confirmingRemoval = true }
                        .accessibilityIdentifier("aiKey.remove")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The models the credential can use, read again from the provider.
private struct ChangeProviderModel: View {
    let kind: ProviderKind
    let current: ProviderModel
    var isChatGPTPlan: Bool = false
    @Environment(AskCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var models: [ProviderModel]?
    @State private var problem: String?
    @State private var chosen: ProviderModel?

    var body: some View {
        Form {
            if let models {
                ProviderModelList(kind: kind, models: models, chosen: $chosen, isChatGPTPlan: isChatGPTPlan)
                Section {
                    Button("Use This Model") {
                        if let chosen { coordinator.keys.choose(chosen, for: kind) }
                        dismiss()
                    }
                    .disabled(chosen == nil || chosen == current)
                    .accessibilityIdentifier("aiKey.useModel")
                }
            } else if let problem {
                Text(problem)
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Model")
        .task {
            do {
                guard let token = try await coordinator.validToken(for: kind) else {
                    problem = isChatGPTPlan
                        ? "Your ChatGPT sign-in isn't on this \(AskDevice.noun) any more."
                        : "The key for \(kind.displayName) isn't on this \(AskDevice.noun) any more."
                    return
                }
                let list = try await coordinator.models(for: kind, key: token)
                chosen = list.first { $0.id == current.id }
                models = list
            } catch let failure as OpenAIOAuth.Failure {
                problem = failure.userMessage
            } catch {
                problem = error.message(kind)
            }
        }
    }
}

/// The list a reader picks a model from: newest first, the app's tested
/// models marked, the preferred one first.
private struct ProviderModelList: View {
    let kind: ProviderKind
    let models: [ProviderModel]
    @Binding var chosen: ProviderModel?
    var isChatGPTPlan: Bool = false

    var body: some View {
        Section {
            ForEach(models) { model in
                Button {
                    chosen = model
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Metrics.spacing4) {
                            Text(model.displayName).foregroundStyle(Palette.ink)
                            if kind.testedModelIDs.contains(model.id) {
                                Text("Tested with Issa Reader")
                                    .font(Typography.footnote)
                                    .foregroundStyle(Palette.inkTertiary)
                            }
                        }
                        Spacer()
                        if chosen == model {
                            Image(systemName: "checkmark").foregroundStyle(Palette.tangerine)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("aiKey.model.\(model.id)")
                .accessibilityAddTraits(chosen == model ? .isSelected : [])
            }
        } header: {
            Text(isChatGPTPlan ? "Models your ChatGPT plan can use" : "Models your key can use")
        } footer: {
            Text(isChatGPTPlan
                ? "Larger models answer better and use more of your weekly shared limit."
                : "Larger models answer better and cost more per question.")
        }
    }
}

// MARK: -

/// Takes a pasted key off the clipboard straight away, where nothing else has
/// been copied since: a key left there is readable by the next app that asks.
enum ProviderKeyClipboard {
    @MainActor
    static func clearAfterPaste() {
        #if canImport(UIKit)
        let board = UIPasteboard.general
        let count = board.changeCount
        DispatchQueue.main.async {
            if board.changeCount == count { board.items = [] }
        }
        #elseif canImport(AppKit)
        let board = NSPasteboard.general
        let count = board.changeCount
        DispatchQueue.main.async {
            if board.changeCount == count { board.clearContents() }
        }
        #endif
    }
}

private extension Error {
    func message(_ kind: ProviderKind) -> String {
        (self as? ProviderCatalog.Failure)?.message(kind)
            ?? "Couldn't reach \(kind.displayName). Check your connection and try again."
    }
}
#endif
