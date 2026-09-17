import XCTest
@testable import RcloneRC

/// Replies captured from rclone 1.75.1 while walking a Google Drive setup, because
/// the shape of this reply is the whole contract and inventing it proves nothing.
final class InteractiveConfigTests: XCTestCase {

    private func step(_ json: String) throws -> RcloneRCClient.ConfigStep {
        try RcloneRCClient.step(from: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    /// The first reply from `config/create` for Google Drive, verbatim.
    func testReadsTheFirstQuestion() throws {
        let reply = """
        {"Error":"","Option":{"Advanced":false,"Default":false,"DefaultStr":"false",
         "Examples":[{"Help":"Yes","Value":"true"},{"Help":"No","Value":"false"}],
         "Exclusive":true,"FieldName":"","Help":"Continue using the shared client_id anyway?",
         "Hide":0,"IsPassword":false,"Name":"config_shared_client_id","NoPrefix":false,
         "Required":false,"Sensitive":false,"Type":"bool","Value":null,"ValueStr":"false"},
         "Result":"","State":"client_id_warning"}
        """
        guard case .question(let option, let state) = try step(reply) else {
            return XCTFail("expected a question")
        }
        XCTAssertEqual(state, "client_id_warning")
        XCTAssertEqual(option.name, "config_shared_client_id")
        XCTAssertEqual(option.type, "bool")
        XCTAssertTrue(option.exclusive)
        XCTAssertEqual(option.examples.count, 2)
    }

    /// The state token is not a tidy identifier; it is rclone's own encoding and must
    /// be passed back untouched.
    func testCarriesAnAwkwardStateTokenVerbatim() throws {
        let reply = """
        {"Error":"","Option":{"Name":"config_is_local","Help":"Use web browser?",
         "Type":"bool","Hide":0},"Result":"","State":"*oauth-islocal,teamdrive,oauth,"}
        """
        guard case .question(_, let state) = try step(reply) else { return XCTFail("expected a question") }
        XCTAssertEqual(state, "*oauth-islocal,teamdrive,oauth,")
    }

    func testNoStateMeansFinished() throws {
        XCTAssertEqual(try step(#"{"Error":"","Option":null,"Result":"","State":""}"#), .finished)
    }

    func testAMissingOptionMeansFinished() throws {
        XCTAssertEqual(try step(#"{"Error":"","Result":"","State":""}"#), .finished)
    }

    /// rclone answers 200 and puts the problem in the body. A caller that only checks
    /// the status code would treat a broken flow as a successful one.
    func testAnErrorInTheBodyIsThrownRatherThanIgnored() {
        let reply = #"{"Error":"didn't find section in config file","Option":null,"State":""}"#
        XCTAssertThrowsError(try step(reply))
    }

    func testAnErrorIsThrownEvenWhenAQuestionIsAlsoPresent() {
        let reply = """
        {"Error":"something went wrong","Option":{"Name":"x","Type":"string","Hide":0},
         "State":"somewhere"}
        """
        XCTAssertThrowsError(try step(reply))
    }

    /// The browser step is recognised so the UI can say what is about to happen —
    /// otherwise the window just stops responding while a call blocks for minutes.
    func testRecognisesTheBrowserStep() {
        func option(_ name: String) -> RcloneRCClient.ProviderOption {
            RcloneRCClient.ProviderOption(name: name, help: "", type: "bool", required: false,
                                          advanced: false, hide: 0, isPassword: false,
                                          sensitive: false, defaultValue: "", examples: [],
                                          exclusive: false, providerGate: "")
        }
        XCTAssertTrue(option("config_is_local").isBrowserSignIn)
        XCTAssertTrue(option("config_oauth_url").isBrowserSignIn)
        XCTAssertFalse(option("config_shared_client_id").isBrowserSignIn)
        XCTAssertFalse(option("teamdrive").isBrowserSignIn)
    }

    /// Long enough that a person choosing an account and approving on a phone is not
    /// cut off; short enough that an abandoned flow does not hang forever.
    func testTheInteractiveTimeoutIsGenerous() {
        XCTAssertGreaterThanOrEqual(RcloneRCClient.interactiveStepTimeout, 300)
        XCTAssertLessThanOrEqual(RcloneRCClient.interactiveStepTimeout, 1800)
    }
}
