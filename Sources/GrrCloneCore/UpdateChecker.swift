import Foundation

/// How this copy of grrclone was installed.
///
/// It decides who is allowed to update the app. Two updaters fighting over the same
/// bundle is worse than either alone: Homebrew records the version it installed, so an
/// app that replaces itself leaves that record stale, and the next `brew upgrade`
/// happily reinstalls over the top — downgrading anyone who had moved ahead.
public enum InstallationKind: Sendable, Equatable {
    case homebrew
    case direct
    case unknown

    /// Detected from the Caskroom rather than by running `brew`.
    ///
    /// A GUI app does not inherit a shell's PATH, so `brew` may not be findable at all,
    /// and spawning it on launch to answer a question about a directory would be slow
    /// and fragile. Homebrew always creates `<prefix>/Caskroom/<token>` when it installs
    /// a cask — verified against the local installation — and that is enough.
    ///
    /// Note the app bundle itself is not a symlink: for `.app` artifacts Homebrew moves
    /// the bundle into place, so the path alone cannot tell you who put it there.
    public static func detect(token: String = "grrclone",
                              prefixes: [String] = ["/opt/homebrew", "/usr/local"],
                              fileManager: FileManager = .default) -> InstallationKind {
        for prefix in prefixes {
            let caskroom = "\(prefix)/Caskroom/\(token)"
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: caskroom, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return .homebrew
            }
        }
        return .direct
    }
}

/// A released version, ordered the way semver says.
public struct ReleaseVersion: Comparable, Sendable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// `rc1`, `beta.2`, or empty for a final release.
    public let prerelease: String

    public var isPrerelease: Bool { !prerelease.isEmpty }
    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-\(prerelease)")
    }

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }

        let prereleaseSplit = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = prereleaseSplit[0].split(separator: ".")
        guard numbers.count >= 2,
              let major = Int(numbers[0]), let minor = Int(numbers[1]) else { return nil }

        self.major = major
        self.minor = minor
        self.patch = numbers.count > 2 ? (Int(numbers[2]) ?? 0) : 0
        self.prerelease = prereleaseSplit.count > 1 ? String(prereleaseSplit[1]) : ""
    }

    /// A pre-release sorts *below* the release it precedes: 0.2.0-rc1 < 0.2.0. Getting
    /// this backwards would offer someone on 0.2.0 an "upgrade" to 0.2.0-rc1.
    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        if a.prerelease == b.prerelease { return false }
        if a.prerelease.isEmpty { return false }   // a is final, b is a pre-release
        if b.prerelease.isEmpty { return true }    // a is a pre-release, b is final
        return a.prerelease.compare(b.prerelease, options: .numeric) == .orderedAscending
    }
}

/// A release grrclone could offer.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: ReleaseVersion
    public let pageURL: URL
    public let publishedAt: Date?
    public var isPrerelease: Bool { version.isPrerelease }
}

/// Checks GitHub for a newer release.
///
/// **Checks only.** It never downloads or installs anything. Self-installing would mean
/// verifying a signature on a downloaded bundle and swapping a running app, which is a
/// large attack surface to add to a program that mounts your storage — and it is the
/// part Homebrew already does well for the people who use it. Telling the user and
/// opening the release page is the whole job.
///
/// **Off unless asked.** grrclone promises no outbound connection except to the storage
/// the user configured. An update check is an exception the user opts into, so it must
/// be genuinely off by default, and the privacy check asserts that it is.
public struct UpdateChecker: Sendable {

    public enum Failure: Error, LocalizedError {
        case badResponse(Int)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .badResponse(let code):
                return code == 403
                    ? "GitHub rate-limited the update check. Try again later."
                    : "GitHub returned HTTP \(code) when checking for updates."
            case .malformed:
                return "Could not read the release list from GitHub."
            }
        }
    }

    public let repository: String
    private let session: URLSession

    public init(repository: String = "mlaify/grrclone", session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    public var releasesURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
    }

    /// The newest release worth offering, or nil when already current.
    ///
    /// - Parameters:
    ///   - current: the running version.
    ///   - includePrereleases: whether release candidates count.
    public func check(current: ReleaseVersion,
                      includePrereleases: Bool) async throws -> AvailableUpdate? {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Identifies the client to GitHub and nothing else. No version, no machine
        // details, no identifier: the request already reveals an IP and that someone
        // is using grrclone, and it does not need to reveal more.
        request.setValue("grrclone", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(http.statusCode)
        }

        return Self.newestUpdate(in: data, current: current,
                                 includePrereleases: includePrereleases)
    }

    /// Parsing kept separate from fetching so it can be tested against captured
    /// responses rather than against the live API.
    public static func newestUpdate(in data: Data,
                                    current: ReleaseVersion,
                                    includePrereleases: Bool) -> AvailableUpdate? {
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        let formatter = ISO8601DateFormatter()
        var best: AvailableUpdate?

        for release in releases {
            // A draft is not published; offering one would send people to a 404.
            if release["draft"] as? Bool == true { continue }

            let isPrerelease = release["prerelease"] as? Bool ?? false
            if isPrerelease && !includePrereleases { continue }

            guard let tag = release["tag_name"] as? String,
                  let version = ReleaseVersion(tag),
                  let page = (release["html_url"] as? String).flatMap(URL.init(string:))
            else { continue }

            // Trust the tag over the prerelease flag for ordering, but respect the flag
            // for filtering: a maintainer can mark a final tag as a pre-release, and
            // the user's choice is about what they are willing to run.
            guard version > current else { continue }
            if let existing = best, existing.version >= version { continue }

            best = AvailableUpdate(
                version: version,
                pageURL: page,
                publishedAt: (release["published_at"] as? String).flatMap(formatter.date(from:)))
        }
        return best
    }
}
