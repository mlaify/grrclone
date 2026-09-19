import SwiftUI
import GrrCloneCore
import RcloneRC

/// Change an existing remote's settings.
///
/// Until now a rotated S3 key or a changed WebDAV password meant deleting the remote
/// and building it again — which, since #69, means reading a page of warnings and
/// losing the connection's local settings for a one-word change.
///
/// The form is generated from `config/providers`, the same source the add-remote
/// wizard uses, so a backend rclone gains next month is editable without anyone
/// touching this file.
struct EditRemoteSheet: View {
    let connection: Connection
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var provider: RcloneRCClient.Provider?
    @State private var values: [String: String] = [:]
    /// What was loaded, to work out what actually changed.
    @State private var original: [String: String] = [:]
    /// Option names that are passwords or otherwise sensitive.
    ///
    /// Kept separate from `editedSecrets`, which is the ones the user has typed
    /// into. Conflating the two wiped passwords: an untouched secret is blank in
    /// `values` and obscured in `original`, so a plain "did it change?" comparison
    /// said yes and sent an empty string.
    @State private var secretFields: Set<String> = []
    /// Secret fields the user has typed into. Only these are sent.
    @State private var editedSecrets: Set<String> = []
    @State private var showAdvanced = false
    @State private var loading = true
    @State private var failure: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit “\(connection.remote)”")
                .font(.title3.weight(.semibold))

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading settings…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let provider {
                form(for: provider)
            } else {
                Text("grrclone does not recognise this remote's type, so it cannot "
                     + "build a form for it. Edit it with `rclone config` instead.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if provider != nil && !loading {
                    Toggle("Show advanced settings", isOn: $showAdvanced)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || saving || !hasChanges)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .task { await load() }
    }

    @ViewBuilder
    private func form(for provider: RcloneRCClient.Provider) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Type", value: provider.description)
                ForEach(provider.visibleOptions(values: values,
                                                includeAdvanced: showAdvanced)) { option in
                    field(for: option)
                }
            }
            .padding(.trailing, 4)
        }
    }

    @ViewBuilder
    private func field(for option: RcloneRCClient.ProviderOption) -> some View {
        let binding = Binding(
            get: { values[option.name] ?? "" },
            set: { newValue in
                values[option.name] = newValue
                if option.isPassword || option.sensitive { editedSecrets.insert(option.name) }
            })

        VStack(alignment: .leading, spacing: 3) {
            if option.isPassword || option.sensitive {
                // Deliberately empty, with a placeholder rather than a value.
                //
                // `config/dump` hands back the *obscured* secret, not the plaintext —
                // and `rclone reveal` undoes that in one step. Putting it in a
                // SecureField would show a string of dots that is not the password
                // and cannot be corrected into one. Leaving it blank says the truth:
                // grrclone does not know your password, and will only change it if
                // you type a new one.
                SecureField(option.name, text: binding,
                            prompt: Text("unchanged"))
                Text(editedSecrets.contains(option.name)
                     ? "Will be replaced."
                     : "Leave empty to keep the current value.")
                .font(.caption2).foregroundStyle(.secondary)
            } else if option.type == "bool" {
                Toggle(option.name, isOn: Binding(
                    get: { (values[option.name] ?? "").lowercased() == "true" },
                    set: { values[option.name] = $0 ? "true" : "false" }))
            } else {
                TextField(option.name, text: binding)
            }

            if !option.help.isEmpty {
                Text(option.help.split(separator: "\n").first.map(String.init) ?? "")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Only what the user actually altered. See `RemoteEdit.changeSet`, which lives
    /// in the core package so it can be tested — the app target has no test bundle,
    /// and the first version of this wiped passwords.
    private var changes: [String: String] {
        RemoteEdit.changeSet(values: values, original: original,
                             secretFields: secretFields, editedSecrets: editedSecrets)
    }

    private var hasChanges: Bool { !changes.isEmpty }

    private func load() async {
        defer { loading = false }
        do {
            let stored = try await model.remoteConfig(named: connection.remote)
            original = stored
            // Secrets start blank. Everything else shows what is configured.
            var shown = stored
            let type = stored["type"] ?? ""
            let found = try await model.availableProviders().first { $0.name == type }
            if let found {
                for option in found.options where option.isPassword || option.sensitive {
                    secretFields.insert(option.name)
                    shown[option.name] = ""
                }
                // An option absent from rclone.conf is running at the provider's
                // default, not at empty. Showing a default-on boolean as unchecked
                // tells the user the opposite of what is in force, and a toggle
                // there and back would then write the wrong value explicitly.
                for option in found.options where shown[option.name] == nil {
                    guard !option.defaultValue.isEmpty else { continue }
                    shown[option.name] = option.defaultValue
                    original[option.name] = option.defaultValue
                }
            }
            values = shown
            provider = found
        } catch {
            failure = error.localizedDescription
        }
    }

    private func save() {
        saving = true
        failure = nil
        let payload = changes
        Task {
            defer { saving = false }
            do {
                try await model.updateRemote(named: connection.remote, parameters: payload)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
