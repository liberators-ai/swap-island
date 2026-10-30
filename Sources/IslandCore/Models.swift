import Foundation

/// The `cswap list --json` contract is additive, so every field beyond identity is optional
/// and unknown keys are ignored.
public struct AccountList: Decodable, Sendable, Equatable {
    public let activeAccountNumber: Int?
    public let accounts: [Account]
}

public struct Account: Decodable, Sendable, Equatable, Identifiable {
    public let number: Int
    public let email: String
    public let active: Bool
    public let alias: String?
    public let disabled: Bool?
    public let usageStatus: String?
    public let usage: Usage?
    /// Present when `usage` is null but an older measurement exists.
    public let lastGoodUsage: Usage?

    public var id: Int { number }
    public var isDisabled: Bool { disabled ?? false }
    public var displayName: String { alias ?? email }
    public var initial: String { String(displayName.prefix(1)).uppercased() }

    /// Live numbers when trusted, otherwise the last known ones, so a blip never empties the row.
    public var shownUsage: Usage? { usage ?? lastGoodUsage }
    public var isUsageStale: Bool { usage == nil && lastGoodUsage != nil }

    /// A login that has died is the one state where clicking the row cannot help.
    public var needsLogin: Bool {
        usageStatus == "relogin_required" || usageStatus == "token_expired"
    }
}

public struct Usage: Decodable, Sendable, Equatable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
}

public struct UsageWindow: Decodable, Sendable, Equatable {
    public let pct: Double
    public let countdown: String?
    /// Where weekly usage would sit if spread evenly across the week. Weekly windows only.
    public let expectedPct: Double?
}

public struct SwitchResult: Decodable, Sendable, Equatable {
    public let switched: Bool
    public let reason: String?

    public enum Outcome: Sendable, Equatable {
        case switched
        /// Nothing needed doing. Not an error, and must not read like one.
        case alreadyThere(String)
        case blocked(String)
    }

    public var outcome: Outcome {
        if switched { return .switched }
        switch reason {
        case "already-active": return .alreadyThere("Already on this account.")
        case "already-best": return .alreadyThere("Already on the account with the most quota.")
        case "only-one-account": return .blocked("Only one account is set up.")
        case "candidates-exhausted", "no-valid-target": return .blocked("No other account has quota left.")
        case "usage-unavailable": return .blocked("Usage is unavailable right now. Try again shortly.")
        case "unmanaged-account": return .blocked("The current login is not managed by cswap. Run cswap add.")
        default: return .blocked("cswap did not switch.")
        }
    }
}

public struct CswapErrorPayload: Decodable, Sendable, Equatable {
    public struct Detail: Decodable, Sendable, Equatable {
        public let message: String?
    }
    public let error: Detail?
}

public enum UsageLevel: Sendable, Equatable {
    case calm, warm, hot

    public init(pct: Double) {
        switch pct {
        case ..<70: self = .calm
        case ..<90: self = .warm
        default: self = .hot
        }
    }
}
