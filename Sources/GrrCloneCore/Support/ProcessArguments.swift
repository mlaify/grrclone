import Darwin

/// A process's command line, read from the kernel with `sysctl(KERN_PROCARGS2)`.
///
/// Not `/bin/ps`. It is setuid root, and a sandboxed process — App Sandbox, `sandbox-exec`,
/// a build sandbox — is never allowed to run a setuid program, so every identification
/// made from inside one failed before it started. The kernel hands a process's own user
/// the same arguments `ps -o command=` prints, without a helper process, a pipe or a
/// timeout to get wrong.
enum ProcessArguments {
    /// The arguments of `pid`, or nil when the kernel will not give them.
    ///
    /// Nil covers a process that is gone, one that belongs to another user, a zombie and
    /// one caught mid-exec. The kernel answers EINVAL for all of them, so nil is "no
    /// answer", never evidence that the process is someone else's. Callers that need to
    /// tell "gone" apart ask `kill(pid, 0)`.
    static func read(pid: Int32) -> [String]? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(buffer.prefix(size))
    }

    /// The command line as `ps -o command=` prints it: the arguments joined by spaces.
    static func commandLine(pid: Int32) -> String? {
        read(pid: pid)?.joined(separator: " ")
    }

    /// Splits a `KERN_PROCARGS2` buffer: `argc` as an Int32, the executable path, NUL
    /// padding, then `argc` NUL-terminated arguments (the environment follows and is
    /// ignored). A buffer that ends before `argc` arguments is malformed, not short.
    static func parse<Bytes: Collection>(_ bytes: Bytes) -> [String]? where Bytes.Element == UInt8 {
        let bytes = Array(bytes)
        let header = MemoryLayout<Int32>.size
        guard bytes.count > header else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }

        var i = header
        while i < bytes.count, bytes[i] != 0 { i += 1 }   // executable path
        while i < bytes.count, bytes[i] == 0 { i += 1 }   // padding

        var arguments: [String] = []
        while arguments.count < argc, i < bytes.count {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            guard i < bytes.count else { return nil }      // unterminated
            arguments.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return arguments.count == Int(argc) ? arguments : nil
    }
}
