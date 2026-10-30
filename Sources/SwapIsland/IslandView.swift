import AppKit
import IslandCore
import ServiceManagement
import SwiftUI

enum IslandMetrics {
    static let bodyWidth: CGFloat = 360
    static let rowHeight: CGFloat = 58
    static let headerHeight: CGFloat = 36
    static let addSectionHeight: CGFloat = 66
    static let noticeHeight: CGFloat = 26
    static let footerHeight: CGFloat = 40
    static let maxVisibleRows = 5

    static func bodySize(accountCount: Int, isAdding: Bool) -> CGSize {
        let rows = max(1, min(accountCount, maxVisibleRows))
        return CGSize(
            width: bodyWidth,
            height: headerHeight + CGFloat(rows) * rowHeight + (isAdding ? addSectionHeight : 0)
                + noticeHeight + footerHeight
        )
    }
}

struct IslandView: View {
    @ObservedObject var store: IslandStore
    @ObservedObject var updater: IslandUpdater
    let geometry: NotchGeometry

    private var bodySize: CGSize {
        IslandMetrics.bodySize(accountCount: store.accounts.count, isAdding: store.showsExtraSection)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if store.isOpen {
                OpenPanel(store: store, updater: updater, notchSize: geometry.notchSize, bodySize: bodySize)
                    .transition(.scale(scale: 0.35, anchor: .top).combined(with: .opacity))
            }
            // The wings fold away while open, so the neck is the notch's width and covers no icon.
            ClosedIsland(
                account: store.active,
                notchSize: geometry.notchSize,
                wing: store.isOpen || store.isFullscreen ? 0 : NotchGeometry.wingWidth
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: store.isOpen)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: store.isAdding)
    }
}

// MARK: - Closed

private struct ClosedIsland: View {
    let account: Account?
    let notchSize: CGSize
    let wing: CGFloat

    var body: some View {
        ZStack {
            IslandShape(topRadius: 6, bottomRadius: 9).fill(.black)
            HStack(spacing: 0) {
                BadgeWithRing(account: account)
                    .frame(width: NotchGeometry.wingWidth - 6)
                Spacer(minLength: 0)
                WeekRing(account: account)
                    .frame(width: NotchGeometry.wingWidth - 6)
            }
            .padding(.horizontal, 6)
            .opacity(wing > 0 ? 1 : 0)
        }
        .frame(width: notchSize.width + wing * 2, height: notchSize.height)
    }
}

/// The active account with its 5-hour usage wrapped around it, all in one wing.
private struct BadgeWithRing: View {
    let account: Account?

    var body: some View {
        let pct = account?.shownUsage?.fiveHour?.pct ?? 0
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: min(pct, 100) / 100)
                .stroke(Color(level: UsageLevel(pct: pct)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: pct)
            if let account {
                AccountBadge(account: account, diameter: 12)
            }
        }
        .frame(width: 17, height: 17)
    }
}

/// The right wing: the active account's 7-day usage, the same size as the badge on the left.
private struct WeekRing: View {
    let account: Account?

    var body: some View {
        let pct = account?.shownUsage?.sevenDay?.pct ?? 0
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: min(pct, 100) / 100)
                .stroke(Color(level: UsageLevel(pct: pct)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: pct)
            Text("7d")
                .font(.system(size: 6.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(width: 17, height: 17)
    }
}

// MARK: - Open

private struct OpenPanel: View {
    @ObservedObject var store: IslandStore
    @ObservedObject var updater: IslandUpdater
    let notchSize: CGSize
    let bodySize: CGSize

    /// From the top of the screen down to the panel's top edge.
    private var shoulderY: CGFloat { notchSize.height + NotchGeometry.shoulderDrop }

    var body: some View {
        let center = bodySize.width / 2
        VStack(spacing: 0) {
            header
            accountList
            if store.needsOnboarding && !store.cswapMissing {
                OnboardingSection(store: store)
                    .transition(.opacity)
            } else if store.isAdding {
                AddAccountSection(store: store)
                    .transition(.opacity)
            }
            noticeBar
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, shoulderY)
        .frame(width: bodySize.width, height: bodySize.height + shoulderY, alignment: .top)
        .background(
            PanelShape(
                neckLeft: center - notchSize.width / 2,
                neckRight: center + notchSize.width / 2,
                shoulderY: shoulderY,
                fillet: NotchGeometry.shoulderDrop
            )
            .fill(.black)
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let logo = Bundle.main.image(forResource: "AppIcon") {
                Image(nsImage: logo)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
            Text("Swap Island")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
            if let version = updater.currentVersion {
                Text(version)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
            updateStatus
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                    .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                    .animation(
                        store.isLoading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                        value: store.isLoading
                    )
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh usage")
            .accessibilityLabel("Refresh usage")
        }
        .frame(height: IslandMetrics.headerHeight)
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updater.phase {
        case .idle:
            EmptyView()
        case .downloading(let version):
            Text("Downloading \(version)…")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        case .available(let version), .ready(let version):
            Button("Update to \(version)") { updater.updateNow() }
                .buttonStyle(.plain)
                .clickCursor()
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(level: .calm))
                .help("Swap Island also updates by itself when this panel closes")
        }
    }

    @ViewBuilder
    private var accountList: some View {
        if store.cswapMissing {
            MissingCswapView(store: store)
                .frame(height: IslandMetrics.rowHeight)
        } else if store.accounts.isEmpty {
            Text(emptyListMessage)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, minHeight: IslandMetrics.rowHeight)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(store.accounts) { account in
                        AccountRow(store: store, account: account)
                    }
                }
            }
            .frame(height: CGFloat(min(store.accounts.count, IslandMetrics.maxVisibleRows)) * IslandMetrics.rowHeight)
            .disabled(store.needsOnboarding)
            .opacity(store.needsOnboarding ? 0.45 : 1)
        }
    }

