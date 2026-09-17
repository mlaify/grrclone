import XCTest
@testable import RcloneRC

/// Parsed from real `config/providers` output captured from rclone 1.75.1, trimmed to
/// five backends. The schema is 69 providers and 968 options and changes with every
/// rclone release, so inventing a fixture would only prove the code agrees with the
/// invention.
final class ProvidersTests: XCTestCase {

    private var providers: [RcloneRCClient.Provider] = []

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "providers", withExtension: "json"),
                                "fixture missing from the test bundle")
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        providers = RcloneRCClient.parseProviders(value)
    }

    private func provider(_ name: String) throws -> RcloneRCClient.Provider {
        try XCTUnwrap(providers.first { $0.name == name }, "no provider \(name)")
    }

    // MARK: Parsing

    func testParsesTheFixture() throws {
        XCTAssertEqual(providers.count, 5)
        XCTAssertEqual(try provider("webdav").description, "WebDAV")
        XCTAssertFalse(try provider("s3").options.isEmpty)
    }

    func testProvidersAreSortedByWhatTheUserReads() {
        let descriptions = providers.map(\.description)
        XCTAssertEqual(descriptions, descriptions.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }, "the picker shows descriptions, so they must be the sort key")
    }

    func testReadsTheFieldsAFormNeeds() throws {
        let url = try XCTUnwrap(try provider("webdav").options.first { $0.name == "url" })
        XCTAssertTrue(url.required)
        XCTAssertFalse(url.advanced)
        XCTAssertEqual(url.type, "string")
        XCTAssertTrue(url.help.contains("URL"))
        XCTAssertEqual(url.summary, "URL of http host to connect to.",
                       "the summary is the first line, for a label")
    }

    /// A password must reach the UI marked as one, or it is typed in the clear.
    func testPasswordsAreMarked() throws {
        let pass = try XCTUnwrap(try provider("webdav").options.first { $0.name == "pass" })
        XCTAssertTrue(pass.isPassword || pass.sensitive)
    }

    func testReadsExamples() throws {
        let vendor = try XCTUnwrap(try provider("s3").options.first { $0.name == "provider" })
        XCTAssertGreaterThan(vendor.examples.count, 10)
        XCTAssertTrue(vendor.examples.contains { $0.value == "AWS" })
        XCTAssertTrue(vendor.examples.contains { $0.help.contains("Amazon") })
    }

    // MARK: OAuth detection

    /// Detected from the presence of a token option rather than a list of names, so a
    /// new OAuth backend is recognised without a code change.
    func testRecognisesAnOAuthBackend() throws {
        XCTAssertTrue(try provider("drive").requiresOAuth)
        XCTAssertFalse(try provider("webdav").requiresOAuth)
        XCTAssertFalse(try provider("local").requiresOAuth)
    }

    // MARK: Sub-provider gating

    /// S3 is really thirty backends wearing a coat. Ignoring the gate is how you ask
    /// an AWS user for a Cloudflare account ID.
    func testSubProviderGatingHidesOtherVendorsOptions() throws {
        let s3 = try provider("s3")

        let forAWS = Set(s3.visibleOptions(values: ["provider": "AWS"],
                                           includeAdvanced: true).map(\.name))
        let forCloudflare = Set(s3.visibleOptions(values: ["provider": "Cloudflare"],
                                                  includeAdvanced: true).map(\.name))

        XCTAssertNotEqual(forAWS, forCloudflare, "the two vendors must not ask the same questions")
        XCTAssertFalse(forAWS.isEmpty)
    }

    func testAnUngatedOptionIsAlwaysOffered() throws {
        let s3 = try provider("s3")
        for vendor in ["AWS", "Ceph", "Other", ""] {
            let names = Set(s3.visibleOptions(values: ["provider": vendor],
                                              includeAdvanced: true).map(\.name))
            XCTAssertTrue(names.contains("provider"),
                          "the vendor picker itself must survive every selection")
        }
    }

    /// The single negated gate in the whole schema. One case is exactly what gets
    /// missed, so it is tested against the real thing.
    func testANegatedGateInvertsTheList() {
        XCTAssertTrue(RcloneRCClient.Provider.gateAllows("!no_auth", selected: "user_principal"))
        XCTAssertFalse(RcloneRCClient.Provider.gateAllows("!no_auth", selected: "no_auth"))
    }

    func testTheRealNegatedOptionBehavesThatWay() throws {
        let oracle = try provider("oracleobjectstorage")
        let withNoAuth = Set(oracle.visibleOptions(values: ["provider": "no_auth"],
                                                   includeAdvanced: true).map(\.name))
        let withOther = Set(oracle.visibleOptions(values: ["provider": "user_principal_auth"],
                                                  includeAdvanced: true).map(\.name))
        XCTAssertFalse(withNoAuth.contains("compartment"))
        XCTAssertTrue(withOther.contains("compartment"))
    }

    func testAnEmptyGateAdmitsEverything() {
        XCTAssertTrue(RcloneRCClient.Provider.gateAllows("", selected: ""))
        XCTAssertTrue(RcloneRCClient.Provider.gateAllows("", selected: "anything"))
    }

    func testGateListsTolerateSpaces() {
        XCTAssertTrue(RcloneRCClient.Provider.gateAllows("AWS, Ceph , Other", selected: "Ceph"))
    }

    // MARK: What the form shows

    /// 968 options across all providers, almost none needed to connect. A form that
    /// shows them all is not a wizard.
    func testAdvancedOptionsAreHeldBack() throws {
        let s3 = try provider("s3")
        let basic = s3.visibleOptions(values: ["provider": "AWS"])
        let all = s3.visibleOptions(values: ["provider": "AWS"], includeAdvanced: true)

        XCTAssertLessThan(basic.count, all.count)
        XCTAssertFalse(basic.contains { $0.advanced })
    }

    /// rclone marks options its own interactive config does not ask. Showing them
    /// would be asking the user to fill in fields the tool considers internal.
    func testHiddenOptionsAreNeverShown() throws {
        for p in providers {
            let shown = p.visibleOptions(values: [:], includeAdvanced: true)
            XCTAssertFalse(shown.contains { $0.hide != 0 },
                           "\(p.name) offered a hidden option")
        }
    }

    // MARK: Validation

    func testRequiredOptionsWithNoValueBlockSubmission() throws {
        let webdav = try provider("webdav")
        let missing = webdav.missingRequired(values: [:])
        XCTAssertTrue(missing.contains { $0.name == "url" })
    }

    func testFillingTheRequiredOptionClearsIt() throws {
        let webdav = try provider("webdav")
        let missing = webdav.missingRequired(values: ["url": "https://dav.example.com"])
        XCTAssertFalse(missing.contains { $0.name == "url" })
    }

    /// An option with a default is not missing just because the user left it alone.
    func testAnOptionWithADefaultIsNotMissing() throws {
        for p in providers {
            for option in p.missingRequired(values: [:]) {
                XCTAssertTrue(option.defaultValue.isEmpty,
                              "\(p.name).\(option.name) has a default and should not be required input")
            }
        }
    }

    /// Validation must respect gating, or a form can be unsubmittable because of a
    /// required field belonging to a vendor the user did not choose.
    func testValidationIgnoresOtherVendorsRequiredOptions() throws {
        let s3 = try provider("s3")
        let missing = s3.missingRequired(values: ["provider": "AWS"])
        let names = Set(missing.map(\.name))
        let awsVisible = Set(s3.visibleOptions(values: ["provider": "AWS"],
                                               includeAdvanced: true).map(\.name))
        XCTAssertTrue(names.isSubset(of: awsVisible),
                      "required options from other vendors leaked into validation: \(names.subtracting(awsVisible))")
    }
}
