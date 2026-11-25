import CProcessGuard
import CZstd
import CodeInsightCore
import Darwin
import Foundation
import zlib

/// One remote directory reached through the system `/usr/bin/ssh`.
///
/// Cairn runs its own control master (a short socket path under `/tmp`) so
/// every later command reuses one authenticated, uncompressed connection, and
/// keeps one remote read loop on it for directory listings, hashes and file
/// reads. Bulk source capture is a separate command whose output the remote
/// side compresses (`zstd -3 --long=27`, else `gzip -1`).
///
/// Nothing is ever written on the remote host: the scripts arrive on the
/// command's standard input, and every value (the directory, each path)
/// follows them there; the remote command line is only an interpreter and a
/// constant, single-quoted bootstrap.
///
/// A loop that times out or goes away leaves the transport disconnected: every
/// request throws `Failure.disconnected` (or `.timedOut`) until `connect()`
/// is called again; a failed read is never an empty result.
public final class SSHTransport: @unchecked Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        /// The host name or remote path cannot be used.
        case invalidTarget(String)
        /// ssh could not connect (authentication, an unreachable host, a
        /// prompt BatchMode refused). `command` can be copied into a terminal.
        case connectFailed(message: String, command: String)
        /// The connection or the remote helper went away.
        case disconnected(String)
        /// A remote operation made no progress within the timeout; the
        /// connection is treated as lost.
        case timedOut(String)
        /// The remote side cannot serve the directory: missing tools, an
        /// unreadable root, an unexpected answer.
        case remote(String)

        /// Whether the link itself is gone, as opposed to a refusal.
        public var isConnectionLoss: Bool {
            switch self {
            case .disconnected, .timedOut: true
            default: false
            }
        }

        public var errorDescription: String? {
            switch self {
            case let .invalidTarget(message): "invalid remote target: \(message)"
            case let .connectFailed(message, command): "ssh could not connect: \(message) (\(command))"
            case let .disconnected(message): "remote connection lost: \(message)"
            case let .timedOut(message): "remote operation timed out: \(message)"
            case let .remote(message): "remote error: \(message)"
            }
        }
    }

    /// The ssh host name (`~/.ssh/config` alias); nil for a test prefix.
    public let host: String?
    /// Absolute directory on the remote host.
    public let remotePath: String
    /// Longest wait for any progress of one remote operation.
    public let timeout: TimeInterval

    private let commandPrefix: [String]
    private let controlPath: String?
    private let forceShellScripts: Bool
    private let forceGzip: Bool

    private let lock = NSLock()
    private var master: Channel?
    private var loop: Channel?
    private var interpreter: Interpreter?
    private var connectionLossHandler: (@Sendable (Failure) -> Void)?
    /// The compressed format of the last capture stream, for tests.
    private(set) var lastCaptureFormat: String?
    /// What the last capture and hash requests asked for, for tests.
    private(set) var lastCapturedPaths: [String] = []
    private(set) var lastHashedPaths: [String] = []

    /// No connection is made until `connect()`.
    public convenience init(host: String, remotePath: String, timeout: TimeInterval = 30) throws {
        guard Self.isUsableHost(host) else { throw Failure.invalidTarget("host \(host)") }
        let controlPath = try Self.controlSocketPath(host: host, remotePath: remotePath)
        try self.init(
            host: host,
            remotePath: remotePath,
            commandPrefix: ["/usr/bin/ssh"] + Self.commonOptions(controlPath)
                + ["-o", "ControlMaster=no", "--", host],
            controlPath: controlPath,
            timeout: timeout
        )
    }

    /// Runs the remote command by appending it to `commandPrefix` (which must
    /// behave like ssh: join its arguments and hand them to a login shell).
    /// The two flags force the fallbacks a host without `python3` or `zstd`
    /// takes.
    init(
        host: String? = nil,
        remotePath: String,
        commandPrefix: [String],
        controlPath: String? = nil,
        timeout: TimeInterval = 30,
        forceShellScripts: Bool = false,
        forceGzip: Bool = false
    ) throws {
        guard remotePath.hasPrefix("/"), !remotePath.contains("\0") else {
            throw Failure.invalidTarget("path \(remotePath) is not absolute")
        }
        guard ci_process_guard_install() else { throw Failure.remote("cannot guard child processes") }
        self.host = host
        self.remotePath = remotePath
        self.commandPrefix = commandPrefix
        self.controlPath = controlPath
        self.timeout = timeout
        self.forceShellScripts = forceShellScripts
        self.forceGzip = forceGzip
    }

    deinit { close() }

    /// A name ssh can only read as a host: not empty, no leading `-` (an
    /// option), no whitespace or control characters.
    public static func isUsableHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-")
            && !host.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 || $0 == "\u{7F}" }
    }

    public var isConnected: Bool { lock.withLock { loop?.isOpen == true } }

    /// Called (on the failing thread) whenever a request or capture finds the
    /// link gone or timed out, so a window can show it is disconnected
    /// however the failure was reported to the caller.
    public var onConnectionLoss: (@Sendable (Failure) -> Void)? {
        get { lock.withLock { connectionLossHandler } }
        set { lock.withLock { connectionLossHandler = newValue } }
    }

    /// Starts the control master (for a real host), probes the remote tools
    /// and starts the read loop. Does nothing while the loop is running; after
    /// a disconnect it connects again. Cancelling the calling task stops it.
    public func connect() throws {
        try lock.withLock {
            if loop?.isOpen == true { return }
            loop?.terminate()
            loop = nil
            try startMasterIfNeeded()
            let found = try exec(
                "for c in python3 bash; do command -v \"$c\"; done",
                input: [], cancellable: true
            )
            let tools = String(decoding: found.output, as: UTF8.self).split(separator: "\n")
            let hasPython = tools.contains { $0.hasSuffix("python3") }
            let hasBash = tools.contains { $0.hasSuffix("bash") }
            guard hasBash else { throw Failure.remote("the remote host has no bash") }
            let interpreter: Interpreter = hasPython && !forceShellScripts ? .python : .bash
            let channel = try spawn(interpreter.bootstrap)
            channel.send(interpreter.payload + Self.field(remotePath) + Self.field("loop"))
            do {
                let line = try channel.readLine(idle: timeout, cancellable: true)
                guard line == Array("ready".utf8) else {
                    channel.terminate()
                    throw Failure.remote("cannot read \(remotePath)")
                }
            } catch Failure.disconnected {
                let status = channel.terminate()
                throw Self.failure(status: status, stderr: channel.errorTail, during: "starting the remote reader")
            } catch {
                channel.terminate()
                throw error
            }
            self.interpreter = interpreter
            loop = channel
        }
    }

    /// Stops the read loop and the control master and removes the socket.
    public func close() {
        lock.withLock {
            loop?.terminate()
            loop = nil
            guard let controlPath, let host, let master else { return }
            if master.isRunning {
                _ = try? runToEnd(["/usr/bin/ssh", "-o", "ControlPath=\(controlPath)", "-O", "exit", "--", host])
            }
            master.terminate()
            self.master = nil
            unlink(controlPath)
        }
    }

    /// The file's current remote bytes; nil when it is gone or not a readable
    /// regular file. `path` is relative to the remote directory.
    ///
    /// The reader opens files on the main thread, so once its request is
    /// sent a read waits at most 5 s without progress before the link counts
    /// as lost (a file that keeps arriving is not cut off). Waiting for the
    /// connection itself comes on top: another request in flight, or a
    /// `connect()` in progress (up to `timeout`). The remote side sends a
    /// file only after reading all of it, so a huge file on a cold disk can
    /// also take longer than 5 s and read as a lost link.
    public func readFile(_ path: String) throws -> [UInt8]? {
        try Self.checkRelative(path)
        let idle = min(timeout, 5)
        return try request(Array("R\0".utf8) + Self.field(path)) { channel in
            let header = try channel.readLine(idle: idle)
            if header == Array("gone".utf8) { return nil }
            guard let count = Self.okCount(header) else { throw Failure.remote("unexpected read answer") }
            return try channel.read(count: count, idle: idle)
        }
    }

    // MARK: Requests used by RemoteSnapshot

    struct Entry {
        let isDirectory: Bool
        let name: [UInt8]
        /// A file's size and modification time as the remote side states
        /// them; nil when it could not say. The time is an opaque token,
        /// only ever compared with one from the same remote reader.
        var size: UInt64?
        var stamp: String?
    }

    /// The directory and regular-file entries of each directory (symlinks
    /// and other kinds left out); nil for a directory that cannot be read.
    /// A file record is `f<size>/<mtime>/<name>`: a name never holds `/`.
    func list(_ directories: [String]) throws -> [[Entry]?] {
        try batch("L", directories) { channel in
            let status = try channel.readLine(idle: timeout)
            if status == Array("err".utf8) { return nil }
            guard status == Array("ok".utf8) else { throw Failure.remote("unexpected listing answer") }
            var entries: [Entry] = []
            while true {
                let record = try channel.readField(idle: timeout)
                guard let kind = record.first else { return entries }
                let rest = record.dropFirst()
                if kind == UInt8(ascii: "d") {
                    entries.append(Entry(isDirectory: true, name: Array(rest)))
                    continue
                }
                let parts = rest.split(separator: UInt8(ascii: "/"), maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { throw Failure.remote("unexpected listing record") }
                let size = UInt64(String(decoding: parts[0], as: UTF8.self))
                let stamp = String(decoding: parts[1], as: UTF8.self)
                entries.append(Entry(
                    isDirectory: false, name: Array(parts[2]),
                    size: size, stamp: size == nil || stamp.isEmpty ? nil : stamp
                ))
            }
        }
    }

    /// Size, SHA-256 and whether the file starts like a Git LFS pointer,
    /// computed remotely; nil for a file that cannot be read.
    func hash(_ files: [String]) throws -> [(size: UInt64, contentID: ContentID, isLFSPointer: Bool)?] {
        lock.withLock { lastHashedPaths = files }
        return try batch("H", files) { channel in
            let line = String(decoding: try channel.readLine(idle: timeout), as: UTF8.self)
            if line == "err" { return nil }
            let fields = line.split(separator: " ")
            guard fields.count == 4, fields[0] == "ok", let size = UInt64(fields[1]),
                  let digest = Self.bytes(hex: fields[2]), digest.count == 32
            else { throw Failure.remote("unexpected hash answer") }
            return (size, ContentID(algorithm: 1, bytes: digest), fields[3] == "1")
        }
    }

    /// Reads `files` in one compressed stream, calling `each` in order with
    /// a file's bytes or nil when the remote side could not read it. Runs as
    /// its own command beside the loop; cancelling the task stops it.
    func capture(_ files: [String], each: (Int, [UInt8]?) throws -> Void) throws {
        lock.withLock { lastCapturedPaths = files }
        guard !files.isEmpty else { return }
        do {
            try streamCapture(files, each: each)
        } catch let failure as Failure where failure.isConnectionLoss {
            reportConnectionLoss(failure)
            throw failure
        }
    }

    private func streamCapture(_ files: [String], each: (Int, [UInt8]?) throws -> Void) throws {
        let interpreter = try lock.withLock {
            guard let interpreter, loop?.isOpen == true else { throw Failure.disconnected("not connected") }
            return interpreter
        }
        let channel = try spawn(interpreter.bootstrap)
        defer { channel.terminate() }
        channel.send(
            interpreter.payload + Self.field(remotePath) + Self.field("capture")
                + Self.field(forceGzip ? "gzip" : "auto") + files.flatMap(Self.field)
        )
        channel.closeInputWhenSent()
        var decoder: Decoder?
        var plain: [UInt8] = []
        var cursor = 0
        var index = 0
        func more() throws -> Bool {
            guard let chunk = try channel.nextChunk(idle: timeout, cancellable: true) else { return false }
            if decoder == nil {
                let started = try Decoder(magic: chunk)
                decoder = started
                lock.withLock { lastCaptureFormat = started.format }
            }
            plain += try decoder!.decode(chunk)
            return true
        }
        func streamEnded() -> Failure {
            let status = channel.terminate()
            if decoder == nil, status != 255 {
                return Self.failure(status: status, stderr: channel.errorTail, during: "capturing sources")
            }
            return Self.failure(status: 255, stderr: channel.errorTail, during: "capture stream ended early")
        }
        while index < files.count {
            if cursor > 1 << 20 {
                plain.removeFirst(cursor)
                cursor = 0
            }
            let newline: Int
            if let found = plain[cursor...].firstIndex(of: 0x0A) {
                newline = found
            } else {
                guard try more() else { throw streamEnded() }
                continue
            }
            let header = Array(plain[cursor..<newline])
            if header == Array("gone".utf8) {
                cursor = newline + 1
                try each(index, nil)
                index += 1
                continue
            }
            guard let count = Self.okCount(header) else { throw Failure.remote("bad capture frame") }
            while plain.count - (newline + 1) < count {
                guard try more() else { throw streamEnded() }
            }
            let start = newline + 1
            cursor = start + count
            try each(index, Array(plain[start..<cursor]))
            index += 1
        }
        while try more() {}
        guard decoder?.finished == true, cursor == plain.count else {
            throw Failure.remote("capture stream has trailing or truncated data")
        }
    }

    var commandPrefixForTests: [String] { commandPrefix }
    var controlPathForTests: String? { controlPath }

    /// The read loop's process, for tests that cut the connection.
    var loopProcessIdentifier: pid_t? { lock.withLock { loop?.pid } }

    // MARK: Plumbing

    private enum Interpreter {
        case python, bash

        var bootstrap: String {
            switch self {
            case .python: "python3 -c 'import sys;b=sys.stdin.buffer;exec(b.read(int(b.readline())))'"
            case .bash: "bash -c 'IFS= read -r -d \"\" s;eval \"$s\"'"
            }
        }

        var payload: [UInt8] {
            switch self {
            case .python:
                let script = Array(remotePythonScript.utf8)
                return Array("\(script.count)\n".utf8) + script
            case .bash:
                return Array(remoteBashScript.utf8) + [0]
            }
        }
    }

    private func request<T>(_ bytes: [UInt8], _ answer: (Channel) throws -> T) throws -> T {
        do {
            return try lock.withLock {
                guard let channel = loop, channel.isOpen else { throw Failure.disconnected("not connected") }
                channel.send(bytes)
                do {
                    return try answer(channel)
                } catch {
                    // A half-read answer leaves the stream out of step.
                    channel.terminate()
                    loop = nil
                    if case Failure.disconnected = error {
                        throw Self.failure(status: 255, stderr: channel.errorTail, during: "the remote reader stopped")
                    }
                    throw error
                }
            }
        } catch let failure as Failure where failure.isConnectionLoss {
            reportConnectionLoss(failure)
            throw failure
        }
    }

    private func reportConnectionLoss(_ failure: Failure) {
        lock.withLock { connectionLossHandler }?(failure)
    }

    private func batch<T>(_ op: String, _ paths: [String], _ answer: (Channel) throws -> T) throws -> [T] {
        guard !paths.isEmpty else { return [] }
        for path in paths where path != "." { try Self.checkRelative(path) }
        let bytes = Self.field(op) + Self.field(String(paths.count)) + paths.flatMap(Self.field)
        return try request(bytes) { channel in try paths.map { _ in try answer(channel) } }
    }

    private func startMasterIfNeeded() throws {
        guard let host, let controlPath else { return }
        if master?.isRunning == true { return }
        master?.terminate()
        unlink(controlPath)
        let arguments = ["/usr/bin/ssh", "-N"] + Self.commonOptions(controlPath) + [
            "-o", "ControlMaster=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "--", host,
        ]
        let channel = try Channel(arguments)
        let started = Date()
        while true {
            if try runToEnd(["/usr/bin/ssh", "-o", "ControlPath=\(controlPath)", "-O", "check", "--", host]) == 0 {
                master = channel
                return
            }
            if !channel.isRunning || Date().timeIntervalSince(started) > timeout || Task.isCancelled {
                channel.terminate()
                if Task.isCancelled { throw CancellationError() }
                throw Failure.connectFailed(
                    message: Self.lastLine(channel.errorTail) ?? "no answer within \(Int(timeout)) s",
                    command: "ssh -o BatchMode=yes -- \(Self.shellQuoted(host))"
                )
            }
            usleep(50_000)
        }
    }

    private static func commonOptions(_ controlPath: String) -> [String] {
        [
            "-o", "BatchMode=yes", "-o", "Compression=no",
            "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=no",
        ]
    }

    /// `/tmp/cairn-<uid>/<16 hex>`: well under the 104-byte socket limit
    /// after ssh appends its 17-character temporary suffix, and no spaces.
    private static func controlSocketPath(host: String, remotePath: String) throws -> String {
        let directory = "/tmp/cairn-\(getuid())"
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw Failure.invalidTarget("cannot create \(directory)")
        }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0
        else { throw Failure.invalidTarget("\(directory) is not a private directory") }
        removeDeadSockets(in: directory)
        let seed = "\(host)\0\(remotePath)\0\(getpid())\0\(UUID().uuidString)"
        let name = ContentID.sha256(of: Array(seed.utf8)).bytes.prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return "\(directory)/\(name)"
    }

    /// An app that quit or was killed leaves its socket files behind: remove
    /// those nothing listens on. Recent ones are left alone, a master still
    /// starting has bound its socket before it listens.
    private static func removeDeadSockets(in directory: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            let path = directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
                  time(nil) - info.st_mtimespec.tv_sec > 60
            else { continue }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard path.utf8.count < capacity else { continue }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { continue }
            let refused = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) != 0 && errno == ECONNREFUSED
                }
            }
            Darwin.close(descriptor)
            if refused { unlink(path) }
        }
    }

    private func spawn(_ remoteCommand: String) throws -> Channel {
        try Channel(commandPrefix + [remoteCommand])
    }

    private func exec(_ remoteCommand: String, input: [UInt8], cancellable: Bool) throws -> (output: [UInt8], status: Int32) {
        let channel = try spawn(remoteCommand)
        defer { channel.terminate() }
        channel.send(input)
        channel.closeInputWhenSent()
        var output: [UInt8] = []
        while let chunk = try channel.nextChunk(idle: timeout, cancellable: cancellable) { output += chunk }
        let status = channel.terminate()
        if status == 255 {
            throw Self.failure(status: status, stderr: channel.errorTail, during: "running a remote command")
        }
        return (output, status)
    }

    /// Runs a local command (ssh control requests) and returns its status.
    private func runToEnd(_ arguments: [String]) throws -> Int32 {
        let channel = try Channel(arguments)
        channel.closeInputWhenSent()
        while try channel.nextChunk(idle: timeout, cancellable: false) != nil {}
        return channel.terminate()
    }

    private static func failure(status: Int32, stderr: [UInt8], during operation: String) -> Failure {
        let line = lastLine(stderr)
        if status == 255 { return .disconnected(line ?? operation) }
        return .remote(line ?? "\(operation) failed (exit \(status))")
    }

    private static func lastLine(_ bytes: [UInt8]) -> String? {
        String(decoding: bytes, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func field(_ value: String) -> [UInt8] { Array(value.utf8) + [0] }

    private static func okCount(_ header: [UInt8]) -> Int? {
        let text = String(decoding: header, as: UTF8.self)
        guard text.hasPrefix("ok ") else { return nil }
        return Int(text.dropFirst(3)).flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func bytes(hex: Substring) -> [UInt8]? {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func checkRelative(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !components.contains(where: { $0 == ".." || $0.isEmpty })
        else { throw Failure.invalidTarget("path \(path)") }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A child process in its own process group, with its three standard streams
/// multiplexed by `poll` so writing a long request never waits on an unread
/// answer. `terminate()` kills the whole group, so a pipeline it started
/// cannot keep the streams open.
private final class Channel {
    let pid: pid_t
    private var input: Int32
    private var output: Int32
    private var errors: Int32
    private var inbox: [UInt8] = []
    private var start = 0
    private var outbox: [UInt8] = []
    private var sent = 0
    private var closeAfterSend = false
    private var status: Int32?
    private(set) var errorTail: [UInt8] = []

    init(_ arguments: [String]) throws {
        var stdinPipe: [Int32] = [0, 0], stdoutPipe: [Int32] = [0, 0], stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw SSHTransport.Failure.remote("cannot create pipes")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        let cArguments = arguments.map { strdup($0) } + [nil]
        defer {
            cArguments.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        var child: pid_t = 0
        let code = posix_spawn(&child, arguments[0], &actions, &attributes, cArguments, environ)
        Darwin.close(stdinPipe[0])
        Darwin.close(stdoutPipe[1])
        Darwin.close(stderrPipe[1])
        guard code == 0 else {
            [stdinPipe[1], stdoutPipe[0], stderrPipe[0]].forEach { Darwin.close($0) }
            throw SSHTransport.Failure.remote("cannot start \(arguments[0]): \(String(cString: strerror(code)))")
        }
        pid = child
        input = stdinPipe[1]
        output = stdoutPipe[0]
        errors = stderrPipe[0]
        for fd in [input, output, errors] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
        ci_process_guard_register(pid, true)
    }

    deinit { terminate() }

    var isOpen: Bool { output >= 0 && status == nil }

    var isRunning: Bool {
        guard status == nil else { return false }
        var code: Int32 = 0
        let result = waitpid(pid, &code, WNOHANG)
        if result == pid {
            status = Self.exitStatus(code)
            ci_process_guard_unregister(pid)
            return false
        }
        return true
    }

    func send(_ bytes: [UInt8]) {
        if sent == outbox.count {
            outbox.removeAll(keepingCapacity: true)
            sent = 0
        }
        outbox += bytes
    }

    func closeInputWhenSent() {
        closeAfterSend = true
        if sent == outbox.count { closeInput() }
    }

    /// Waits for progress on stdout; false once it has ended.
    private func pump(idle: TimeInterval, cancellable: Bool) throws -> Bool {
        var waited: TimeInterval = 0
        while output >= 0 {
            if cancellable, Task.isCancelled {
                terminate()
                throw CancellationError()
            }
            var fds = [pollfd(fd: output, events: Int16(POLLIN), revents: 0)]
            if errors >= 0 { fds.append(pollfd(fd: errors, events: Int16(POLLIN), revents: 0)) }
            let writing = input >= 0 && sent < outbox.count
            if writing { fds.append(pollfd(fd: input, events: Int16(POLLOUT), revents: 0)) }
            let ready = poll(&fds, nfds_t(fds.count), 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw SSHTransport.Failure.disconnected("poll failed")
            }
            if ready == 0 {
                waited += 0.1
                if waited >= idle {
                    terminate()
                    throw SSHTransport.Failure.timedOut("no answer within \(Int(idle.rounded(.up))) s")
                }
                continue
            }
            var progressed = false
            for item in fds where item.revents != 0 {
                if item.fd == input {
                    let count = outbox[sent...].withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
                    if count > 0 {
                        sent += count
                        if sent == outbox.count, closeAfterSend { closeInput() }
                    } else if count < 0, errno != EAGAIN {
                        // The reader is gone; what it said so far is still read.
                        sent = outbox.count
                        closeInput()
                    }
                } else if item.fd == errors {
                    if !readSome(errors, into: { errorTail = Array((errorTail + $0).suffix(4096)) }) {
                        Darwin.close(errors)
                        errors = -1
                    }
                } else if item.fd == output {
                    if readSome(output, into: { inbox += $0 }) {
                        progressed = true
                    } else {
                        Darwin.close(output)
                        output = -1
                        return false
                    }
                }
            }
            if progressed { return true }
            waited = 0
        }
        return false
    }

    /// False at end of stream.
    private func readSome(_ fd: Int32, into append: ([UInt8]) -> Void) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            append(Array(buffer[..<count]))
            return true
        }
        return count < 0 && (errno == EAGAIN || errno == EINTR)
    }

    /// The next bytes from stdout, or nil at its end.
    func nextChunk(idle: TimeInterval, cancellable: Bool) throws -> [UInt8]? {
        if start == inbox.count, try !pump(idle: idle, cancellable: cancellable) { return nil }
        let chunk = Array(inbox[start...])
        inbox.removeAll(keepingCapacity: true)
        start = 0
        return chunk
    }

    func readLine(idle: TimeInterval, cancellable: Bool = false) throws -> [UInt8] {
        try readUntil(0x0A, idle: idle, cancellable: cancellable)
    }

    func readField(idle: TimeInterval) throws -> [UInt8] {
        try readUntil(0, idle: idle, cancellable: false)
    }

    func read(count: Int, idle: TimeInterval) throws -> [UInt8] {
        while inbox.count - start < count {
            guard try pump(idle: idle, cancellable: false) else { throw ended() }
        }
        defer { consume(count) }
        return Array(inbox[start..<start + count])
    }

    private func readUntil(_ byte: UInt8, idle: TimeInterval, cancellable: Bool) throws -> [UInt8] {
        var searched = start
        while true {
            if let found = inbox[searched...].firstIndex(of: byte) {
                defer { consume(found + 1 - start) }
                return Array(inbox[start..<found])
            }
            searched = inbox.count
            guard try pump(idle: idle, cancellable: cancellable) else { throw ended() }
        }
    }

    private func consume(_ count: Int) {
        start += count
        if start == inbox.count {
            inbox.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 1 << 20 {
            inbox.removeFirst(start)
            start = 0
        }
    }

    private func ended() -> SSHTransport.Failure {
        .disconnected("the remote side closed the stream")
    }

    private func closeInput() {
        guard input >= 0 else { return }
        Darwin.close(input)
        input = -1
    }

    /// Reads what stderr still holds after the process ended.
    private func drainErrors() throws {
        while errors >= 0, readSome(errors, into: { errorTail = Array((errorTail + $0).suffix(4096)) }) {}
    }

    /// Kills the process group if still running, closes the streams and
    /// returns the exit status (255 for a killed process).
    @discardableResult
    func terminate() -> Int32 {
        closeInput()
        defer {
            try? drainErrors()
            for fd in [output, errors] where fd >= 0 { Darwin.close(fd) }
            output = -1
            errors = -1
        }
        if let status {
            kill(-pid, SIGKILL)
            return status
        }
        var code: Int32 = 0
        var result = waitpid(pid, &code, WNOHANG)
        if result == 0 {
            // Give a process that just closed its output a moment to exit.
            for _ in 0..<20 where result == 0 {
                usleep(5_000)
                result = waitpid(pid, &code, WNOHANG)
            }
        }
        if result == 0 {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            result = waitpid(pid, &code, 0)
        } else {
            // The leader is gone; leftover pipeline members are not.
            kill(-pid, SIGKILL)
        }
        ci_process_guard_unregister(pid)
        let final = result == pid ? Self.exitStatus(code) : 255
        status = final
        return final
    }

    private static func exitStatus(_ code: Int32) -> Int32 {
        // WIFEXITED / WEXITSTATUS; a signal reads as a lost connection.
        code & 0x7F == 0 ? (code >> 8) & 0xFF : 255
    }
}

/// Streaming zstd or gzip decompression, chosen by the stream's magic bytes.
final class Decoder {
    let format: String
    private var zstd: OpaquePointer?
    private var zlibStream: UnsafeMutablePointer<z_stream>?
    private(set) var finished = false

    init(magic: [UInt8]) throws {
        if magic.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) {
            format = "zstd"
            zstd = ZSTD_createDCtx()
            // `--long=27` frames need a 128 MiB window.
            guard let zstd, ZSTD_isError(ZSTD_DCtx_setParameter(zstd, ZSTD_d_windowLogMax, 27)) == 0 else {
                throw SSHTransport.Failure.remote("cannot start zstd")
            }
        } else if magic.starts(with: [0x1F, 0x8B]) {
            format = "gzip"
            let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
            stream.initialize(to: z_stream())
            zlibStream = stream
            // 15 + 16: a gzip wrapper, checked (CRC and length) by zlib.
            guard inflateInit2_(stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw SSHTransport.Failure.remote("cannot start gzip")
            }
        } else {
            throw SSHTransport.Failure.remote(
                "unexpected capture stream: \(String(decoding: magic.prefix(80), as: UTF8.self))"
            )
        }
    }

    deinit {
        if let zstd { ZSTD_freeDCtx(zstd) }
        if let zlibStream {
            inflateEnd(zlibStream)
            zlibStream.deallocate()
        }
    }

    func decode(_ input: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 17)
        try input.withUnsafeBytes { source in
            if let zstd {
                var inBuffer = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
                repeat {
                    let produced = try chunk.withUnsafeMutableBytes { target -> Int in
                        var outBuffer = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                        let result = ZSTD_decompressStream(zstd, &outBuffer, &inBuffer)
                        if ZSTD_isError(result) != 0 {
                            throw SSHTransport.Failure.remote("zstd: \(String(cString: ZSTD_getErrorName(result)))")
                        }
                        finished = result == 0
                        return outBuffer.pos
                    }
                    output += chunk[..<produced]
                    // A full output buffer may hide more output.
                    if produced == chunk.count { continue }
                    if inBuffer.pos == inBuffer.size { break }
                } while true
            } else if let stream = zlibStream {
                stream.pointee.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.pointee.avail_in = uInt(source.count)
                while true {
                    if finished {
                        guard stream.pointee.avail_in > 0 else { break }
                        // Another gzip member follows.
                        inflateReset(stream)
                        finished = false
                    }
                    let (produced, result) = chunk.withUnsafeMutableBytes { target -> (Int, Int32) in
                        stream.pointee.next_out = target.bindMemory(to: Bytef.self).baseAddress
                        stream.pointee.avail_out = uInt(target.count)
                        let result = inflate(stream, Z_NO_FLUSH)
                        return (target.count - Int(stream.pointee.avail_out), result)
                    }
                    output += chunk[..<produced]
                    switch result {
                    case Z_STREAM_END: finished = true
                    case Z_OK where stream.pointee.avail_out == 0: continue
                    case Z_OK, Z_BUF_ERROR: break
                    default: throw SSHTransport.Failure.remote("gzip: corrupt stream (\(result))")
                    }
                    if !finished, stream.pointee.avail_in == 0 { break }
                    if !finished, result == Z_BUF_ERROR { break }
                }
                stream.pointee.next_in = nil
            }
        }
        return output
    }
}

/// The remote read loop and capture, for hosts with `python3`. Paths are
/// bytes throughout; work is submitted in blocks so a slow link never makes
/// the remote side read the whole batch into memory.
private let remotePythonScript = #"""
import os, sys, stat, hashlib, shutil, subprocess
from concurrent.futures import ThreadPoolExecutor
I, O = sys.stdin.buffer, sys.stdout.buffer
LFS = b"version https://git-lfs.github.com/spec"
POOL = ThreadPoolExecutor(16)

def field():
    parts = []
    while True:
        chunk = I.peek(1)
        if not chunk:
            return None
        k = chunk.find(b"\0")
        if k >= 0:
            parts.append(I.read(k + 1)[:-1])
            return b"".join(parts)
        parts.append(I.read(len(chunk)))

def regular(p):
    fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("not a regular file")
        return os.fdopen(fd, "rb")
    except BaseException:
        os.close(fd)
        raise

def listing(d):
    try:
        out = [b"ok\n"]
        with os.scandir(d) as it:
            for e in it:
                try:
                    if e.is_dir(follow_symlinks=False):
                        out.append(b"d" + e.name + b"\0")
                    elif e.is_file(follow_symlinks=False):
                        try:
                            s = e.stat(follow_symlinks=False)
                            m = b"%d/%d/" % (s.st_size, s.st_mtime_ns)
                        except OSError:
                            m = b"//"
                        out.append(b"f" + m + e.name + b"\0")
                except OSError:
                    pass
        out.append(b"\0")
        return b"".join(out)
    except OSError:
        return b"err\n"

def hashing(p):
    try:
        h, n, head = hashlib.sha256(), 0, b""
        with regular(p) as f:
            while True:
                c = f.read(1 << 20)
                if not c:
                    break
                if n == 0:
                    head = c[:len(LFS)]
                h.update(c)
                n += len(c)
        return b"ok %d %s %d\n" % (n, h.hexdigest().encode(), head == LFS)
    except (OSError, TypeError):
        return b"err\n"

def reading(p):
    try:
        with regular(p) as f:
            data = f.read()
        return b"ok %d\n" % len(data) + data
    except (OSError, TypeError):
        return b"gone\n"

def mapped(fn, items, out):
    for k in range(0, len(items), 256):
        for r in POOL.map(fn, items[k:k + 256]):
            out.write(r)

root, mode = field(), field()
try:
    os.chdir(root)
except (OSError, TypeError):
    O.write(b"err\n")
    O.flush()
    sys.exit(3)
if mode == b"capture":
    want = field()
    paths = []
    while True:
        p = field()
        if p is None:
            break
        paths.append(p)
    z = shutil.which("zstd") if want != b"gzip" else None
    O.flush()
    proc = subprocess.Popen([z, "-3", "--long=27", "-c", "-q"] if z else ["gzip", "-1", "-c"], stdin=subprocess.PIPE)
    mapped(reading, paths, proc.stdin)
    proc.stdin.close()
    sys.exit(proc.wait())
O.write(b"ready\n")
O.flush()
while True:
    op = field()
    if op is None:
        break
    if op == b"R":
        O.write(reading(field()))
    elif op in (b"L", b"H"):
        n = int(field())
        items = [field() for _ in range(n)]
        mapped(listing if op == b"L" else hashing, items, O)
    else:
        sys.exit(2)
    O.flush()
"""#

/// The same protocol in bash, for hosts without `python3`: single-threaded,
/// one file at a time. A read pads or cuts the bytes to the size it
/// announced, so a file changing mid-read garbles only its own content (its
/// hash then fails) and never the stream.
private let remoteBashScript = #"""
export LC_ALL=C
shopt -s nullglob dotglob
lfs='version https://git-lfs.github.com/spec'
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum < "$1"; }; else sha() { shasum -a 256 < "$1"; }; fi
# Size and modification time, `size/mtime`: GNU stat, else BSD stat.
if stat -c %s / >/dev/null 2>&1; then meta() { stat -c '%s/%y' -- "$1" 2>/dev/null; }
else meta() { stat -f '%z/%Fm' -- "$1" 2>/dev/null; }; fi
listing() {
  if ! [ -d "$1" ] || ! [ -r "$1" ]; then printf 'err\n'; return; fi
  printf 'ok\n'
  local e m
  for e in "$1"/*; do
    if [ -L "$e" ]; then :
    elif [ -d "$e" ]; then printf 'd%s\0' "${e##*/}"
    elif [ -f "$e" ]; then m=$(meta "$e") || m=/; printf 'f%s/%s\0' "$m" "${e##*/}"
    fi
  done
  printf '\0'
}
hashing() {
  local n h l=0
  [ -f "$1" ] && n=$(wc -c < "$1" 2>/dev/null) && h=$(sha "$1" 2>/dev/null) || { printf 'err\n'; return; }
  printf '%s' "$lfs" | cmp -s -n 39 - "$1" && l=1
  printf 'ok %d %s %d\n' "$((n))" "${h%% *}" "$l"
}
reading() {
  local n
  [ -f "$1" ] && n=$(wc -c < "$1" 2>/dev/null) || { printf 'gone\n'; return; }
  n=$((n))
  printf 'ok %d\n' "$n"
  [ "$n" -gt 0 ] && { head -c "$n" "$1" 2>/dev/null; cat /dev/zero; } | head -c "$n"
}
IFS= read -r -d '' root || exit 3
IFS= read -r -d '' mode || exit 3
cd -- "$root" 2>/dev/null || { printf 'err\n'; exit 3; }
if [ "$mode" = capture ]; then
  IFS= read -r -d '' want || exit 3
  paths=()
  while IFS= read -r -d '' p; do paths+=("./$p"); done
  if [ "$want" != gzip ] && command -v zstd >/dev/null 2>&1; then z='zstd -3 --long=27 -c -q'; else z='gzip -1 -c'; fi
  if [ "${#paths[@]}" -gt 0 ]; then
    printf '%s\0' "${paths[@]}" | xargs -0 -P 16 -n 64 cat >/dev/null 2>&1 &
  fi
  for p in "${paths[@]}"; do reading "$p"; done | $z
  exit
fi
printf 'ready\n'
while IFS= read -r -d '' op; do
  case $op in
    R) IFS= read -r -d '' p || exit 0; reading "./$p" ;;
    L|H) IFS= read -r -d '' n || exit 0
      while [ "$n" -gt 0 ]; do
        IFS= read -r -d '' p || exit 0
        if [ "$op" = L ]; then listing "./$p"; else hashing "./$p"; fi
        n=$((n - 1))
      done ;;
    *) exit 2 ;;
  esac
done
"""#
