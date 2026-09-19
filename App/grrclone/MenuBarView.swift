import SwiftUI
import GrrCloneCore

struct MenuBarView: View {
    @ObservedObject var model: AppModel


    /// Measured height of the connection list. See the comment at its use site.
    @State private var listHeight: CGFloat = 0

    /// Enough for one row, so the list is never invisible even before the first
    /// measurement arrives.
    static let minimumListHeight: CGFloat = 44
    /// Past this the list scrolls, so a machine with many remotes cannot produce a
    /// menu taller than the screen.
    static let maximumListHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let error = model.lastError {
                errorNotice(error)
                Divider()
            }

            if let report = model.uncleanShutdown {
                uncleanShutdownNotice(report)
                Divider()
            }

            if model.rows.isEmpty {
                empty
            } else {
                // Height is measured from the content, not left to the ScrollView.
                //
                // A ScrollView has no intrinsic content height: asked how tall it would
                // like to be, it answers with the minimum. `maxHeight` alone therefore
                // capped a height nothing had set, and the popover — which sizes itself
                // to fit — collapsed to a sliver, drawing the connection rows behind the
                // footer. The list of mounts is the entire point of this menu, so it was
                // the one thing you could not see.
                //
                // Measuring keeps both behaviours: the menu is exactly as tall as it
                // needs to be for a couple of remotes, and scrolls once there are more
                // than fit in `maximumListHeight`.
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.rows) { row in
                            ConnectionRow(row: row, model: model)
                        }
                    }
                    .padding(.vertical, 6)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ListHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    )
                }
                .frame(height: min(max(listHeight, Self.minimumListHeight),
                                   Self.maximumListHeight))
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            }

            if hasActivityToReport {
                Divider()
                activityNotice
            }

            if !model.foreignMounts.isEmpty {
                Divider()
                foreignNotice
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    /// Shows the last error, because until now nothing did.
    ///
    /// `lastError` was published and assigned from a dozen places — a daemon that
    /// would not start, a password that could not be saved, a connection that failed —
    /// and read by no view at all. Every one of those failures was silent: the app said
    /// "Ready" and carried on, and the user found out later, if ever. A failure to save
    /// a config password is the clearest case, since the only symptom is being asked
    /// for it again at the next launch, long after the cause.
    ///
    /// Dismissible, so an error the user has read does not sit in the menu forever.
    private func errorNotice(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                model.clearLastError()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Tells the user the last session ended badly, and what that may have cost.
    ///
    /// Deliberately not a transient status line. Recovery from a crash is automatic —
    /// orphaned daemons reaped, stale mounts cleared — and being quiet about that is
    /// right. What is not right is being quiet when the crash may have taken the
    /// user's own data with it, which is the case when something wrote into a
    /// mountpoint while nothing was mounted on it. That write is on the local disk,
    /// looks saved, and the next mount hides it.
    private func uncleanShutdownNotice(_ report: UncleanShutdownReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: report.needsAttention
                      ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(report.needsAttention ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.needsAttention
                         ? "grrclone did not shut down cleanly, and found local files"
                         : "grrclone did not shut down cleanly")
                        .font(.caption.weight(.medium))
                    Text(report.needsAttention
                         ? "Something wrote into \(report.shadowedPaths.count) "
                           + "connection folder(s) while nothing was mounted there. "
                           + "Those files are on this Mac and would be hidden by the "
                           + "next connection."
                         : "Mounts and the rclone process were cleaned up. Nothing "
                           + "appears to have been lost.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                if report.needsAttention {
                    Button("Move Files Aside") { model.recoverShadowedData() }
                        .controlSize(.small)
                        .help("Move the local files to a folder named “(recovered …)” "
                              + "so the connection can mount without hiding them")
                }
                Button("Dismiss") { model.dismissUncleanShutdown() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("grrclone").font(.headline)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.configLocked {
                // Cancelling the password prompt must not be a one-way door that needs
                // a restart to undo.
                Button("Unlock…") {
                    Task { await model.unlockConfiguration() }
                }
                .help("Enter the password for your encrypted rclone configuration")
            }
            if !model.daemonReady {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No remotes configured")
                .font(.subheadline)
            Text("Add one with `rclone config`, then reopen this menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    /// Kept as a computed property rather than inlined into the `if`. A multi-line
    /// boolean expression inside a ViewBuilder gets misparsed as a trailing closure.
    private var hasActivityToReport: Bool {
        model.pendingUploads > 0 || model.activity.erroredFiles > 0
            || model.activity.outOfSpace || model.activity.hasUnknownState
            || model.transferStats?.isActive == true
    }

    /// Pending uploads are shown prominently because a write returns as soon as it hits
    /// the local cache. Without this, a file looks saved in Finder while nothing has
    /// reached the provider, and closing the lid quietly strands it.
    private var activityNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.pendingUploads > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.pendingUploads == 1
                         ? "1 file still uploading"
                         : "\(model.pendingUploads) files still uploading")
                        .font(.caption)
                    Spacer()
                    if let speed = model.transferSpeed {
                        Text(speed).font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Saved on this Mac, not yet on the server.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // The files themselves, not just a count.
            //
            // A count answers "is anything happening"; it does not answer "is the
            // big one nearly done" or "why has this been going for ten minutes",
            // which is what someone watching an upload actually wants. Capped at
            // three so a large sync does not turn the menu into a log.
            ForEach(model.visibleTransfers) { transfer in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(transfer.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(AppModel.describe(transfer: transfer))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // Indeterminate when rclone has not reported a size, rather than
                    // a bar sitting at 0% that looks stuck.
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if let more = model.hiddenTransferCount {
                Text("and \(more) more")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.activity.hasUnknownState {
                Label("Cannot reach rclone — upload state unknown",
                      systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if model.activity.erroredFiles > 0 {
                Label("\(model.activity.erroredFiles) upload(s) failing, will retry",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if model.activity.outOfSpace {
                Label("Local cache is out of space", systemImage: "internaldrive.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Surfaced so the behaviour is visible rather than merely documented: grrclone can
    /// see these mounts and is deliberately not touching them.
    private var foreignNotice: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Not managed by grrclone")
                .font(.caption.weight(.medium))
            ForEach(model.foreignMounts) { mount in
                HStack(spacing: 6) {
                    Text(mount.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if mount.count > 1 {
                        // Stacked mounts: the same path mounted repeatedly. Saying so
                        // is what turns "grrclone refused to mount here" from a
                        // mystery into a diagnosis.
                        Text("×\(mount.count)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            // Not openSettings(): from an inactive accessory app that silently does
            // nothing. See SettingsWindow.
            Button("Settings…") { SettingsWindow.open() }
                .buttonStyle(.plain)
            Spacer()
            Button("Add Remote…") {
                // Open the window first, then ask it to present the wizard. Presenting
                // from here put the sheet on the popover, which closes as soon as
                // anything is clicked — the wizard appeared and then disappeared the
                // instant you used it.
                SettingsWindow.open()
                model.showAddRemote = true
            }
            .buttonStyle(.plain)
            .help("Create an rclone remote without using the terminal")
            Spacer()
            Button("Check mounts") { model.checkHealthNow() }
                .buttonStyle(.plain)
                .help("Probe each mount and reconnect any that have stopped responding")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ConnectionRow: View {
    let row: AppModel.Row
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.state.symbolName)
                .foregroundStyle(row.state.tint)
                .font(.caption)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.connection.displayName)
                    .lineLimit(1)
                Text(row.state.describedForMenu)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            if row.state.isMounted {
                Button {
                    model.reveal(row.connection)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }

            Button(row.state.isMounted ? "Disconnect" : "Connect") {
                model.toggle(row.connection)
            }
            .controlSize(.small)
            .disabled(isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .onHover { hovering = $0 }
    }

    private var isBusy: Bool {
        if case .connecting = row.state { return true }
        return false
    }
}

/// Carries the measured height of the connection list up to the enclosing view.
private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
