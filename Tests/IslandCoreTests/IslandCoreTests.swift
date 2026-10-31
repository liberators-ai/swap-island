import CoreGraphics
import Foundation
import Testing
@testable import IslandCore

@Suite struct DecodingTests {
    @Test func readsTheLiveListShape() throws {
        let json = #"""
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
          {"number":2,"email":"a@example.com","organizationName":"x","active":true,"usageStatus":"ok",
           "usage":{"fiveHour":{"pct":14.0,"resetsAt":"2026-10-30T21:29:59+00:00","countdown":"3h 12m","clock":"23:29"},
                    "sevenDay":{"pct":83.0,"countdown":"4d 2h","expectedPct":41.2,"aheadOfPace":true},
                    "scoped":[{"pct":0.0,"name":"Fable"}]},
           "usageAgeSeconds":115.8,"someFutureField":{"nested":true}},
          {"number":3,"email":"b@example.com","active":false,"usageStatus":"ok",
           "usage":{"fiveHour":{"pct":0.0},"sevenDay":{"pct":99.0}},"alias":"work","disabled":true}
        ]}
        """#
        let list = try CswapClient.decode(AccountList.self, from: Data(json.utf8))
        #expect(list.activeAccountNumber == 2)
        #expect(list.accounts[0].usage?.sevenDay?.expectedPct == 41.2)
        #expect(list.accounts[1].usage?.fiveHour?.countdown == nil)
        #expect(list.accounts[1].displayName == "work")
        #expect(list.accounts[1].isDisabled)
    }

    @Test func fallsBackToLastKnownUsageAndMarksItStale() throws {
        let json = #"""
        {"accounts":[{"number":1,"email":"a@example.com","active":false,"usageStatus":"token_expired",
          "usage":null,"lastGoodUsage":{"fiveHour":{"pct":40},"sevenDay":{"pct":50}}}]}
        """#
        let account = try CswapClient.decode(AccountList.self, from: Data(json.utf8)).accounts[0]
        #expect(account.shownUsage?.fiveHour?.pct == 40)
        #expect(account.isUsageStale)
        #expect(account.needsLogin)
    }

    @Test func aNoOpSwitchIsNotReportedAsAFailure() throws {
        let noOp = try CswapClient.decode(SwitchResult.self, from: Data(#"{"switched":false,"reason":"already-best"}"#.utf8))
        #expect(noOp.outcome == .alreadyThere("Already on the account with the most quota."))

        let blocked = try CswapClient.decode(SwitchResult.self, from: Data(#"{"switched":false,"reason":"candidates-exhausted"}"#.utf8))
        #expect(blocked.outcome == .blocked("No other account has quota left."))

        let unknown = try CswapClient.decode(SwitchResult.self, from: Data(#"{"switched":false,"reason":"brand-new-reason"}"#.utf8))
        #expect(unknown.outcome == .blocked("cswap did not switch."))
    }

    @Test func rejectsGarbageWithAReadableError() {
        #expect(throws: CswapError.failed("Unexpected answer from cswap.")) {
            try CswapClient.decode(AccountList.self, from: Data("not json".utf8))
        }
    }
}

@Suite struct ClientTests {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-cswap-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func surfacesTheCliErrorMessage() async throws {
        let fake = try script(#"echo '{"schemaVersion":1,"error":{"message":"Account 9 not found"}}'; exit 1"#)
        await #expect(throws: CswapError.failed("Account 9 not found")) {
            _ = try await CswapClient(executable: fake).switchTo(account: 9)
        }
    }

    @Test func passesTheAccountNumberToSwitch() async throws {
        let fake = try script(#"[ "$1 $2 $3" = "switch 6 --json" ] && echo '{"switched":true}' || { echo '{}'; exit 3; }"#)
        let result = try await CswapClient(executable: fake).switchTo(account: 6)
        #expect(result.switched)
    }

    @Test func readsTheInstalledVersion() async throws {
        let fake = try script(#"[ "$1" = "--version" ] && echo "cswap 0.29.0""#)
        #expect(try await CswapClient(executable: fake).version() == ReleaseVersion("0.29.0"))
    }

    @Test func aPreReleaseIsNotOfferedAnUpdate() async throws {
        let fake = try script(#"echo "cswap 0.29.0b1""#)
        await #expect(throws: CswapError.failed("Unexpected answer from cswap.")) {
            _ = try await CswapClient(executable: fake).version()
        }
    }

    @Test func upgradeCanFindUvFromAMinimalPath() async throws {
        let fake = try script(#"[ "$1" = "upgrade" ] && case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *) exit 3 ;; esac"#)
        try await CswapClient(executable: fake).upgrade()
    }

    @Test func upgradePathKeepsWhatWasInherited() {
        #expect(CswapClient.upgradePath(inherited: "/usr/bin:/bin", home: "/Users/x")
            == "/Users/x/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(CswapClient.upgradePath(inherited: nil, home: "/Users/x")
            == "/Users/x/.local/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    @Test func answersTheRemovePromptItself() async throws {
        let fake = try script(#"read answer; [ "$1 $2 $answer" = "remove 6 y" ] || exit 3"#)
        try await CswapClient(executable: fake).remove(account: 6)
    }

    @Test func surfacesAPlainCommandsStderrLine() async throws {
        let fake = try script(#"echo "starting" >&2; echo "Account is in use by a running session" >&2; exit 1"#)
        await #expect(throws: CswapError.failed("Account is in use by a running session")) {
            try await CswapClient(executable: fake).setDisabled(account: 2, true)
        }
    }

    @Test func pausesWithDisableAndResumesWithEnable() async throws {
        let fake = try script(#"[ "$1 $2" = "disable 3" ] || [ "$1 $2" = "enable 3" ] || exit 3"#)
        try await CswapClient(executable: fake).setDisabled(account: 3, true)
        try await CswapClient(executable: fake).setDisabled(account: 3, false)
    }

    @Test func reportsAMissingBinary() async {
        let client = CswapClient(executable: URL(fileURLWithPath: "/nonexistent/cswap"))
        await #expect(throws: CswapError.notInstalled) {
            _ = try await client.list()
        }
    }

    // The refresh loop waits on each call, so a call that never returns freezes the panel.
    @Test func givesUpOnAChildThatNeverAnswers() async throws {
        let fake = try script("exec sleep 30")
        let start = ContinuousClock.now
        await #expect(throws: CswapError.timedOut) {
            _ = try await CswapClient(executable: fake, timeout: .seconds(1)).list()
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func readsTheAnswerWhileAGrandchildHoldsThePipe() async throws {
        let fake = try script(#"sleep 8 & echo "cswap 0.29.0""#)
        let start = ContinuousClock.now
        #expect(try await CswapClient(executable: fake).version() == ReleaseVersion("0.29.0"))
        // Under the 8 seconds the grandchild keeps the pipe open; tests launch in parallel, so not much under.
        #expect(ContinuousClock.now - start < .seconds(7))
    }

    @Test func stopsWaitingWhenCancelled() async throws {
        let fake = try script("exec sleep 30")
        let start = ContinuousClock.now
        let call = Task { try await CswapClient(executable: fake).list() }
        try await Task.sleep(for: .milliseconds(300))
        call.cancel()
        await #expect(throws: CancellationError.self) { _ = try await call.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

@Suite struct GeometryTests {
    // The real numbers from this MacBook: 1512 wide, 665 + 662 auxiliary, 32 inset.
    private let notched = NotchGeometry(
        screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
        topInset: 32, auxiliaryLeft: 665, auxiliaryRight: 662
    )
    private let bodySize = CGSize(width: 360, height: 300)

    @Test func derivesTheNotchWidthFromTheAuxiliaryAreas() {
        // The narrower margin on both sides, because the hardware notch sits on the screen's center.
        #expect(notched.notchSize == CGSize(width: 188, height: 32))
    }

    @Test(arguments: [
        (CGRect(x: 0, y: 0, width: 1512, height: 982), CGFloat(32), CGFloat(665), CGFloat(662)),
        (CGRect(x: 0, y: 0, width: 1728, height: 1117), 37, 770, 770),
        (CGRect(x: 0, y: 0, width: 1470, height: 956), 37, 650, 640),
        (CGRect(x: -1920, y: 300, width: 1512, height: 982), 32, 665, 662),
    ])
    func everyNotchGetsACenteredPanelAndAFlushIsland(
        screen: CGRect, inset: CGFloat, left: CGFloat, right: CGFloat
    ) {
        let geometry = NotchGeometry(screen: screen, topInset: inset, auxiliaryLeft: left, auxiliaryRight: right)
        #expect(geometry.notchRect.minX == screen.minX + min(left, right))
        #expect(geometry.notchRect.maxX == screen.maxX - min(left, right))
        #expect(geometry.notchRect.midX == screen.midX)
        #expect(geometry.notchRect.maxY == screen.maxY)
        #expect(geometry.notchRect.height == inset)
        #expect(geometry.panelRect(bodySize: bodySize).midX == geometry.notchRect.midX)
        #expect(geometry.windowFrame(bodySize: bodySize, margin: 40).midX == geometry.notchRect.midX)
        let window = geometry.windowFrame(bodySize: bodySize, margin: 40)
        #expect(window.minX == window.minX.rounded())
        #expect(geometry.closedRect.midX == geometry.notchRect.midX)
        #expect(geometry.panelRect(bodySize: bodySize).maxY == geometry.notchRect.minY - NotchGeometry.shoulderDrop)
    }

    @Test func theClosedIslandExtendsEquallyOnBothSides() {
        #expect(notched.notchRect.minX - notched.closedRect.minX == NotchGeometry.wingWidth)
        #expect(notched.closedRect.maxX - notched.notchRect.maxX == NotchGeometry.wingWidth)
        #expect(notched.closedRect.midX == notched.notchRect.midX)
    }

    @Test func aFoldedWingKeepsThePanelOpenButLeavesItsClicksToTheIcons() {
        let inWing = CGPoint(x: notched.notchRect.maxX + 10, y: notched.screen.maxY - 12)
        #expect(notched.isOverIsland(at: inWing, bodySize: bodySize))
        #expect(!notched.isOverOpenShape(at: inWing, bodySize: bodySize))
    }

    @Test func theOpenPanelStaysBelowTheMenuBar() {
        let menuBarBottom = notched.screen.maxY - notched.notchSize.height
        #expect(notched.panelRect(bodySize: bodySize).maxY < menuBarBottom)
    }

    @Test func aMenuBarIconBesideTheNeckIsNotPartOfTheIsland() {
        let icon = CGPoint(x: notched.notchRect.maxX + 30, y: notched.screen.maxY - 12)
        #expect(!notched.isOverIsland(at: icon, bodySize: bodySize, slack: 8))
    }

    @Test func aScreenWithoutANotchGetsAVirtualOne() {
        let external = NotchGeometry(
            screen: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            topInset: 0, auxiliaryLeft: nil, auxiliaryRight: nil
        )
        #expect(external.notchSize == NotchGeometry.fallbackSize)
    }

    @Test func opensOnTheNotchAndNotBesideIt() {
        #expect(notched.triggersOpen(at: CGPoint(x: 756, y: 975)))
        #expect(!notched.triggersOpen(at: CGPoint(x: 300, y: 975)))
        #expect(!notched.triggersOpen(at: CGPoint(x: 756, y: 900)))
    }

    @Test func hiddenWingsDoNotReactToTheMouse() {
        let inWing = CGPoint(x: notched.notchRect.maxX + 10, y: notched.screen.maxY - 12)
        let inNotch = CGPoint(x: notched.notchRect.midX, y: notched.screen.maxY - 12)
        #expect(notched.triggersOpen(at: inWing))
        #expect(!notched.triggersOpen(at: inWing, wingsHidden: true))
        #expect(notched.triggersOpen(at: inNotch, wingsHidden: true))
    }

    @Test func aSmallDriftPastTheEdgeKeepsItOpen() {
        let edge = notched.panelRect(bodySize: bodySize)
        #expect(notched.isOverIsland(at: CGPoint(x: edge.maxX + 6, y: edge.midY), bodySize: bodySize, slack: 8))
        #expect(!notched.isOverIsland(at: CGPoint(x: edge.maxX + 40, y: edge.midY), bodySize: bodySize, slack: 8))
    }

    @Test func theNeckConnectsTheNotchToThePanel() {
        let edge = notched.panelRect(bodySize: bodySize)
        let inNeck = CGPoint(x: notched.screen.midX, y: edge.maxY + 4)
        #expect(notched.isOverIsland(at: inNeck, bodySize: bodySize))
    }

    @Test func windowIsLargerThanThePanelSoTheShadowIsNotClipped() {
        let frame = notched.windowFrame(bodySize: bodySize, margin: 40)
        #expect(frame.contains(notched.panelRect(bodySize: bodySize)))
        #expect(frame.maxY == 982)
    }
}

@Suite struct UsageLevelTests {
    @Test func bandsMatchTheAutoSwitchThreshold() {
        #expect(UsageLevel(pct: 69.9) == .calm)
        #expect(UsageLevel(pct: 70) == .warm)
        #expect(UsageLevel(pct: 90) == .hot)
    }
}

@Suite struct ReleaseVersionTests {
    @Test func readsTheVersionFromPyPI() throws {
        let json = #"{"info":{"name":"claude-swap","version":"0.29.0"},"releases":{}}"#
        #expect(try JSONDecoder().decode(PyPIProject.self, from: Data(json.utf8)).info.version == "0.29.0")
    }

    @Test func readsATagWithOrWithoutTheLeadingV() {
        #expect(ReleaseVersion("v0.1.2") == ReleaseVersion("0.1.2"))
        #expect(ReleaseVersion("0.1.2")?.description == "0.1.2")
    }

    @Test func comparesNumbersNotText() throws {
        #expect(try #require(ReleaseVersion("0.1.10")) > #require(ReleaseVersion("0.1.9")))
        #expect(try #require(ReleaseVersion("1.0")) > #require(ReleaseVersion("0.9.9")))
        #expect(ReleaseVersion("1.0") == ReleaseVersion("1.0.0"))
    }

    @Test func rejectsATagThatIsNotAVersion() {
        #expect(ReleaseVersion("nightly") == nil)
        #expect(ReleaseVersion("") == nil)
        #expect(ReleaseVersion("v1.x") == nil)
    }

    @Test func readsTheDigestFromAShasumFile() {
        let digest = String(repeating: "a", count: 64)
        #expect(ReleaseChecksum.digest(in: "\(digest)  Swap-Island.zip\n") == digest)
        #expect(ReleaseChecksum.digest(in: "Not Found") == nil)
    }

    @Test func decodesTheLatestReleaseAnswer() throws {
        let json = #"{"tag_name":"v0.1.3","name":"Swap Island 0.1.3","draft":false}"#
        let release = try JSONDecoder().decode(LatestRelease.self, from: Data(json.utf8))
        #expect(release.tagName == "v0.1.3")
    }
}
