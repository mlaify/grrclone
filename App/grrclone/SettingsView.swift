import SwiftUI
import ServiceManagement
import GrrCloneCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        TabView {
            connectionsTab
                .tabItem { Label("Connections", systemImage: "externaldrive") }
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Sized for the tallest tab, Connections. A Settings window that resizes as
        // you switch tabs looks broken, so every tab gets the same frame.
        .frame(width: 520, height: 500)
    }

    /// A picker and a form, not a split view.
    ///
    /// An `HSplitView` here ran edge to edge: its list sat under the window's title
    /// bar with the traffic lights on top of the first row, and its divider carried on
    /// up through the tab strip. A sidebar is right for a large window and wrong for a
    /// 520-point settings pane. This also matches the other two tabs, which are forms.
    private var connectionsTab: some View {
        Form {
            Section {
                Picker("Connection", selection: $selection) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(model.rows) { row in
                        Text(row.connection.displayName).tag(Optional(row.connection.id))
                    }
                }
            }

            if let id = selection, let row = model.rows.first(where: { $0.id == id }) {
                ConnectionDetail(connection: row.connection, model: model)
            } else {
                Section {
                    Text(model.rows.isEmpty
                         ? "No remotes found. Add one with `rclone config`."
                         : "Choose a connection above to change how it is mounted.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        // Land on something useful. Opening to an empty pane and a "Choose…" prompt
        // makes the user do a step the app can do for them, and with one remote
        // configured there is nothing to choose.
        .onAppear {
            if selection == nil { selection = model.rows.first?.id }
        }
        .onChange(of: model.rows.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = ids.first }
            if selection == nil { selection = ids.first }
        }
    }

    private var generalTab: some View {
        Form {
            LaunchAtLoginToggle()
            LabeledContent("Mount folder") {
                Text(model.mountRoot.path)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            Text("Each connection is mounted in a folder of its own beneath this path. "
                 + "grrclone never unmounts anything it did not create.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("grrclone").font(.title2.weight(.semibold))
            Text("Connects rclone remotes as Finder volumes. No kernel extension, no root.")
            Divider()
            Text("Privacy").font(.headline)
            Text("""
                 No telemetry, no analytics, no crash reporting, and no update check. \
                 The only network connections made are to the storage providers you \
                 configure. There are no accounts and no license keys.
                 """)
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
            Text("MIT licensed").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings for one connection.
///
/// Emits `Section`s rather than its own `Form`: it is placed inside the Connections
/// tab's form, and a nested form draws a second inset background inside the first.
private struct ConnectionDetail: View {
    let connection: Connection
    @ObservedObject var model: AppModel

    @State private var displayName: String = ""
    @State private var readOnly = false
    @State private var cacheSize = ""
    @State private var connectAtLogin = false

    var body: some View {
        Group {
            Section {
                LabeledContent("Remote", value: connection.fsSpec)
                TextField("Name", text: $displayName)
            } footer: {
                Text("Also the folder name this remote is mounted in.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Connect at login", isOn: $connectAtLogin)
                Toggle("Read only", isOn: $readOnly)
                TextField("Cache size limit", text: $cacheSize)
            } footer: {
                Text("""
                     Files you write are cached on this Mac and uploaded in the \
                     background, which is what Finder and apps like Office expect.
                     """)
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Revert", action: load).disabled(!hasChanges)
                    // Explicit rather than saving as you type: the name decides the
                    // mount folder, so applying it halfway through being typed would
                    // create directories nobody asked for.
                    Button("Apply", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasChanges)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: connection.id) { _, _ in load() }
    }

    private var hasChanges: Bool {
        displayName != connection.displayName
            || readOnly != connection.options.readOnly
            || cacheSize != connection.options.vfsCacheMaxSize
            || connectAtLogin != connection.connectAtLogin
    }

    private func load() {
        displayName = connection.displayName
        readOnly = connection.options.readOnly
        cacheSize = connection.options.vfsCacheMaxSize
        connectAtLogin = connection.connectAtLogin
    }

    private func save() {
        var updated = connection
        updated.displayName = displayName.isEmpty ? connection.remote : displayName
        updated.options.readOnly = readOnly
        updated.options.vfsCacheMaxSize = cacheSize.isEmpty ? "20G" : cacheSize
        updated.connectAtLogin = connectAtLogin
        model.update(updated)
    }
}

/// Registers the app as a login item through `SMAppService`, which needs no helper
/// bundle and no privileged installation.
private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Toggle("Open grrclone at login", isOn: $enabled)
            .onChange(of: enabled) { _, wanted in
                do {
                    if wanted { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    error = nil
                } catch {
                    // Revert, so the control never claims a state the system rejected.
                    self.error = error.localizedDescription
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }
}