    private var emptyListMessage: String {
        if store.isLoading { return "Reading accounts…" }
        return store.needsOnboarding ? "No saved accounts yet." : "No accounts yet. Press Add account below."
    }

    /// Always takes its height, so a message appearing never shifts the rows under the cursor.
    private var noticeBar: some View {
        ZStack(alignment: .leading) {
            Color.clear
            if let notice = store.notice {
                switch notice {
                case .success(let text):
                    Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(Color(level: .calm))
                case .failure(let text):
                    Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color(level: .hot))
                }
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(height: IslandMetrics.noticeHeight)
        .animation(.easeOut(duration: 0.2), value: store.notice)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                store.switchToBest()
            } label: {
                HStack(spacing: 5) {
                    if store.isSwitchingBest {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkle")
                    }
                    Text("Most quota")
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(store.isBusy || store.cswapMissing || store.needsOnboarding)
            .help("Switch to the account with the most quota left")

            Button {
                store.isAdding.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.isAdding ? "xmark" : "plus")
                    Text("Add account")
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(store.cswapMissing || store.needsOnboarding)

            Spacer()
            FooterControls()
        }
        .frame(height: IslandMetrics.footerHeight, alignment: .top)
    }
}

/// Inline rather than a popup menu: a menu window opens in the current Space, which sits
/// underneath the island's own, so any part of it overlapping the panel would be hidden.
private struct FooterControls: View {
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggleLogin) {
                Label("At login", systemImage: launchesAtLogin ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(launchesAtLogin ? 0.85 : 0.5))
            }
            .buttonStyle(.plain)
            .clickCursor()
            .help("Open Swap Island when you log in to this Mac")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle())
            .help("Quit Swap Island")
            .accessibilityLabel("Quit Swap Island")
        }
    }

    private func toggleLogin() {
        do {
            if launchesAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Swap Island: login item change failed: \(error.localizedDescription)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Accounts already in cswap are the same accounts here, so importing them copies nothing:
/// it only turns the rows on. With none saved, the import is the login Claude Code has now.
private struct OnboardingSection: View {
    @ObservedObject var store: IslandStore

    var body: some View {
        let count = store.accounts.count
        VStack(alignment: .leading, spacing: 7) {
            if store.accounts.isEmpty {
                Text("Import the login Claude Code uses now, or log in first.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 6) {
                    Button("Import current login") { store.addCurrentLogin() }
                        .disabled(store.isBusy || store.isLoading)
                    Button("Log in") { store.openLoginInTerminal() }
                }
                .buttonStyle(PillButtonStyle())
            } else {
                Text("Found \(count) \(count == 1 ? "account" : "accounts") in cswap. Nothing gets copied.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.75))
                Button("Import \(count) \(count == 1 ? "account" : "accounts")") { store.finishOnboarding() }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: IslandMetrics.addSectionHeight, alignment: .leading)
    }
}

private struct AddAccountSection: View {
    @ObservedObject var store: IslandStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            step(number: 1, text: "Log in with the other account. Do not log out first.") {
                store.openLoginInTerminal()
            } label: {
                Text("Log in")
            }
            step(number: 2, text: "Then store it here.") {
                store.addCurrentLogin()
            } label: {
                Text("Save this login")
            }
            .disabled(store.isBusy)
        }
        .frame(height: IslandMetrics.addSectionHeight)
    }

    private func step<Label: View>(
        number: Int,
        text: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 15, height: 15)
                .background(Circle().fill(.white.opacity(0.8)))
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            Button(action: action, label: label)
                .buttonStyle(PillButtonStyle())
        }
    }
}

