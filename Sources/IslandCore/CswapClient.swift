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

    public init(executable: URL) {
        self.executable = executable
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

    private func run(
        _ arguments: [String],
        input: String? = nil,
        timeout: Duration = .seconds(45),
        path: String? = nil
    ) async throws -> Data {
        let executable = executable
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await Self.execute(executable, arguments, input: input, path: path) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CswapError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func execute(_ executable: URL, _ arguments: [String], input: String?, path: String?) async throws -> Data {
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

        return try await withTaskCancellationHandler {
            do {
                try process.run()
            } catch {
                throw CswapError.notInstalled
            }
            if let input {
                try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
            // Drain both at once: a pipe that fills while nobody reads it blocks the child forever.
            async let output = readToEnd(stdout)
            async let errorOutput = readToEnd(stderr)
            let (data, errorData) = await (output, errorOutput)
            await waitForExit(process)

            guard process.terminationStatus == 0 else {
                throw CswapError.failed(failureMessage(stdout: data, stderr: errorData, status: process.terminationStatus))
            }
            return data
        } onCancel: {
            process.terminate()
        }
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
    }

    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
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
