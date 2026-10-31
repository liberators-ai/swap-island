import Foundation

public enum CswapError: Error, Equatable, LocalizedError {
    case notInstalled
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "cswap not found."
        case .timedOut: "cswap did not answer in time."
        case .failed(let message): message
        }
    }
}

/// Every credential operation goes through the `cswap` CLI. It holds Claude Code's own credential
/// locks while writing, and re-implementing that here is how a swap would collide with a token refresh.
public struct CswapClient: Sendable {
    public let executable: URL
    /// How long one call may take before it is given up. `upgrade` passes its own, longer one.
    public let timeout: Duration

    public init(executable: URL, timeout: Duration = .seconds(45)) {
        self.executable = executable
        self.timeout = timeout
    }

    /// A GUI app inherits a minimal PATH, so the usual install locations are probed directly.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CswapClient? {
        if let override = environment["SWAP_ISLAND_CSWAP"] {
            return CswapClient(executable: URL(fileURLWithPath: override))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { CswapClient(executable: URL(fileURLWithPath: $0)) }
    }

    public func list() async throws -> AccountList {
        try Self.decode(AccountList.self, from: try await run(["list", "--json"]))
    }

    public func switchTo(account number: Int) async throws -> SwitchResult {
        try Self.decode(SwitchResult.self, from: try await run(["switch", String(number), "--json"]))
    }

    public func switchToBest() async throws -> SwitchResult {
        try Self.decode(SwitchResult.self, from: try await run(["switch", "--strategy", "best", "--json"]))
    }

    /// Stores the login Claude Code is on now, or refreshes it in place if it is already managed.
    public func addCurrentLogin() async throws {
        _ = try await run(["add"])
    }

    public func setDisabled(account number: Int, _ disabled: Bool) async throws {
        _ = try await run([disabled ? "disable" : "enable", String(number)])
    }

    /// The panel asks for confirmation itself, so the CLI's own prompt is answered here.
    public func remove(account number: Int) async throws {
        _ = try await run(["remove", String(number)], input: "y\n")
    }

    /// A pre-release such as 0.29.0b1 does not parse, so it never gets offered a final release.
    public func version() async throws -> ReleaseVersion {
        let output = String(decoding: try await run(["--version"]), as: UTF8.self)
        guard let word = output.split(whereSeparator: \.isWhitespace).last,
              let version = ReleaseVersion(String(word))
        else { throw CswapError.failed("Unexpected answer from cswap.") }
        return version
    }

    /// Exits 0 even when nothing changed, so a caller has to read `version()` afterwards.
    public func upgrade() async throws {
        let path = Self.upgradePath(
            inherited: ProcessInfo.processInfo.environment["PATH"],
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
        _ = try await run(["upgrade"], timeout: .seconds(180), path: path)
    }

    /// `cswap upgrade` calls uv or pipx by name, and a GUI app's minimal PATH has neither.
    static func upgradePath(inherited: String?, home: String) -> String {
        (["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + [inherited].compactMap { $0 })
            .joined(separator: ":")
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CswapError.failed("Unexpected answer from cswap.")
        }
    }

    /// Returns by the deadline whatever the child does. A task group cannot promise that: it waits
    /// for every child task, and on 31/10/2026 one `waitUntilExit` never returned although cswap had
    /// exited, so the refresh loop stopped and the panel kept showing usage from hours before.
    private func run(
        _ arguments: [String],
        input: String? = nil,
        timeout: Duration? = nil,
        path: String? = nil
    ) async throws -> Data {
        try await Self.execute(executable, arguments, input: input, path: path, timeout: timeout ?? self.timeout)
    }

    private static func execute(
        _ executable: URL,
        _ arguments: [String],
        input: String?,
        path: String?,
        timeout: Duration
    ) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONIOENCODING"] = "utf-8"
        if let path { environment["PATH"] = path }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        let outcome = Outcome()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Already cancelled: nothing gets started.
                guard outcome.attach(continuation) else { return }
                let exited = DispatchSemaphore(value: 0)
                // Set before run(): a quick child can exit before run() returns.
                process.terminationHandler = { _ in exited.signal() }
                do {
                    try process.run()
                } catch {
                    outcome.finish(.failure(CswapError.notInstalled))
                    return
                }
                // Drain both at once: a pipe that fills while nobody reads it blocks the child forever.
                let output = Drain(stdout)
                let errorOutput = Drain(stderr)
                if let input {
                    try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    // Bounded, so a child that outlives its SIGTERM costs a thread for a while, not forever.
                    guard exited.wait(timeout: .now() + timeout.seconds + 5) == .success else { return }
                    // A grandchild that inherited a pipe can hold it open after cswap exits.
                    // cswap's own output is in by then, so a short wait for the end is enough.
                    output.waitForEnd(seconds: 2)
                    errorOutput.waitForEnd(seconds: 2)
                    let status = process.terminationStatus
                    outcome.finish(status == 0
                        ? .success(output.data)
                        : .failure(CswapError.failed(failureMessage(stdout: output.data, stderr: errorOutput.data, status: status))))
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout.seconds) {
                    if outcome.finish(.failure(CswapError.timedOut)) { stopIfRunning(process) }
                }
            }
        } onCancel: {
            if outcome.finish(.failure(CancellationError())) { stopIfRunning(process) }
        }
    }

    /// SIGTERM only while the child still runs unreaped, so a pid the system has handed to another
    /// process is never signalled. `WNOWAIT` leaves the exit status for Foundation to collect.
    private static func stopIfRunning(_ process: Process) {
        let pid = process.processIdentifier
        var info = siginfo_t()
        guard pid > 0, waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == 0 else { return }
        process.terminate()
    }

    /// JSON commands report through an envelope on stdout, the others print a line on stderr.
    private static func failureMessage(stdout: Data, stderr: Data, status: Int32) -> String {
        if let message = (try? JSONDecoder().decode(CswapErrorPayload.self, from: stdout))?.error?.message {
            return message
        }
        let lastLine = String(decoding: stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init)
        return lastLine ?? "cswap exited with \(status)."
    }
}

/// Resumes the caller once, with whichever of exit, deadline and cancellation comes first.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?

    /// False when the outcome was settled before the caller got here, which only cancellation does.
    func attach(_ continuation: CheckedContinuation<Data, any Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// True for the one call that settled it.
    @discardableResult
    func finish(_ result: Result<Data, any Error>) -> Bool {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

/// Collects a pipe as it fills and signals when every writer has closed it.
private final class Drain: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let ended = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                ended.signal()
            } else {
                lock.lock()
                buffer.append(chunk)
                lock.unlock()
            }
        }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func waitForEnd(seconds: Double) {
        _ = ended.wait(timeout: .now() + seconds)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
