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
        .frame(width: 520, height: 360)
    }

    private var connectionsTab: some View {
        HSplitView {
            List(model.rows, selection: $selection) { row in
                Label(row.connection.displayName, systemImage: row.state.symbolName)
                    .tag(row.connection.id)
            }
            .frame(minWidth: 160)

            Group {
                if let id = selection, let row = model.rows.first(where: { $0.id == id }) {
                    ConnectionDetail(connection: row.connection, model: model)
                } else {
                    Text("Select a connection")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320)
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

private struct ConnectionDetail: View {
    let connection: Connection
    @ObservedObject var model: AppModel

    @State private var displayName: String = ""
    @State private var readOnly = false
    @State private var cacheSize = ""
    @State private var connectAtLogin = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Remote", value: connection.fsSpec)
                TextField("Name", text: $displayName)
                Text("Also the folder name under the mount folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Connect at login", isOn: $connectAtLogin)
                Toggle("Read only", isOn: $readOnly)
                TextField("Cache size limit", text: $cacheSize)
                Text("""
                     Files you write are cached locally and uploaded in the background, \
                     which is what Finder and apps like Office expect. Turning the cache \
                     off would make the volume read-only.
                     """)
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: connection.id) { _, _ in load() }
        .onDisappear(perform: save)
        .toolbar {
            Button("Apply", action: save)
        }
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
