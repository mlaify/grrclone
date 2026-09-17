import Foundation

/// Records that a session is in progress, so the next launch can tell whether the
/// last one ended properly.
///
/// grrclone already recovers from an unclean shutdown — orphaned daemons are reaped
/// and stale mounts reconciled — but it did so silently, behind a status line that
/// disappears. That is the wrong shape for this. An unclean shutdown is the one case
/// where a user's data may genuinely have been affected: uploads can have been in
/// flight, and a mountpoint can have been left behind for something to write into.
/// They should be told, once, with enough detail to check.
///
/// The marker is deliberately simple: a file that exists while running and is deleted
/// on the way out. Anything cleverer would have to survive the same power cut it is
/// trying to detect.
public struct SessionMarker: Sendable {

    public struct Record: Codable, Sendable, Equatable {
        public var startedAt: Date
        /// Mountpoints live at the moment the record was last written. After a crash
        /// these are the paths worth checking.
        public var mountPoints: [String]
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL(runtimeDirectory: URL) -> URL {
        runtimeDirectory.appendingPathComponent("session.json")
    }

    /// The previous session's record, if it did not shut down cleanly.
    ///
    /// Reading is non-destructive; call `clear()` once the user has been told.
    public func previousSession() -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    public func begin() {
        write(Record(startedAt: Date(), mountPoints: []))
    }

    public func update(mountPoints: [String]) {
        var record = (try? JSONDecoder().decode(Record.self, from: Data(contentsOf: url)))
            ?? Record(startedAt: Date(), mountPoints: [])
        record.mountPoints = mountPoints
        write(record)
    }

    /// Called on a clean shutdown. Its absence next time means the shutdown was clean.
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// What an unclean shutdown left behind, and what can be done about it.
public struct UncleanShutdownReport: Sendable, Equatable {
    public let previousStart: Date
    /// Mountpoints that were live, and now hold data on the local disk where the
    /// volume used to be. This is the case that loses work: the next mount hides it.
    public let shadowedPaths: [String]
    /// Mountpoints that were live and are now empty. Nothing to recover.
    public let cleanPaths: [String]

    public var needsAttention: Bool { !shadowedPaths.isEmpty }
}

extension UncleanShutdownReport {

    /// Inspect the paths a crashed session had mounted.
    ///
    /// A path holding files now is not a remote that survived; it is local data
    /// written into the empty directory the crash left behind. Mounting over it would
    /// hide it, which is why `prepareMountPoint` refuses, and why this exists to say
    /// so in terms a user can act on.
    public static func inspect(_ record: SessionMarker.Record,
                               fileManager: FileManager = .default) -> UncleanShutdownReport {
        var shadowed: [String] = []
        var clean: [String] = []

        for path in record.mountPoints {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let contents = ((try? fileManager.contentsOfDirectory(atPath: path)) ?? [])
                .filter { $0 != ".DS_Store" }
            if contents.isEmpty { clean.append(path) } else { shadowed.append(path) }
        }

        return UncleanShutdownReport(previousStart: record.startedAt,
                                     shadowedPaths: shadowed,
                                     cleanPaths: clean)
    }

    /// Move local data out of a mountpoint so the remote can be mounted without
    /// hiding it.
    ///
    /// Moved rather than deleted, and never merged into the remote: grrclone cannot
    /// know whether these files are newer than what is on the server, and guessing
    /// wrong overwrites the wrong copy. The user decides; this only makes the decision
    /// possible by putting the data somewhere visible with a name that says what it is.
    @discardableResult
    public static func recover(path: String,
                               fileManager: FileManager = .default) throws -> URL {
        let source = URL(fileURLWithPath: path)
        try? NFSTransport.unprotect(source)

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate]
        let name = "\(source.lastPathComponent) (recovered \(stamp.string(from: Date())))"
        var destination = source.deletingLastPathComponent().appendingPathComponent(name)

        var attempt = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = source.deletingLastPathComponent()
                .appendingPathComponent("\(name) \(attempt)")
            attempt += 1
        }

        try fileManager.moveItem(at: source, to: destination)
        return destination
    }
}
