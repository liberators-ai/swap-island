import AppKit
import CryptoKit
import Foundation
import IslandCore

/// Keeps the installed app current from the GitHub releases. A new version downloads in the
/// background and replaces the app the next time the panel is closed and no cswap command runs.
/// Setting the `autoUpdate` default to false leaves that last step to the button in the panel.
@MainActor
final class IslandUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(String)
        /// Newer version exists, but this copy cannot replace itself, so the button opens the release page.
        case available(String)
        case ready(String)
    }

    @Published private(set) var phase: Phase = .idle
    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    private nonisolated static let repo = "liberators-ai/swap-island"
    private static let checkInterval: Duration = .seconds(6 * 60 * 60)
    private static let idlePoll: Duration = .seconds(5)

    private let demoVersion: String?
    private var loop: Task<Void, Never>?
    private var stagedApp: URL?

    /// `demoVersion` shows the update button without checking anything, for screenshots.
    init(demoVersion: String?) {
        self.demoVersion = demoVersion
    }

    func start(isIdle: @escaping @MainActor () -> Bool) {
        if let demoVersion {
            phase = .available(demoVersion)
            return
        }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                await self?.installWhenIdle(isIdle)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func updateNow() {
        switch phase {
        case .ready: install()
        case .available(let version):
            if let url = URL(string: "https://github.com/\(Self.repo)/releases/tag/v\(version)") {
                NSWorkspace.shared.open(url)
            }
        case .idle, .downloading: break
        }
    }

    private func check() async {
        guard stagedApp == nil, let currentVersion, let current = ReleaseVersion(currentVersion) else { return }
        do {
            let latest = try await Self.latestVersion()
            guard latest > current else { return }
            let version = latest.description
            guard let bundle = Self.replaceableBundle() else {
                phase = .available(version)
                return
            }
            phase = .downloading(version)
            stagedApp = try await Self.stage(version: version, replacing: bundle)
            phase = .ready(version)
        } catch {
            NSLog("Swap Island: update check failed: \(error.localizedDescription)")
            if case .downloading = phase { phase = .idle }
        }
    }

    private func installWhenIdle(_ isIdle: @MainActor () -> Bool) async {
        guard stagedApp != nil, UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true else { return }
        while !isIdle() {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: Self.idlePoll)
        }
        install()
    }

    private func install() {
        guard let stagedApp else { return }
        do {
            let installed = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: stagedApp)
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", #"sleep 1; /usr/bin/open "$0""#, (installed ?? Bundle.main.bundleURL).path]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("Swap Island: update install failed: \(error.localizedDescription)")
            self.stagedApp = nil
            phase = .idle
        }
    }

    /// Only a copy in an Applications folder replaces itself, so a build folder or a mounted DMG stays as it is.
    private static func replaceableBundle() -> URL? {
        let bundle = Bundle.main.bundleURL
        let parent = bundle.deletingLastPathComponent().path
        let folders = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        guard folders.contains(parent), FileManager.default.isWritableFile(atPath: parent) else { return nil }
        return bundle
    }

    private nonisolated static func latestVersion() async throws -> ReleaseVersion {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let release = try JSONDecoder().decode(LatestRelease.self, from: try await fetch(url))
        guard let version = ReleaseVersion(release.tagName) else { throw UpdateError("Unreadable tag \(release.tagName)") }
        return version
    }

    /// Downloads and checks a release, and returns the unpacked app on the same volume as `bundle`,
    /// so the final swap is a rename and cannot leave a half-written app behind.
    private nonisolated static func stage(version: String, replacing bundle: URL) async throws -> URL {
        let assets = "https://github.com/\(repo)/releases/download/v\(version)"
        let archive = try await fetch(URL(string: "\(assets)/Swap-Island.zip")!)
        let checksum = String(decoding: try await fetch(URL(string: "\(assets)/Swap-Island.zip.sha256")!), as: UTF8.self)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard ReleaseChecksum.digest(in: checksum) == digest else { throw UpdateError("Checksum mismatch") }

        let work = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true
        )
        let zip = work.appendingPathComponent("Swap-Island.zip")
        try archive.write(to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

        let app = work.appendingPathComponent("Swap Island.app")
        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version
        else { throw UpdateError("The download is not Swap Island \(version)") }
        try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        return app
    }

    private nonisolated static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Swap-Island", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("No file at \(url)") }
        return data
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("\(tool) failed") }
    }
}

private struct UpdateError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
