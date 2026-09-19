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
            CacheTab(model: model)
                .tabItem { Label("Cache", systemImage: "internaldrive") }
            LogsTab(model: model)
                .tabItem { Label("Logs", systemImage: "doc.plaintext") }
            UpdatesTab(model: model)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
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

            Section {
                HStack {
                    Spacer()
                    Button("Add Remote…") { model.showAddRemote = true }
                }
            }

            if let id = selection, let row = model.rows.first(where: { $0.id == id }) {
                ConnectionDetail(connection: row.connection, model: model)
            } else {
                Section {
                    Text(model.rows.isEmpty
                         ? "No remotes yet — add one above."
                         : "Choose a connection to change how it is mounted.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $model.showAddRemote) {
            AddRemoteWizard(model: model)
        }
        .sheet(item: $model.deletingConnection) { connection in
            DeleteRemoteSheet(connection: connection, model: model)
        }
        .sheet(item: $model.editingConnection) { connection in
            EditRemoteSheet(connection: connection, model: model)
        }
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
                Text("Keeps Finder's hidden .DS_Store files off your remotes. "
                     + "Applies to all network volumes. The ._ files can't be stopped.")
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
                    Text("Forget it and grrclone will ask for it at the next start.")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            // `false` offers encryption. `nil` means we could not read the file, so
            // say that rather than implying the configuration is in the clear.
            switch model.configIsEncryptedOnDisk {
            case .some(false):
                Section {
                    EncryptConfigOffer(model: model)
                }
            case .none:
                Section {
                    Label("grrclone could not read your rclone configuration, so it "
                          + "cannot tell whether it is encrypted.",
                          systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            case .some(true):
                EmptyView()
            }

            Section {
                BandwidthLimitField(model: model)
            } footer: {
                Text("Applies to all connections, right away. Try 10M, 512k, or "
                     + "1M:100k for separate up and down. Empty means no limit.")
                .font(.caption).foregroundStyle(.secondary)
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
                Text("Each connection gets its own folder here. Reconnect to apply.")
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
            Text("No telemetry, no analytics, no accounts, no licence keys. "
                 + "grrclone only connects to the storage you set up.")
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
    @State private var subpath: String = ""
    @State private var readOnly = false
    @State private var cacheSize = ""
    @State private var connectAtLogin = false

    var body: some View {
        Group {
            Section {
                LabeledContent("Remote", value: previewFsSpec)
                TextField("Name", text: $displayName)
            } footer: {
                Text("Also the folder name this remote is mounted in.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Folder", text: $subpath, prompt: Text("the whole remote"))
            } footer: {
                Text("Mount one folder instead of everything. Leave empty for the "
                     + "whole remote.")
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("File locks are not shared between Macs")
                            .font(.caption.weight(.medium))
                        Text("Don't open the same password database, vault or "
                             + "document on two Macs at once — neither will know "
                             + "about the other.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "lock.open.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("A limit of the protocol, not a setting you can change.")
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Connect at login", isOn: $connectAtLogin)
                Toggle("Read only", isOn: $readOnly)
                TextField("Cache size limit", text: $cacheSize)
            } footer: {
                Text("Files you save are cached here and uploaded in the background.")
                .font(.caption).foregroundStyle(.secondary)
            }

            // Settings that only take effect at mount time were previously applied
            // silently: the form looked saved while the live volume kept the old name
            // and the old read-only state. Say so, and offer the one action that makes
            // it true.
            if model.needsRemount.contains(connection.id) {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Saved, but not yet in force")
                                .font(.caption.weight(.medium))
                            Text("These take effect when the remote is mounted.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remount") { model.remount(connection) }
                    }
                }
            }

            // Destructive actions live at the bottom, apart from the everyday ones.
            // A Delete sitting beside Disconnect invites the mis-click, and the two
            // words mean very different things.
            Section {
                HStack {
                    Button("Edit Remote…") { model.beginEditing(connection) }
                    Spacer()
                    Button("Delete Remote…", role: .destructive) {
                        model.beginDeleting(connection)
                    }
                }
            } footer: {
                Text("Edit changes the credentials and endpoint rclone uses. Delete "
                     + "removes the connection entirely — your files on the storage "
                     + "provider are not touched either way.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    /// What the remote will resolve to once saved, so the Remote row is not stale
    /// while the folder field is being typed into.
    private var previewFsSpec: String {
        var draft = connection
        draft.path = Connection.sanitisedPath(subpath)
        return draft.fsSpec
    }

    private var hasChanges: Bool {
        displayName != connection.displayName
            || Connection.sanitisedPath(subpath) != connection.path
            || readOnly != connection.options.readOnly
            || cacheSize != connection.options.vfsCacheMaxSize
            || connectAtLogin != connection.connectAtLogin
    }

    private func load() {
        displayName = connection.displayName
        subpath = connection.path
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
        updated.displayName = Connection.sanitisedName(displayName, fallback: connection.remote)
        updated.path = Connection.sanitisedPath(subpath)
        updated.options.readOnly = readOnly
        updated.options.vfsCacheMaxSize = cacheSize.isEmpty ? "20G" : cacheSize
        updated.connectAtLogin = connectAtLogin
        model.update(updated)

        displayName = updated.displayName
        subpath = updated.path
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

/// The bandwidth limit field.
///
/// Applied on commit rather than as you type: a partially typed `1M` is `1`, which is
/// a valid limit of one byte per second and would throttle everything to a standstill
/// for as long as it took to type the next character.
private struct BandwidthLimitField: View {
    @ObservedObject var model: AppModel
    @State private var text: String = ""
    @State private var editing = false

    var body: some View {
        LabeledContent("Bandwidth limit") {
            TextField("Unlimited", text: $text)
                .multilineTextAlignment(.trailing)
                .onSubmit { model.updateBandwidthLimit(text) }
                .onAppear { text = model.bandwidthLimit }
                // Follow the model unless the user is mid-edit, so the field shows
                // what rclone actually applied — `1M` comes back as `1Mi` — without
                // rewriting what someone is still typing.
                .onChange(of: model.bandwidthLimit) { _, applied in
                    if !editing { text = applied }
                }
                .onChange(of: text) { _, _ in editing = true }
        }
    }
}

/// Recent daemon output.
///
/// A tab rather than a window of its own. This app is an accessory with no main
/// window, and presenting SwiftUI windows from one has already cost this project a
/// day — see SettingsWindow. Settings is a window that already works.
private struct LogsTab: View {
    @ObservedObject var model: AppModel
    @State private var ticker: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Detail", selection: Binding(
                    get: { model.logLevel },
                    set: { model.setLogLevel($0) }
                )) {
                    ForEach(DaemonSettings.LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Spacer()

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        model.logLines.map(\.text).joined(separator: "\n"), forType: .string)
                }
                .disabled(model.logLines.isEmpty)

                Button("Clear") { model.clearLogs() }
                    .disabled(model.logLines.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.logLines) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.logLines.last?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }

            if model.logLines.isEmpty {
                Text("Nothing yet — raise the detail to see more.")
                .font(.caption).foregroundStyle(.secondary)
            }

            Text("Passwords are removed automatically. Debug is very noisy — "
                 + "don't leave it on.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        // Polled only while this tab is visible: an app that is not showing logs has
        // no reason to keep waking up to copy them.
        .onAppear {
            Task { await model.refreshLogs() }
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in await model.refreshLogs() }
            }
        }
        .onDisappear {
            ticker?.invalidate()
            ticker = nil
        }
    }
}

/// Update checking, and the awkward truth about Homebrew.
///
/// Two updaters cannot own one app bundle. Homebrew records the version it installed;
/// an app that replaces itself makes that record a lie, and the next `brew upgrade`
/// reinstalls over the top — downgrading anyone who had moved ahead. So when grrclone
/// was installed by Homebrew it says so and points at `brew upgrade` rather than
/// pretending it can manage itself.
///
/// Checking is still offered to Homebrew users, because knowing a release exists is
/// useful and costs nothing; it is *installing* that has to have one owner.
private struct UpdatesTab: View {
    @ObservedObject var model: AppModel

    private var isHomebrew: Bool { model.installation == .homebrew }

    private var installedByNote: String {
        guard isHomebrew else { return "" }
        return "Homebrew manages this copy — update it with "
            + "`brew update && brew upgrade --cask grrclone`."
    }

    private var howToInstallNote: String {
        isHomebrew ? "Run `brew update && brew upgrade --cask grrclone` to install it."
                   : "Download it from the releases page."
    }

    private func availableText(_ update: AvailableUpdate) -> String {
        let suffix = update.isPrerelease ? " (pre-release)" : ""
        return "Version " + update.version.description + " is available" + suffix
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed version", value: model.currentVersion.description)
                LabeledContent("Installed by") {
                    Text(isHomebrew ? "Homebrew" : "Direct download")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                // Always a Text, never a bare `if`: a conditional with no else
                // makes the footer ambiguous and the compiler blames the enclosing
                // Form. The strings live outside the view builder for the same
                // family of reason — concatenation inside a ternary inside a
                // ViewBuilder defeats the type checker outright.
                Text(installedByNote).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Check for new releases", isOn: $model.updateChecksEnabled)
                Toggle("Include pre-releases", isOn: $model.includePrereleases)
                    .disabled(!model.updateChecksEnabled)
            } footer: {
                Text("Asks GitHub once a day what versions exist. Sends nothing "
                     + "about you, and never installs anything by itself.")
                .font(.caption).foregroundStyle(.secondary)
            }

            // The app's one permission, stated rather than buried.
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.notificationsAuthorised
                             ? "grrclone will notify you when an update is available"
                             : "Notifications are off")
                        .font(.caption.weight(.medium))
                        Text(model.notificationsAuthorised
                             ? "This is the only permission grrclone asks for."
                             : "grrclone asks for one permission, and only this one: "
                               + "to notify you about an update it finds on GitHub. "
                               + "Turn it on in System Settings › Notifications.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: model.notificationsAuthorised
                          ? "bell.badge" : "bell.slash")
                    .foregroundStyle(model.notificationsAuthorised ? .green : .secondary)
                }
            }
            .task { await model.refreshNotificationAuthorisation() }

            if model.includePrereleases && isHomebrew {
                Section {
                    Label {
                        Text("Homebrew installs stable releases only. A pre-release "
                             + "has to be downloaded from the releases page, and doing "
                             + "that replaces the copy Homebrew is tracking.")
                        .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                HStack {
                    if model.updateCheckInProgress {
                        ProgressView().controlSize(.small)
                    } else if let update = model.availableUpdate {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(availableText(update))
                                .font(.callout.weight(.medium))
                            Text(howToInstallNote)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let checked = model.lastUpdateCheck {
                        Text("Up to date, as of \(checked.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(model.updateChecksEnabled ? "Not checked yet"
                                                       : "Checking is off")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Spacer()

                    if model.availableUpdate != nil {
                        // Only for a Homebrew install: a direct-download user has
                        // no brew command to run, and offering one would send them
                        // somewhere that does not apply to them.
                        if isHomebrew {
                            Button("Copy Command") { model.copyUpgradeCommand() }
                                .help(model.upgradeCommand)
                        }
                        // The URL is composed locally from the repository and tag
                        // and never taken from GitHub's reply, so a tampered
                        // response can at worst name a tag that 404s — it cannot
                        // redirect this button somewhere else.
                        Button("Release Notes") { model.openReleasePage() }
                    }
                    // Disabled rather than silently doing nothing. The gate now
                    // lives inside checkForUpdates(), so a button that looked live
                    // and quietly returned would be worse than one that is plainly
                    // unavailable until checking is switched on.
                    Button("Check Now") { model.checkForUpdates() }
                        .disabled(model.updateCheckInProgress || !model.updateChecksEnabled)
                        .help(model.updateChecksEnabled
                              ? "Ask GitHub whether a newer release exists"
                              : "Turn on “Check for new releases” first")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// Offers to encrypt `rclone.conf`, and explains why that is not already the case.
///
/// grrclone shows a password field when adding a remote, has a keychain feature, and
/// never connects the two out loud — so a reasonable person concludes their remote
/// passwords are in the keychain. They are not. They are in `rclone.conf`, obscured,
/// which `rclone reveal` undoes in one step.
///
/// The keychain holds exactly one thing: the password to an *encrypted* config. Until
/// the config is encrypted, that feature guards something the user does not have, and
/// this is the offer that closes the loop.
private struct EncryptConfigOffer: View {
    @ObservedObject var model: AppModel

    @State private var expanded = false
    @State private var password = ""
    @State private var confirm = ""
    @State private var remember = true
    @State private var working = false

    private var canEncrypt: Bool {
        !working && password.count >= 8 && password == confirm
    }

    var body: some View {
        Group {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your remote passwords are not encrypted")
                        .font(.caption.weight(.medium))
                    Text("Anything that can read your rclone config file can recover "
                         + "them. Encrypting it fixes that.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "lock.open.fill").foregroundStyle(.orange)
            }

            if expanded {
                SecureField("New configuration password", text: $password)
                SecureField("Confirm", text: $confirm)
                Toggle("Remember it in my keychain", isOn: $remember)

                Text("Any other rclone tool on this Mac will need this password too. "
                     + "Your mounts stay up.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Cancel") { reset() }
                    Button("Encrypt") {
                        working = true
                        Task {
                            await model.encryptConfiguration(password: password,
                                                             remember: remember)
                            reset()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canEncrypt)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Encrypt Configuration…") { expanded = true }
                }
            }
        }
    }

    private func reset() {
        password = ""; confirm = ""; expanded = false; working = false
    }
}
