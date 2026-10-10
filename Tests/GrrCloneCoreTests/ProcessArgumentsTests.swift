import XCTest
@testable import GrrCloneCore

/// Reading a process's arguments from the kernel instead of `/bin/ps`, which is setuid
/// and cannot run inside a sandbox at all.
final class ProcessArgumentsTests: XCTestCase {

    func testReadsItsOwnArguments() {
        XCTAssertEqual(ProcessArguments.read(pid: getpid()), CommandLine.arguments)
    }

    func testReadsAChildsArguments() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }

        XCTAssertEqual(ProcessArguments.read(pid: child.processIdentifier), ["/bin/sleep", "30"])
        XCTAssertEqual(ProcessArguments.commandLine(pid: child.processIdentifier), "/bin/sleep 30")
    }

    /// No answer for a process that is gone; `identify` then asks `kill(pid, 0)`.
    func testAGoneProcessHasNoArguments() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()

        XCTAssertNil(ProcessArguments.read(pid: child.processIdentifier))
    }

    // MARK: - Buffer layout

    private func buffer(argc: Int32, _ tail: String) -> [UInt8] {
        withUnsafeBytes(of: argc) { Array($0) } + Array(tail.utf8)
    }

    func testParsesArgumentsAfterThePathAndPadding() {
        let bytes = buffer(argc: 2, "/usr/local/bin/rclone\0\0\0\0rclone\0rcd --rc-addr\0HOME=/x\0")
        XCTAssertEqual(ProcessArguments.parse(bytes), ["rclone", "rcd --rc-addr"])
    }

    func testRejectsMalformedBuffers() {
        XCTAssertNil(ProcessArguments.parse([UInt8]()), "empty")
        XCTAssertNil(ProcessArguments.parse(buffer(argc: 0, "/bin/x\0\0")), "no arguments")
        XCTAssertNil(ProcessArguments.parse(buffer(argc: 3, "/bin/x\0\0a\0b\0")), "fewer than argc")
        XCTAssertNil(ProcessArguments.parse(buffer(argc: 1, "/bin/x\0\0abc")), "unterminated")
    }
}
