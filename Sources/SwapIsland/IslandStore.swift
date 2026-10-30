import AppKit
import Foundation
import IslandCore
import SwiftUI

@MainActor
final class IslandStore: ObservableObject {
    enum Notice: Equatable {
        case success(String)
        case failure(String)
    }

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var isLoading = false
    @Published private(set) var switchingTo: Int?
    @Published private(set) var isSwitchingBest = false
    @Published private(set) var isManaging = false
    @Published private(set) var cswapMissing = false
    @Published private(set) var notice: Notice?
    @Published var isOpen = false
    @Published var isAdding = false

    /// Covers every address with a solid bar, for screenshots that get published.
    let hidesEmails: Bool

    private var client: CswapClient?
    private var refreshLoop: Task<Void, Never>?
    private var noticeDismissal: Task<Void, Never>?

    init(client: CswapClient?, hidesEmails: Bool = false) {
        self.client = client
        self.hidesEmails = hidesEmails
    }

    var active: Account? { accounts.first(where: \.active) }
    var isBusy: Bool { switchingTo != nil || isSwitchingBest || isManaging }

    /// cswap paces its own usage API calls, so reading its cache often costs nothing upstream.
    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh() async {
        // Looked up again each time, so installing cswap while the app is open just works.
        client = client ?? CswapClient.locate()
        guard let client else {
            cswapMissing = true
            return
        }
        cswapMissing = false
        guard !isLoading, !isBusy else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            accounts = try await client.list().accounts
        } catch {
            if accounts.isEmpty { show(.failure(error.localizedDescription)) }
        }
    }

    func switchTo(_ account: Account) {
        guard !account.active else { return }
        switchingTo = account.number
        perform({ self.switchingTo = nil }) { client in
            self.report(try await client.switchTo(account: account.number))
        }
    }

    func switchToBest() {
        isSwitchingBest = true
        perform({ self.isSwitchingBest = false }) { client in
            self.report(try await client.switchToBest())
        }
    }

    func addCurrentLogin() {
        isManaging = true
        perform({ self.isManaging = false }) { client in
            try await client.addCurrentLogin()
            self.isAdding = false
            self.show(.success("Login saved."))
        }
    }

    func setDisabled(_ account: Account, _ disabled: Bool) {
        isManaging = true
        perform({ self.isManaging = false }) { client in
            try await client.setDisabled(account: account.number, disabled)
        }
    }

    func remove(_ account: Account) {
        isManaging = true
        perform({ self.isManaging = false }) { client in
            try await client.remove(account: account.number)
            self.show(.success("Account removed."))
        }
    }

    /// Runs the login in Terminal, because it is an interactive browser flow.
    /// A `.command` file needs no Automation permission, unlike scripting Terminal directly.
    func openLoginInTerminal() {
        let script = """
        #!/bin/zsh -l
        claude auth login
        echo
        echo "Logged in. Go back to Swap Island and press Save this login."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swap-island-login.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            show(.failure("Could not open the login: \(error.localizedDescription)"))
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(IslandStore.installCommand, forType: .string)
        show(.success("Copied. Run it in Terminal."))
    }

    static let installCommand = "uv tool install claude-swap"

    private func perform(_ finish: @escaping () -> Void, _ work: @escaping (CswapClient) async throws -> Void) {
        guard let client else {
            finish()
            return
        }
        Task {
            do {
                try await work(client)
            } catch {
                show(.failure(error.localizedDescription))
            }
            finish()
            await refresh()
        }
    }

    private func report(_ result: SwitchResult) {
        switch result.outcome {
        case .switched: show(.success("Switched. Running sessions follow in about 30s."))
        case .alreadyThere(let message): show(.success(message))
        case .blocked(let message): show(.failure(message))
        }
    }

    private func show(_ notice: Notice) {
        self.notice = notice
        noticeDismissal?.cancel()
        noticeDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