private struct MissingCswapView: View {
    @ObservedObject var store: IslandStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Swap Island needs the cswap command.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 8) {
                Text(IslandStore.installCommand)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") { store.copyInstallCommand() }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountRow: View {
    @ObservedObject var store: IslandStore
    let account: Account
    @State private var confirmsRemoval = false

    private var isHovered: Bool { store.hoveredAccount == account.number }
    private var isSwitching: Bool { store.switchingTo == account.number }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                store.switchTo(account)
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .clickCursor()
            .disabled(store.isBusy)
            .accessibilityLabel(accessibilityText)

            trailing
                .padding(.trailing, 8)
        }
        .padding(.vertical, 2)
        .onGeometryChange(for: CGRect.self, of: HoverAreas.visibleFrame) { [number = account.number] frame in
            HoverAreas.setRow(frame, for: number)
        }
        .onDisappear { HoverAreas.setRow(nil, for: account.number) }
        .onChange(of: isHovered) { _, hovering in
            if !hovering { confirmsRemoval = false }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            AccountBadge(account: account, diameter: 26)
                .opacity(account.isDisabled ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    name
                    statusTag
                }
                usage
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Reserved for the trailing controls, so the meters do not jump on hover.
            Color.clear.frame(width: 46, height: 1)
        }
        .padding(.horizontal, 8)
        .frame(height: IslandMetrics.rowHeight - 4)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.white.opacity(account.active ? 0.09 : (isHovered ? 0.06 : 0)))
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var name: some View {
        Text(account.displayName)
            .font(.system(size: 12, weight: account.active ? .semibold : .medium))
            .foregroundStyle(.white.opacity(account.isDisabled ? 0.5 : 1))
            .lineLimit(1)
            .truncationMode(.middle)
            .opacity(store.hidesEmails ? 0 : 1)
            .overlay(alignment: .leading) {
                if store.hidesEmails {
                    Capsule().fill(.white.opacity(0.24)).frame(height: 10)
                }
            }
    }

    @ViewBuilder
    private var statusTag: some View {
        if account.needsLogin {
            Tag(text: "Needs login", color: Color(level: .hot))
        } else if account.isDisabled {
            Tag(text: "Disabled", color: .white.opacity(0.5))
        } else if account.isUsageStale {
            Tag(text: "Old data", color: .white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var usage: some View {
        if let usage = account.shownUsage {
            HStack(spacing: 10) {
                UsageMeter(label: "5h", window: usage.fiveHour)
                UsageMeter(label: "7d", window: usage.sevenDay)
            }
            .opacity(account.isUsageStale ? 0.55 : 1)
        } else {
            Text("Usage unavailable")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isSwitching {
            ProgressView().controlSize(.small).frame(width: 46)
        } else if isHovered {
            HStack(spacing: 0) {
                Button {
                    store.setDisabled(account, !account.isDisabled)
                } label: {
                    Image(systemName: account.isDisabled ? "play.fill" : "pause.fill")
                        .font(.system(size: 9.5))
                }
                .buttonStyle(IconButtonStyle(side: 23))
                .help(account.isDisabled ? "Return to auto-rotation" : "Hold out of auto-rotation")
                .accessibilityLabel(account.isDisabled ? "Enable account" : "Disable account")

                if !account.active {
                    Button {
                        if confirmsRemoval {
                            store.remove(account)
                        } else {
                            confirmsRemoval = true
                        }
                    } label: {
                        Image(systemName: confirmsRemoval ? "trash.fill" : "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(confirmsRemoval ? Color(level: .hot) : .white.opacity(0.7))
                    }
                    .buttonStyle(IconButtonStyle(side: 23))
                    .help(confirmsRemoval ? "Click again to remove this account" : "Remove account")
                    .accessibilityLabel("Remove account")
                }
            }
            .disabled(store.isBusy)
        } else if account.active {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(level: .calm))
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 2)
        }
    }

    private var accessibilityText: String {
        let five = account.shownUsage?.fiveHour.map { "5 hour \(Int($0.pct)) percent" } ?? ""
        let seven = account.shownUsage?.sevenDay.map { "7 day \(Int($0.pct)) percent" } ?? ""
        return [account.displayName, account.active ? "active" : "switch to this account", five, seven]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

private struct UsageMeter: View {
    let label: String
    let window: UsageWindow?

    var body: some View {
        let pct = window?.pct ?? 0
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(.white.opacity(0.5))
                Text("\(Int(pct.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(Color(level: UsageLevel(pct: pct)))
                Spacer(minLength: 0)
                if let countdown = window?.countdown {
                    Text(countdown).foregroundStyle(.white.opacity(0.4)).monospacedDigit()
                }
            }
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(Color(level: UsageLevel(pct: pct)))
                        .frame(width: proxy.size.width * min(pct, 100) / 100)
                    // The even-pace mark: past it, this week is burning faster than it lasts.
                    if let expected = window?.expectedPct {
                        Rectangle()
                            .fill(.white.opacity(0.85))
                            .frame(width: 1.5, height: 6)
                            .offset(x: proxy.size.width * min(expected, 100) / 100)
                    }
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().stroke(color.opacity(0.5), lineWidth: 0.75))
    }
}

struct AccountBadge: View {
    let account: Account
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(Color.badge(for: account.email))
            .frame(width: diameter, height: diameter)
            .overlay(
                Text(account.initial)
                    .font(.system(size: diameter * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.82))
            )
    }
}

// MARK: - Styling

/// Where the enabled buttons and the rows are, in window coordinates, for `IslandController` to
/// compare with the mouse. `onHover` would be simpler, but it misses enters and exits in this
/// never-frontmost panel: 7 of 39 pointer moves left the wrong cursor when it was measured.
@MainActor
enum HoverAreas {
    private static var buttons: [UUID: CGRect] = [:]
    private static var rows: [Int: CGRect] = [:]

    static func setButton(_ frame: CGRect?, for id: UUID) {
        buttons[id] = frame
    }

    static func setRow(_ frame: CGRect?, for account: Int) {
        rows[account] = frame
    }

    static func isOverButton(_ point: CGPoint) -> Bool {
        buttons.values.contains { $0.contains(point) }
    }

    static func account(at point: CGPoint) -> Int? {
        rows.first { $0.value.contains(point) }?.key
    }

    /// Clipped to the account list, so a row scrolled out of view does not claim what is drawn there.
    nonisolated static func visibleFrame(_ proxy: GeometryProxy) -> CGRect {
        let frame = proxy.frame(in: .global)
        guard let clip = proxy.bounds(of: .scrollView) else { return frame }
        return CGRect(origin: .zero, size: proxy.size).intersection(clip)
            .offsetBy(dx: frame.minX, dy: frame.minY)
    }
}

private struct ButtonHoverArea: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var id = UUID()
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: HoverAreas.visibleFrame) { frame = $0 }
            .onChange(of: isEnabled ? frame : nil) { _, target in HoverAreas.setButton(target, for: id) }
            .onDisappear { HoverAreas.setButton(nil, for: id) }
    }
}

