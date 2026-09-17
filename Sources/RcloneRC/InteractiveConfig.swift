import Foundation

/// Driving rclone's interactive configuration, which is how OAuth backends are set up.
///
/// The wizard's single-shot `config/create` covers the 50 backends that only need
/// answers. The other 19 — Drive, Dropbox, OneDrive, Box and the rest — ask questions
/// that depend on earlier answers and then hand off to a browser, and a form cannot
/// express that.
///
/// rclone models it as a state machine. `config/create` with `nonInteractive` returns
/// the next question rather than failing, and the caller answers with `config/update`
/// carrying the state token and the chosen value. The question comes back in the same
/// schema as `config/providers`, so the same parser and the same form controls work
/// for both.
extension RcloneRCClient {

    /// Where the state machine is.
    public enum ConfigStep: Sendable, Equatable {
        /// Nothing more to ask: the remote exists.
        case finished
        /// Present this, then call `continueConfiguring` with the answer.
        case question(ProviderOption, state: String)

        public var option: ProviderOption? {
            if case .question(let option, _) = self { return option }
            return nil
        }
    }

    /// How long a step may take.
    ///
    /// The browser step blocks the rc call for as long as the person takes: finding a
    /// password, approving on a phone, choosing an account. Measured against Drive,
    /// the call does not return until that is done. Ten minutes is generous enough not
    /// to cancel a flow somebody is still completing, and short enough that an
    /// abandoned one does not hang forever.
    static let interactiveStepTimeout: TimeInterval = 600

    /// Begin configuring a remote that asks questions.
    public func beginConfiguring(name: String, type: String,
                                 parameters: [String: String] = [:]) async throws -> ConfigStep {
        let result = try await call("config/create", [
            "name": .string(name),
            "type": .string(type),
            "parameters": .object(parameters.mapValues { JSONValue.string($0) }),
            "opt": .object(["nonInteractive": .bool(true), "obscure": .bool(true)]),
        ], timeout: Self.interactiveStepTimeout)

        return try Self.step(from: result)
    }

    /// Answer the current question and get the next one.
    public func continueConfiguring(name: String, state: String,
                                    answer: String) async throws -> ConfigStep {
        let result = try await call("config/update", [
            "name": .string(name),
            "parameters": .object([:]),
            "opt": .object([
                "nonInteractive": .bool(true),
                "obscure": .bool(true),
                "continue": .bool(true),
                "state": .string(state),
                "result": .string(answer),
            ]),
        ], timeout: Self.interactiveStepTimeout)

        return try Self.step(from: result)
    }

    /// Read a step out of a config/create or config/update reply.
    ///
    /// `Error` is a string rather than an HTTP failure: rclone answers 200 and puts
    /// the problem in the body, so a caller that only checks the status code sees a
    /// broken flow as a successful one.
    static func step(from value: JSONValue) throws -> ConfigStep {
        if let error = value["Error"]?.stringValue, !error.isEmpty {
            throw RcloneRCError.unexpectedResponse(error)
        }

        // No state and no question means there is nothing left to ask.
        guard let state = value["State"]?.stringValue, !state.isEmpty,
              let optionValue = value["Option"], optionValue != .null,
              let option = parseOption(optionValue)
        else { return .finished }

        return .question(option, state: state)
    }
}

extension RcloneRCClient.ProviderOption {

    /// Whether this step is the one that opens a browser.
    ///
    /// rclone opens the browser itself and runs its own redirect listener — grrclone
    /// does not need to, and should not try. Recognising the step matters only so the
    /// UI can say what is about to happen, because otherwise the window simply stops
    /// responding to the user while a call blocks for minutes.
    public var isBrowserSignIn: Bool {
        name == "config_is_local" || name.hasPrefix("config_oauth")
    }
}
