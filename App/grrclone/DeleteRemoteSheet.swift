import SwiftUI
import GrrCloneCore

/// Confirmation for deleting a remote.
///
/// The design problem here is not the button, it is the question people actually
/// have: *are my files about to be deleted?* Someone who fears the answer is yes will
/// never press it, and someone who assumes the answer is yes will be baffled when
/// their files are still there. So the answer goes first, in the largest text on the
/// sheet, before any list of consequences.
struct DeleteRemoteSheet: View {
    let connection: Connection
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var typedName = ""
    @State private var acknowledgedPending = false
    @State private var working = false

    private var pending: PendingUploads? { model.deletionPending }
    private var stillChecking: Bool { pending == nil }

    /// Typing the name is the gate. A remote's deletion sitting one click away from
    /// Disconnect is too easy to hit by accident, and the two words mean very
    /// different things.
    private var nameMatches: Bool {
        typedName.trimmingCharacters(in: .whitespaces) == connection.remote
    }

    private var blockedByUploads: Bool {
        guard let pending else { return true }
        return !pending.isSafeToDiscard && !acknowledgedPending
    }

    private var canDelete: Bool { nameMatches && !blockedByUploads && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete “\(connection.displayName)”?")
                .font(.title3.weight(.semibold))

            // The reassurance, first and prominently.
            Label {
                Text("Your files on the storage provider are not touched.")
                    .font(.body.weight(.medium))
            } icon: {
                Image(systemName: "checkmark.shield").foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("grrclone will remove:").font(.callout.weight(.medium))
                bullet("the saved credentials for this remote")
                bullet("its settings in grrclone")
                bullet("its local cache")
                Text("To use it again you would set it up from scratch, including "
                     + "signing in again in a browser if it uses one.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            pendingSection

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Type **\(connection.remote)** to confirm.")
                    .font(.callout)
                TextField("", text: $typedName)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            Text("Your rclone configuration is copied alongside itself first, so this "
                 + "can be undone by hand.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelDeleting()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Delete Remote", role: .destructive) {
                    working = true
                    Task {
                        await model.confirmDelete(connection,
                                                  discardPendingUploads: acknowledgedPending)
                        working = false
                        dismiss()
                    }
                }
                .disabled(!canDelete)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var pendingSection: some View {
        if stillChecking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for unfinished uploads…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let pending, pending.inspectionFailed {
            // Unknown is not permission. The user can still proceed, but only after
            // being told plainly that grrclone could not check.
            warning(colour: .orange,
                    icon: "questionmark.circle",
                    title: "grrclone could not check for unfinished uploads",
                    detail: "Its local cache could not be read, so it cannot tell "
                          + "whether anything is still waiting to be sent.",
                    toggle: "Delete anyway, and discard whatever is in the cache")
        } else if let pending, !pending.dirtyFiles.isEmpty {
            warning(colour: .red,
                    icon: "exclamationmark.triangle.fill",
                    title: "\(pending.count) file(s) have not finished uploading",
                    detail: pending.dirtyFiles.prefix(5).joined(separator: "\n")
                          + (pending.count > 5 ? "\nand \(pending.count - 5) more" : "")
                          + "\n\nThe only copy of these is on this Mac. Connect the "
                          + "remote and let them finish, or they are lost.",
                    toggle: "Delete anyway, and lose these files")
        }
    }

    private func warning(colour: Color, icon: String, title: String,
                         detail: String, toggle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).font(.callout.weight(.medium))
            } icon: {
                Image(systemName: icon).foregroundStyle(colour)
            }
            Text(detail)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(toggle, isOn: $acknowledgedPending)
                .font(.caption)
        }
        .padding(10)
        .background(colour.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }
}
