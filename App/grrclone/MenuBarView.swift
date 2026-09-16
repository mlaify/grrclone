import SwiftUI
import GrrCloneCore

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if model.rows.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.rows) { row in
                            ConnectionRow(row: row, model: model)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)
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
        model.pendingUploads > 0 || model.activity.erroredFiles > 0 || model.activity.outOfSpace
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
                }
                Text("Saved on this Mac, not yet on the server.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
            ForEach(model.foreignMounts, id: \.self) { path in
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { openSettings() }
                .buttonStyle(.plain)
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
