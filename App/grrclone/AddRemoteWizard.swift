import SwiftUI
import RcloneRC
import GrrCloneCore

/// Creates an rclone remote without a terminal.
///
/// Until this existed, a new user had to run `rclone config` before grrclone was any
/// use to them — a hard stop for the people this app is for.
///
/// Every field here comes from the daemon's `config/providers`. Nothing about any
/// backend is written down in this file, and that is not tidiness: the current build
/// reports 69 providers and 968 options, and rclone adds to both with every release.
/// A hand-written form would be wrong immediately and wrong differently each month.
@MainActor
struct AddRemoteWizard: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var providers: [RcloneRCClient.Provider] = []
    @State private var selected: RcloneRCClient.Provider?
    @State private var name = ""
    @State private var values: [String: String] = [:]
    @State private var showAdvanced = false
    @State private var loading = true
    @State private var error: String?
    @State private var creating = false
    @State private var search = ""

    // The interactive flow, for backends that ask questions rather than take a form.
    @State private var question: RcloneRCClient.ProviderOption?
    @State private var questionState: String?
    @State private var answer = ""
    @State private var waitingOnBrowser = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if loading {
                loadingView
            } else if let question {
                interactiveStep(question)
            } else if let provider = selected {
                form(for: provider)
            } else {
                providerList
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 560)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            if selected != nil {
                Button {
                    selected = nil
                    values = [:]
                } label: {
                    Label("Backends", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(selected?.description ?? "Add a remote").font(.headline)
            Spacer()
            if selected != nil { Color.clear.frame(width: 70) }
        }
        .padding(12)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Asking rclone which backends it supports")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Choosing a backend

    private var filteredProviders: [RcloneRCClient.Provider] {
        guard !search.isEmpty else { return providers }
        return providers.filter {
            $0.description.localizedCaseInsensitiveContains(search)
                || $0.name.localizedCaseInsensitiveContains(search)
        }
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            List(filteredProviders) { provider in
                Button {
                    choose(provider)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.description)
                            Text(provider.name).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Said before they invest in filling a form they cannot finish.
                        if provider.requiresOAuth {
                            Text("browser sign-in")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }

    // MARK: Filling it in

    private func form(for provider: RcloneRCClient.Provider) -> some View {
        Form {
            Section {
                TextField("Name", text: $name)
            } footer: {
                Text("What this remote is called in rclone. Letters, numbers, dash and "
                     + "underscore.")
                .font(.caption).foregroundStyle(.secondary)
            }

            if provider.requiresOAuth {
                Section {
                    Label {
                        Text("\(provider.description) signs in through a browser. "
                             + "grrclone will ask rclone to open it and wait while you "
                             + "finish; you can leave the rest of this blank.")
                        .font(.caption)
                    } icon: {
                        Image(systemName: "safari").foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(provider.visibleOptions(values: values, includeAdvanced: showAdvanced)) { option in
                field(for: option)
            }

            Section {
                Toggle("Show advanced options", isOn: $showAdvanced)
            }

            if let error {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func field(for option: RcloneRCClient.ProviderOption) -> some View {
        let binding = Binding(
            get: { values[option.name] ?? "" },
            set: { values[option.name] = $0 })

        Section {
            if option.exclusive && !option.examples.isEmpty {
                // Exclusive means the examples are the only legal values, so a free
                // text field would invite a value rclone will reject.
                Picker(option.name, selection: binding) {
                    Text("—").tag("")
                    ForEach(option.examples) { example in
                        Text(example.help.isEmpty ? example.value : example.help)
                            .tag(example.value)
                    }
                }
            } else if !option.examples.isEmpty {
                // Suggestions, not a constraint: rclone accepts other values here.
                VStack(alignment: .leading, spacing: 4) {
                    TextField(option.name, text: binding)
                    Menu("Suggestions") {
                        ForEach(option.examples) { example in
                            Button(example.help.isEmpty ? example.value : example.help) {
                                values[option.name] = example.value
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.caption)
                }
            } else if option.isPassword || option.sensitive {
                VStack(alignment: .leading, spacing: 4) {
                    SecureField(option.name, text: binding)
                    // Said where the password is typed, not buried in Settings. A
                    // SecureField implies protection it does not provide: rclone
                    // obscures this value, and `rclone reveal` undoes that in one step.
                    // Warn unless we know it is encrypted. An unknown state gets the
                    // warning too: better to over-warn about credential storage than
                    // to stay quiet because we could not check.
                    if model.configIsEncryptedOnDisk != true {
                        Label("Stored in your rclone configuration, obscured rather than "
                              + "encrypted. Encrypt the configuration in Settings to "
                              + "protect it properly.",
                              systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if option.type == "bool" {
                Toggle(option.name, isOn: Binding(
                    get: { (values[option.name] ?? option.defaultValue) == "true" },
                    set: { values[option.name] = $0 ? "true" : "false" }))
            } else {
                TextField(option.name, text: binding)
            }
        } header: {
            HStack(spacing: 4) {
                Text(option.name)
                if option.required { Text("required").font(.caption2).foregroundStyle(.secondary) }
            }
        } footer: {
            if !option.help.isEmpty {
                Text(option.help)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Questions rclone asks

    /// One step of rclone's interactive configuration.
    ///
    /// The same option schema the form uses, so the controls are the same — this is a
    /// question at a time rather than a page of them, because each answer decides what
    /// is asked next.
    private func interactiveStep(_ option: RcloneRCClient.ProviderOption) -> some View {
        Form {
            Section {
                if !option.help.isEmpty {
                    Text(option.help)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } header: {
                Text(option.name)
            }

            Section {
                if option.exclusive && !option.examples.isEmpty {
                    Picker("Answer", selection: $answer) {
                        ForEach(option.examples) { example in
                            Text(example.help.isEmpty ? example.value : example.help)
                                .tag(example.value)
                        }
                    }
                    .pickerStyle(.inline)
                } else if option.isPassword || option.sensitive {
                    SecureField("Answer", text: $answer)
                } else {
                    TextField("Answer", text: $answer)
                }
            }

            if waitingOnBrowser {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Waiting for you to finish signing in")
                                .font(.callout.weight(.medium))
                            // Said out loud because the call blocks for as long as the
                            // person takes, and a window that stops responding with no
                            // explanation reads as a hang.
                            Text("rclone has opened your browser. This window will "
                                 + "carry on once you have approved it there.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let error {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func answerQuestion() async {
        guard let state = questionState else { return }
        let asked = question
        error = nil
        creating = true
        // The browser step blocks until the person is done, so say so before waiting
        // rather than after.
        waitingOnBrowser = asked?.isBrowserSignIn ?? false
        defer { creating = false; waitingOnBrowser = false }

        do {
            let next = try await model.continueConfiguring(name: sanitisedName,
                                                           state: state, answer: answer)
            await apply(next)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Move the flow on, or finish.
    private func apply(_ step: RcloneRCClient.ConfigStep) async {
        switch step {
        case .finished:
            question = nil
            questionState = nil
            await model.adoptNewRemotes()
            dismiss()
        case .question(let option, let state):
            question = option
            questionState = state
            // Start from rclone's own default rather than empty, so pressing Continue
            // does what its own config command would do.
            answer = option.examples.first(where: { $0.value == option.defaultValue })?.value
                ?? option.defaultValue
        }
    }

    // MARK: Finishing

    private var footer: some View {
        HStack {
            Button("Cancel") { Task { await cancel() } }
            Spacer()
            if creating && !waitingOnBrowser { ProgressView().controlSize(.small) }
            if question != nil {
                Button("Continue") { Task { await answerQuestion() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating)
            } else {
                Button("Add") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(12)
    }

    /// Abandoning an interactive flow leaves a half-built remote in the config, which
    /// would then show up in the menu as something that cannot be mounted. Remove it.
    private func cancel() async {
        if question != nil { await model.discardRemote(named: sanitisedName) }
        dismiss()
    }

    private var canCreate: Bool {
        guard let provider = selected, !creating else { return false }
        guard !sanitisedName.isEmpty else { return false }
        return provider.missingRequired(values: values).isEmpty
    }

    /// rclone remote names are used as config section headings, so they cannot contain
    /// whatever the user types.
    private var sanitisedName: String {
        name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    }

    private func choose(_ provider: RcloneRCClient.Provider) {
        selected = provider
        error = nil
        if name.isEmpty { name = provider.name }
        // Seed defaults so the form shows what will actually be used.
        for option in provider.options where !option.defaultValue.isEmpty {
            values[option.name] = option.defaultValue
        }
    }

    private func load() async {
        defer { loading = false }
        do { providers = try await model.availableProviders() }
        catch { self.error = error.localizedDescription }
    }

    private func create() async {
        guard let provider = selected else { return }
        creating = true
        defer { creating = false }

        // Only what the user can see and has answered. Sending every option would
        // write defaults into the config as if they had been chosen, which makes a
        // later rclone release unable to change them.
        let visible = Set(provider.visibleOptions(values: values, includeAdvanced: true).map(\.name))
        let parameters = values.filter { visible.contains($0.key) && !$0.value.isEmpty }

        do {
            if provider.requiresOAuth {
                // These ask questions that depend on earlier answers and then hand off
                // to a browser, which a single form cannot express.
                await apply(try await model.beginConfiguring(name: sanitisedName,
                                                             type: provider.name,
                                                             parameters: parameters))
            } else {
                try await model.createRemote(name: sanitisedName, type: provider.name,
                                             parameters: parameters)
                dismiss()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
