import Foundation
import RcloneRC

/// What a remote reports about how much of it is used, and how much there is.
///
/// Two sources, tried in this order, both optional and neither backend-specific:
///
/// 1. rclone's `operations/about` — the backend's own accounting. For WebDAV that is
///    RFC 4331 quota properties; for drive-like backends it is the provider's API.
///    Whatever rclone can report, grrclone shows; grrclone adds no knowledge of any
///    backend of its own (CONTRIBUTING: "rclone handles backends").
/// 2. A usage document at `<url>/.usage/usage.json`, fetched with the remote's own
///    credentials. An open convention for servers that report nothing through 1,
///    documented in docs/usage-json.md. A server that does not offer it answers 401
///    or 404 and the app simply shows nothing — no error, no retry.
///
/// "Reports nothing" and "could not be asked" are different answers and stay
/// different: the house rule that an unknown is never displayed as zero.
public struct StorageUsage: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case about, usageDocument }

    public struct Category: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var usedBytes: Int64
        /// Crossing this starts a grace period on quota systems that have one. Nil when
        /// the storage has no such notion.
        public var softLimitBytes: Int64?
        /// Writes fail here. Nil means "no cap", which is not the same as 100 % used.
        public var hardLimitBytes: Int64?
        /// Human text from the server when the soft limit is exceeded, e.g. `6days`.
        public var grace: String?

        public init(id: String, label: String, usedBytes: Int64,
                    softLimitBytes: Int64? = nil, hardLimitBytes: Int64? = nil,
                    grace: String? = nil) {
            self.id = id
            self.label = label
            self.usedBytes = usedBytes
            self.softLimitBytes = softLimitBytes
            self.hardLimitBytes = hardLimitBytes
            self.grace = grace
        }

        /// Fraction of the hard limit used, clamped to 1. Nil when there is no cap.
        public var fractionUsed: Double? {
            guard let hard = hardLimitBytes, hard > 0 else { return nil }
            return min(1, Double(usedBytes) / Double(hard))
        }

        public var isOverSoftLimit: Bool {
            guard let soft = softLimitBytes, soft > 0 else { return false }
            return usedBytes > soft
        }
    }

    public var source: Source
    public var generatedAt: Date?
    public var categories: [Category]

    public init(source: Source, generatedAt: Date? = nil, categories: [Category]) {
        self.source = source
        self.generatedAt = generatedAt
        self.categories = categories
    }

    /// The three answers a remote can give, kept apart on purpose.
    public enum Outcome: Sendable, Equatable {
        case reported(StorageUsage)
        /// rclone was asked and the remote offers neither `about` nor a usage document.
        case notReported
        /// rclone (or the server) could not be asked. Shown as such, never as zero.
        case unreachable(String)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case malformed(String)
        case unsupportedVersion(Int)
        case unexpectedHost(String)
        case insecureURL

        public var errorDescription: String? {
            switch self {
            case .malformed(let why):
                return "The usage document could not be read: \(why)."
            case .unsupportedVersion(let version):
                return "The usage document is version \(version), which this app does not understand."
            case .unexpectedHost(let host):
                return "The usage request was answered by \(host), not by the remote's own host."
            case .insecureURL:
                return "The remote's URL is not https, so its usage document was not requested."
            }
        }
    }

    // MARK: - Source 1: rclone about

    /// One category from `operations/about`, or nil when the backend reported nothing
    /// usable. rclone's fields are all optional: `used`, `total`, `free`, `trashed`,
    /// `other`, in bytes. Two are enough to say something; one is not.
    public static func fromAbout(_ json: JSONValue) -> StorageUsage? {
        guard let object = json.objectValue else { return nil }
        func bytes(_ key: String) -> Int64? {
            guard let value = object[key] else { return nil }
            if let i = value.intValue { return Int64(i) }
            if let d = value.doubleValue { return Int64(d) }
            return nil
        }
        let used = bytes("used"), total = bytes("total"), free = bytes("free")
        let usedBytes: Int64
        if let used { usedBytes = used }
        else if let total, let free { usedBytes = total - free }
        else { return nil }
        let cap: Int64?
        if let total { cap = total } else if let free { cap = usedBytes + free } else { cap = nil }
        // `used` alone, with no idea of the whole, is not worth a bar. Say nothing.
        guard cap != nil || used != nil else { return nil }
        return StorageUsage(source: .about, categories: [
            Category(id: "storage", label: "Storage", usedBytes: usedBytes, hardLimitBytes: cap),
        ])
    }

    // MARK: - Source 2: the usage document

    /// Parse a version-1 usage document. Pure, so it is tested against captured bytes
    /// rather than against a live server — the same reason `UpdateChecker` splits its
    /// parsing out.
    public static func parseUsageDocument(_ data: Data) throws -> StorageUsage {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.malformed("not a JSON object")
            }
            object = parsed
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.malformed("not JSON")
        }
        guard let version = (object["version"] as? NSNumber)?.intValue else {
            throw Failure.malformed("no version")
        }
        guard version == 1 else { throw Failure.unsupportedVersion(version) }
        guard let rawCategories = object["categories"] as? [[String: Any]], !rawCategories.isEmpty else {
            throw Failure.malformed("no categories")
        }
        // JSON `null` arrives as NSNull, which is not an NSNumber, so a null limit
        // correctly becomes nil rather than zero.
        func bytes(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
        var categories: [Category] = []
        for raw in rawCategories {
            guard let id = raw["id"] as? String, let used = bytes(raw["used_bytes"]) else {
                throw Failure.malformed("a category has no id or no used_bytes")
            }
            categories.append(Category(
                id: id, label: (raw["label"] as? String) ?? id, usedBytes: used,
                softLimitBytes: bytes(raw["soft_limit_bytes"]),
                hardLimitBytes: bytes(raw["hard_limit_bytes"]),
                grace: raw["grace"] as? String))
        }
        var generatedAt: Date?
        if let stamp = object["generated_at"] as? String {
            generatedAt = ISO8601DateFormatter().date(from: stamp)
        }
        return StorageUsage(source: .usageDocument, generatedAt: generatedAt, categories: categories)
    }

    /// Fetches the usage document. The transport is injected so tests never touch the
    /// network, mirroring `UpdateChecker(session:)`.
    public struct Fetcher: Sendable {
        public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
        public static let relativePath = ".usage/usage.json"

        private let transport: Transport

        public init(transport: Transport? = nil) {
            self.transport = transport ?? { request in try await URLSession.shared.data(for: request) }
        }

        /// Nil means the server does not offer the document (401, 404, not JSON).
        /// Throwing means it could not be asked. The credentials travel in an
        /// `Authorization` header — never in the URL, which would put them in logs.
        public func usageDocument(baseURL: URL, user: String, password: String) async throws -> StorageUsage? {
            // App Transport Security would refuse cleartext anyway; refusing here first
            // keeps a plain-http remote out of the "could not ask" bucket. It is a
            // "does not report" case: we chose not to ask.
            guard baseURL.scheme?.lowercased() == "https" else { throw Failure.insecureURL }
            // `URL(string:relativeTo:)` replaces the last path component when the base
            // has no trailing slash, so `https://host/dav` would resolve to `/.usage/…`
            // instead of `/dav/.usage/…`. Add the slash.
            var baseString = baseURL.absoluteString
            if !baseString.hasSuffix("/") { baseString += "/" }
            guard let base = URL(string: baseString),
                  let url = URL(string: Self.relativePath, relativeTo: base)?.absoluteURL
            else { throw Failure.malformed("the remote's URL cannot be extended") }

            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("grrclone", forHTTPHeaderField: "User-Agent")
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await transport(request)

            // Same fail-closed check as UpdateChecker: an answer from some other host
            // after a redirect is not an answer from the remote.
            guard let final = response.url,
                  final.scheme?.lowercased() == "https",
                  final.host?.lowercased() == baseURL.host?.lowercased()
            else { throw Failure.unexpectedHost(response.url?.host ?? "unknown") }
            guard let http = response as? HTTPURLResponse else { throw Failure.malformed("not an HTTP response") }
            guard http.statusCode == 200 else { return nil }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard contentType.contains("json") else { return nil }
            return try parseUsageDocument(data)
        }
    }
}
