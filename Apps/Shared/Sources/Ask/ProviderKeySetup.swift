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
        Text("Your own AI keys")
            .overlineStyle()
        ForEach(ProviderKind.allCases, id: \.self) { kind in
            NavigationLink {
                ProviderKeyScreen(kind: kind).settingsPage()
            } label: {
                LabeledContent {
                    Text(coordinator.keys.registration(for: kind)?.model.displayName ?? "Add key…")
                        .foregroundStyle(Palette.inkTertiary)
                } label: {
                    Text(kind.displayName)
                }
            }
            .accessibilityIdentifier("settings.aiKey.\(kind.rawValue)")
        }
        Text("Use your own Anthropic or OpenAI account for “Ask about this book”. Questions go there only when you choose it, and are billed to that account.")
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

/// Paste, check, choose a model, agree. Nothing is saved before the last step.
private struct AddProviderKey: View {
    let kind: ProviderKind
    let onDone: () -> Void
    @Environment(AskCoordinator.self) private var coordinator

    private enum Step: Equatable {
        case enter
        case checking
        case choose([ProviderModel])
        case consent(ProviderModel)
    }

    @State private var key = ""
    /// The key the provider accepted. Saved in place of the field, which
    /// could be edited after the check.
    @State private var checked = ""
    @State private var step: Step = .enter
    @State private var problem: String?
    @State private var chosen: ProviderModel?

    var body: some View {
        Form {
            switch step {
            case .enter, .checking:
                enter
            case let .choose(models):
                ProviderModelList(kind: kind, models: models, chosen: $chosen)
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

    private var enter: some View {
        Section {
            SecureField("API key", text: $key)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .textContentType(.password)
                .disabled(step == .checking)
                .accessibilityIdentifier("aiKey.field")
            PasteButton(payloadType: String.self) { strings in
                guard let pasted = strings.first else { return }
                Task { @MainActor in
                    key = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    ProviderKeyClipboard.clearAfterPaste()
                }
            }
            .disabled(step == .checking)
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
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || step == .checking)
            .accessibilityIdentifier("aiKey.check")
            if let problem {
                Text(problem)
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("aiKey.problem")
            }
        } footer: {
            Text(kind.keyInstructions + " The key is kept on this \(AskDevice.noun) only.")
        }
    }

    private func check() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        problem = nil
        step = .checking
        Task {
            do {
                let models = try await coordinator.models(for: kind, key: candidate)
                checked = candidate
                chosen = models.first { $0.id == kind.preferredModelID } ?? models.first
                step = .choose(models)
            } catch {
                problem = error.message(kind)
                step = .enter
            }
        }
    }

    /// What will happen, in full, before anything is saved.
    private func consent(_ model: ProviderModel) -> some View {
        Section {
            Text("Your questions, and the book you're reading up to your place, will be sent to \(kind.displayName) to be answered by \(model.displayName).")
            Text(kind.retentionSentence)
            Text("Questions are billed to your \(kind.displayName) account. They go to \(kind.displayName) only when you choose it in Ask, or make it your default in Settings.")
            Link("\(kind.displayName)'s privacy policy", destination: kind.privacyPolicyURL)
                .foregroundStyle(Palette.tangerine)
            Button("Agree and Add Key") {
                if !checked.isEmpty, coordinator.keys.register(kind, key: checked, model: model) {
                    key = ""
                    checked = ""
                    onDone()
                } else {
                    problem = "The key couldn't be saved on this \(AskDevice.noun). Try again."
                    step = .enter
                }
            }
            .accessibilityIdentifier("aiKey.agree")
            Button("Cancel", role: .cancel) {
                key = ""
                checked = ""
                step = .enter
                onDone()
            }
            .accessibilityIdentifier("aiKey.cancel")
        } header: {
            Text("Before you add this key")
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

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ChangeProviderModel(kind: kind, current: registration.model).settingsPage()
                } label: {
                    LabeledContent("Model", value: registration.model.displayName)
                }
                .accessibilityIdentifier("aiKey.changeModel")
                Button("Replace Key…", action: onReplace)
                    .accessibilityIdentifier("aiKey.replace")
            } footer: {
                Text("Questions you send to \(kind.displayName) go there with the book so far, billed to your account.")
            }
            Section {
                if confirmingRemoval {
                    Text("Remove the \(kind.displayName) key from this \(AskDevice.noun)? Questions can't be sent to \(kind.displayName) until you add one again.")
                    Button("Remove Key", role: .destructive) {
                        coordinator.removeKey(kind)
                        if settings.askDefaultProvider == kind.rawValue { settings.askDefaultProvider = nil }
                        dismiss()
                    }
                    .accessibilityIdentifier("aiKey.remove.confirm")
                    Button("Keep It") { confirmingRemoval = false }
                } else {
                    Button("Remove Key…", role: .destructive) { confirmingRemoval = true }
                        .accessibilityIdentifier("aiKey.remove")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The models the key can use, read again from the provider.
private struct ChangeProviderModel: View {
    let kind: ProviderKind
    let current: ProviderModel
    @Environment(AskCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var models: [ProviderModel]?
    @State private var problem: String?
    @State private var chosen: ProviderModel?

    var body: some View {
        Form {
            if let models {
                ProviderModelList(kind: kind, models: models, chosen: $chosen)
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
            guard let key = coordinator.keys.key(for: kind) else {
                problem = "The key for \(kind.displayName) isn't on this \(AskDevice.noun) any more."
                return
            }
            do {
                let list = try await coordinator.models(for: kind, key: key)
                chosen = list.first { $0.id == current.id }
                models = list
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
            Text("Models your key can use")
        } footer: {
            Text("Larger models answer better and cost more per question.")
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
