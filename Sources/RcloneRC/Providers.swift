import Foundation

/// The backends rclone can talk to, and the questions each one asks.
///
/// Read from the daemon rather than written down here. The current build reports 69
/// providers and 968 options between them, and rclone adds to both with every
/// release — a hand-maintained copy would be wrong the day it shipped and subtly
/// wrong forever after.
extension RcloneRCClient {

    public struct Provider: Sendable, Equatable, Identifiable {
        public let name: String
        public let description: String
        public let options: [ProviderOption]

        public var id: String { name }

        /// Backends that authenticate through a browser, which the wizard cannot yet
        /// drive. Detected by the presence of an OAuth token option rather than by a
        /// list of names, so a new OAuth backend is recognised without a code change.
        public var requiresOAuth: Bool {
            options.contains { $0.name == "token" }
        }
    }

    public struct ProviderOption: Sendable, Equatable, Identifiable {
        public let name: String
        public let help: String
        public let type: String
        public let required: Bool
        public let advanced: Bool
        /// rclone's own visibility flag: non-zero means it hides the option somewhere.
        public let hide: Int
        public let isPassword: Bool
        public let sensitive: Bool
        public let defaultValue: String
        public let examples: [Example]
        /// True when the examples are the only permitted values.
        public let exclusive: Bool
        /// Which sub-providers this option belongs to, verbatim from rclone: a comma
        /// separated list, optionally negated with a leading `!`. Empty means always.
        public let providerGate: String

        public var id: String { name }

        /// The first line of the help, which is what a form label can show.
        public var summary: String {
            help.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? name
        }

        public struct Example: Sendable, Equatable, Identifiable {
            public let value: String
            public let help: String
            public var id: String { value }
        }
    }
}

extension RcloneRCClient {

    /// Every backend rclone supports, with its options.
    public func providers() async throws -> [Provider] {
        Self.parseProviders(try await call("config/providers"))
    }

    /// Create a remote.
    ///
    /// `obscure` is on because rclone stores passwords obscured, and a password
    /// written in the clear would work until something else read the config and
    /// re-wrote it. Letting rclone do the obscuring is also the only way to get the
    /// same result its own `config` command produces.
    public func createRemote(name: String, type: String,
                             parameters: [String: String]) async throws {
        var params: [String: JSONValue] = [
            "name": .string(name),
            "type": .string(type),
            "parameters": .object(parameters.mapValues { JSONValue.string($0) }),
            "opt": .object(["obscure": .bool(true), "nonInteractive": .bool(true)]),
        ]
        // An empty parameters object still has to be sent; rclone rejects a missing key.
        if parameters.isEmpty { params["parameters"] = .object([:]) }
        _ = try await call("config/create", params)
    }

    public func deleteRemote(name: String) async throws {
        _ = try await call("config/delete", ["name": .string(name)])
    }

    static func parseProviders(_ value: JSONValue) -> [Provider] {
        guard let list = value["providers"]?.arrayValue else { return [] }

        return list.compactMap { entry -> Provider? in
            guard let name = entry["Name"]?.stringValue else { return nil }
            let options = (entry["Options"]?.arrayValue ?? []).compactMap(parseOption)
            return Provider(name: name,
                            description: entry["Description"]?.stringValue ?? name,
                            options: options)
        }
        .sorted { $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending }
    }

    static func parseOption(_ entry: JSONValue) -> ProviderOption? {
        guard let name = entry["Name"]?.stringValue else { return nil }

        let examples = (entry["Examples"]?.arrayValue ?? []).compactMap { e -> ProviderOption.Example? in
            guard let value = e["Value"]?.stringValue else { return nil }
            return ProviderOption.Example(value: value, help: e["Help"]?.stringValue ?? value)
        }

        return ProviderOption(
            name: name,
            help: entry["Help"]?.stringValue ?? "",
            type: entry["Type"]?.stringValue ?? "string",
            required: entry["Required"]?.boolValue ?? false,
            advanced: entry["Advanced"]?.boolValue ?? false,
            hide: entry["Hide"]?.intValue ?? 0,
            isPassword: entry["IsPassword"]?.boolValue ?? false,
            sensitive: entry["Sensitive"]?.boolValue ?? false,
            defaultValue: entry["DefaultStr"]?.stringValue ?? "",
            examples: examples,
            exclusive: entry["Exclusive"]?.boolValue ?? false,
            providerGate: entry["Provider"]?.stringValue ?? "")
    }
}

extension RcloneRCClient.Provider {

    /// The options worth asking about, given what has been answered so far.
    ///
    /// Three filters, each of which changes what a correct form looks like:
    ///
    /// - **Hidden options** are excluded. rclone sets `Hide` for things its own
    ///   interactive config does not ask, and showing them would be asking a user to
    ///   fill in fields the tool itself considers internal.
    /// - **Sub-provider gating.** Many backends are really families — S3 covers AWS,
    ///   Ceph, Cloudflare and thirty more — and an option carries the list of members
    ///   it belongs to. Ignoring that is how you end up asking an AWS user for a
    ///   Cloudflare account ID. The list can be negated with a leading `!`.
    /// - **Advanced options** are held back unless asked for. There are 968 options
    ///   across all providers and almost none of them are needed to connect.
    public func visibleOptions(values: [String: String],
                               includeAdvanced: Bool = false) -> [RcloneRCClient.ProviderOption] {
        let selected = values["provider"] ?? ""
        return options.filter { option in
            guard option.hide == 0 else { return false }
            guard includeAdvanced || !option.advanced else { return false }
            return Self.gateAllows(option.providerGate, selected: selected)
        }
    }

    /// Whether an option's `Provider` list admits the selected sub-provider.
    ///
    /// Empty admits everything. A leading `!` inverts the list — only one option in
    /// the current build uses that form (`oracleobjectstorage`'s `compartment`, gated
    /// on `!no_auth`), which is exactly the kind of single case that gets missed.
    static func gateAllows(_ gate: String, selected: String) -> Bool {
        guard !gate.isEmpty else { return true }

        var list = gate
        var negated = false
        if list.hasPrefix("!") {
            negated = true
            list.removeFirst()
        }

        let members = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let matches = members.contains(selected)
        return negated ? !matches : matches
    }

    /// Required options with nothing filled in, which is what stops the form being
    /// submitted.
    public func missingRequired(values: [String: String]) -> [RcloneRCClient.ProviderOption] {
        visibleOptions(values: values, includeAdvanced: true).filter { option in
            option.required && (values[option.name] ?? "").isEmpty && option.defaultValue.isEmpty
        }
    }
}
