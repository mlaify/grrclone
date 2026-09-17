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
            Section {
                DSStoreToggle()
            } footer: {
                Text("""
                     Finder writes a hidden .DS_Store file into every folder it opens, \
                     and on a remote those get uploaded. This stops it for all network \
                     volumes, not only grrclone's, and takes effect once Finder \
                     restarts.

                     It does not stop the ._ files. Those carry attributes that NFS \
                     cannot store, so macOS writes one beside almost every file, and \
                     nothing on this side can prevent it.
                     """)
                .font(.caption).foregroundStyle(.secondary)
            }
            if model.configIsEncrypted {
                Section {
                    LabeledContent("Configuration password") {
                        HStack {
                            Text(model.hasSavedConfigPassword ? "Saved in your keychain" : "Not saved")
                                .font(.caption).foregroundStyle(.secondary)
                            if model.hasSavedConfigPassword {
                                Button("Forget") { model.forgetConfigPassword() }
                                    .controlSize(.small)
                            }
                        }
                    }
                } footer: {
                    Text("Your rclone configuration is encrypted. Forgetting the "
                         + "password means grrclone asks for it the next time it starts.")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Mount folder") {
                    HStack {
                        Text(model.mountRoot.path)
                            .font(.caption).textSelection(.enabled)
                            .lineLimit(1).truncationMode(.head)
                        Button("Change…") { chooseMountRoot() }
                            .controlSize(.small)
                    }
                }
            } footer: {
                Text("Each connection is mounted in a folder of its own beneath this "
                     + "path. Changing it does not move anything already mounted; "
                     + "disconnect and reconnect for it to take effect. grrclone never "
                     + "unmounts anything it did not create.")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Chooses the folder connections are mounted beneath.
    private func chooseMountRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.mountRoot
        panel.prompt = "Use This Folder"
        panel.message = "Connections are mounted in folders beneath this one."
        // The Settings window is not key while the panel is up, and an accessory app
        // needs to be active for a panel to come forward at all.
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            model.mountRoot = url
        }
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

    /// Saves, then shows what was actually saved.
    ///
    /// Empty fields are filled in with a fallback — a blank name would leave the mount
    /// folder unnamed — and the draft has to be told, or it keeps showing the empty
    /// field the user left behind. `hasChanges` then stays true forever: Apply and
    /// Revert remain lit after a save that succeeded, which reads as a failure. The
    /// usual reload does not cover this, since it is keyed on the connection's id and
    /// the id has not changed.
    private func save() {
        var updated = connection
        updated.displayName = displayName.isEmpty ? connection.remote : displayName
        updated.options.readOnly = readOnly
        updated.options.vfsCacheMaxSize = cacheSize.isEmpty ? "20G" : cacheSize
        updated.connectAtLogin = connectAtLogin
        model.update(updated)

        displayName = updated.displayName
        cacheSize = updated.options.vfsCacheMaxSize
        readOnly = updated.options.readOnly
        connectAtLogin = updated.connectAtLogin
    }
}

/// Toggles the system preference that keeps `.DS_Store` off network volumes.
///
/// Writing to another application's defaults domain is unusual, and done here because
/// there is no other way: the setting belongs to Finder, not to grrclone. It is
/// presented as the system-wide change it is rather than as an app setting.
private struct DSStoreToggle: View {
    @State private var enabled = !FinderMetadata.writesDSStoreToNetworkVolumes
    @State private var needsRelaunch = false

    var body: some View {
        Toggle("Stop Finder writing .DS_Store to network volumes", isOn: $enabled)
            .onChange(of: enabled) { _, wanted in
                UserDefaults(suiteName: "com.apple.desktopservices")?
                    .set(wanted, forKey: "DSDontWriteNetworkStores")
                needsRelaunch = true
            }
        if needsRelaunch {
            HStack {
                Text("Finder must restart for this to take effect.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                // Offered rather than done automatically: relaunching Finder closes
                // the user's windows, which is not grrclone's decision to make.
                Button("Relaunch Finder") {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                    task.arguments = ["Finder"]
                    try? task.run()
                    needsRelaunch = false
                }
                .controlSize(.small)
            }
        }
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
