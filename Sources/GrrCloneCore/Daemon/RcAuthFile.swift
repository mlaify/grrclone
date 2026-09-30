import CryptoKit
import Foundation

/// The control socket's credential, handed to rclone as a file rather than as
/// arguments.
///
/// `--rc-user`/`--rc-pass` put the password on the daemon's command line, and macOS
/// lets every local account read every other account's process arguments — and so do
/// crash reports, spindumps, sysdiagnose and endpoint-security logs (#156). The socket
/// is still `0600` inside `0700` directories, so another account could not use the
/// password; this removes the password from where it could be read at all.
///
/// `--rc-htpasswd` takes a file of `user:hash`. `{SHA}` (unsalted SHA-1) is enough
/// here: the password is 24 random bytes minted for each launch, so there is nothing
/// to guess, and the hash is useless for anything but this one daemon.
///
/// **The file must outlive startup.** rclone re-reads it on every request, and with
/// the file gone every request fails (verified against 1.75.1: 200 before removal,
/// connection dropped after). So it is removed when the daemon stops, not once it has
/// started.
enum RcAuthFile {

    static let fileName = "rc.htpasswd"

    /// One htpasswd line. `user` must not contain `:`; the supervisor's tokens are
    /// base64url and never do.
    static func line(user: String, password: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(password.utf8))
        return "\(user):{SHA}\(Data(digest).base64EncodedString())\n"
    }

    /// Write the file readable by this user only, from the first byte.
    ///
    /// `open` with `0600` and `O_EXCL` rather than writing and then setting
    /// permissions, which would leave a moment where the file exists with the umask's
    /// permissions. `O_NOFOLLOW` so a link planted at the path is refused rather than
    /// written through. Anything already at the path is a previous launch's leftover
    /// and is removed first.
    static func write(user: String, password: String, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("create", errno) }
        defer { close(fd) }
        let bytes = Array(line(user: user, password: password).utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw posixError("write", errno) }
        guard fsync(fd) == 0 else { throw posixError("sync", errno) }
    }

    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func posixError(_ what: String, _ code: Int32) -> Error {
        DaemonSupervisor.Failure.didNotStart(
            "could not \(what) the control-socket credential file: \(String(cString: strerror(code)))")
    }
}