private extension View {
    /// Goes inside any `.disabled`, so a disabled button keeps the arrow.
    func clickCursor() -> some View { modifier(ButtonHoverArea()) }
}

private struct IconButtonStyle: ButtonStyle {
    var side: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.4 : 0.7))
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .clickCursor()
    }
}

private struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(isEnabled ? 0.92 : 0.4))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.2 : 0.11)))
            .clickCursor()
    }
}

extension Color {
    init(level: UsageLevel) {
        switch level {
        case .calm: self = Color(red: 0.40, green: 0.85, blue: 0.55)
        case .warm: self = Color(red: 0.98, green: 0.72, blue: 0.30)
        case .hot: self = Color(red: 0.98, green: 0.42, blue: 0.38)
        }
    }

    /// A stable hue per email, so an account keeps its colour across launches.
    static func badge(for email: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.96, green: 0.76, blue: 0.48),
            Color(red: 0.55, green: 0.85, blue: 0.80),
            Color(red: 0.95, green: 0.60, blue: 0.55),
            Color(red: 0.70, green: 0.85, blue: 0.50),
            Color(red: 0.60, green: 0.78, blue: 0.96),
            Color(red: 0.93, green: 0.80, blue: 0.70),
        ]
        let hash = email.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }
        return palette[Int(hash % UInt32(palette.count))]
    }
}
