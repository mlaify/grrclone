import CommonCrypto
import Foundation

/// rclone's reversible "obscure" encoding, done in process.
///
/// rclone stores passwords in its config obscured, not encrypted: AES-256-CTR under a
/// key published in rclone's own source (`fs/config/obscure`), with a random 16-byte
/// IV prepended and the result base64url-encoded without padding. Anyone with rclone
/// can reverse it, which is the point — it only stops a password being read at a
/// glance.
///
/// grrclone used to reverse it by running `rclone reveal -- <obscured>`, and that put
/// the value on a command line. macOS lets every local account read every other
/// account's process arguments, and since obscuring is reversible, that was the
/// plaintext credential in the process list for as long as the helper ran (#156).
/// `rclone reveal` cannot read stdin instead: given `-`, it tries to decode `-`.
/// Doing it here means the value never leaves this process.
///
/// Verified against rclone 1.75.1's own `obscure` output in both directions, including
/// values that begin with a dash, Unicode, and the empty string; see ObscureTests.
public enum RcloneObscure {

    public enum Failure: Error, LocalizedError, Equatable {
        case notObscured
        case cryptFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .notObscured: return "The stored value is not in rclone's obscured format."
            case .cryptFailed(let status): return "Could not decode the stored value (\(status))."
            }
        }
    }

    /// rclone's obscure key. **Not a secret**: it is published in rclone's source and
    /// every copy of rclone contains it. It is here only so the encoding can be
    /// reversed without spawning a process. Nothing grrclone protects depends on it.
    private static let publishedRcloneKey: [UInt8] = [
        0x9c, 0x93, 0x5b, 0x48, 0x73, 0x0a, 0x55, 0x4d,
        0x6b, 0xfd, 0x7c, 0x63, 0xc8, 0x86, 0xa9, 0x2b,
        0xd3, 0x90, 0x19, 0x8e, 0xb8, 0x12, 0x8a, 0xfb,
        0xf4, 0xde, 0x16, 0x2b, 0x8b, 0x95, 0xf6, 0x38,
    ]
    private static let ivLength = kCCBlockSizeAES128

    /// The plaintext behind an obscured value.
    public static func reveal(_ obscured: String) throws -> String {
        guard let data = decodeBase64URL(obscured), data.count >= ivLength else { throw Failure.notObscured }
        let iv = [UInt8](data.prefix(ivLength))
        let body = [UInt8](data.dropFirst(ivLength))
        let plain = try ctr(body, iv: iv)
        guard let text = String(bytes: plain, encoding: .utf8) else { throw Failure.notObscured }
        return text
    }

    /// Obscure a value as rclone would, with a fresh random IV. Used by tests to prove
    /// rclone reads back what this writes.
    public static func obscure(_ plain: String) throws -> String {
        var iv = [UInt8](repeating: 0, count: ivLength)
        guard SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv) == errSecSuccess else {
            throw Failure.cryptFailed(-1)
        }
        let body = try ctr(Array(plain.utf8), iv: iv)
        return encodeBase64URL(Data(iv + body))
    }

    /// AES-256-CTR is its own inverse, so one function both ways. Big-endian counter
    /// over the whole block, which is what Go's `cipher.NewCTR` does.
    private static func ctr(_ input: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var cryptor: CCCryptorRef?
        var status = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding), iv, publishedRcloneKey, publishedRcloneKey.count,
            nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        guard status == kCCSuccess, let cryptor else { throw Failure.cryptFailed(status) }
        defer { CCCryptorRelease(cryptor) }

        guard !input.isEmpty else { return [] }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        status = CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess, moved == input.count else { throw Failure.cryptFailed(status) }
        return output
    }

    static func decodeBase64URL(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        // rclone uses RawURLEncoding: no padding. A string that already has `=` is not
        // one of rclone's, and the length rule below catches it.
        guard !b.contains("=") else { return nil }
        let remainder = b.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 { b += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: b)
    }

    static func encodeBase64URL(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
