import SwiftUI
import GrrCloneCore

/// How much disk each remote's cache is using, and a way to get it back.
///
/// `--vfs-cache-mode full` stages every file read or written on local disk. That is
/// what makes writes return immediately and reads repeat instantly, and it is also
/// how three remotes quietly consume 60 GB with nothing in the app reporting it. The
/// cache-size field in a connection's settings sets a ceiling and says nothing about
/// what is actually there.
struct CacheTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.rows.isEmpty {
                    Text("No remotes yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.rows) { row in
                        CacheRow(row: row,
                                 usage: model.cacheUsage[row.id],
                                 model: model)
                    }
                }
            } header: {
                HStack {
                    Text("Cache")
                    Spacer()
                    if model.measuringCache {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(ByteCountFormatter.string(fromByteCount: model.totalCacheBytes,
                                                       countStyle: .file))
                        .monospacedDigit()
                    }
                }
            } footer: {
                Text("Files you open or save are kept here so they load instantly next "
                     + "time. Clearing one only means the next read downloads again.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Refresh") {
                        Task { await model.refreshCacheUsage() }
                    }
                    .disabled(model.measuringCache)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        // Measured when the tab is opened, not on a timer. Walking a 20 GB cache is
        // tens of thousands of stat calls; doing that every two seconds in the
        // background to keep a number fresh nobody is looking at would be absurd.
        .task { await model.refreshCacheUsage() }
    }
}

private struct CacheRow: View {
    let row: AppModel.Row
    let usage: VFSCache.Usage?
    @ObservedObject var model: AppModel

    /// Every reason this cache cannot be cleared right now, in the order the user
    /// should act on them. Nil means it can.
    private var obstacle: String? {
        if row.state.isMounted { return "Disconnect it first" }
        guard let usage else { return "Not measured yet" }
        if usage.pending.inspectionFailed { return "Could not be read" }
        if !usage.pending.dirtyFiles.isEmpty {
            return "\(usage.pending.count) file(s) still uploading"
        }
        if usage.bytes == 0 { return "Nothing cached" }
        return nil
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.connection.displayName)
                if let obstacle {
                    Text(obstacle)
                        .font(.caption)
                        .foregroundStyle(warning ? .orange : .secondary)
                } else if let usage {
                    Text("\(usage.fileCount) file(s)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(usage.map {
                ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file)
            } ?? "—")
            .monospacedDigit()
            .foregroundStyle(.secondary)

            Button("Clear") {
                Task { await model.clearCache(for: row.connection) }
            }
            .disabled(obstacle != nil)
        }
    }

    /// An obstacle the user should notice, as against one that is merely a fact.
    private var warning: Bool {
        guard let usage else { return false }
        return usage.pending.inspectionFailed || !usage.pending.dirtyFiles.isEmpty
    }
}
