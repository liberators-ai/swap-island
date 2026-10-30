import Foundation

/// A dotted release number. Compared as numbers, so 0.1.10 is newer than 0.1.9.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    private let parts: [Int]

    public init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !trimmed.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String {
        parts.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// The part of GitHub's latest-release answer the updater reads.
public struct LatestRelease: Decodable, Sendable {
    public let tagName: String

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}

/// The part of PyPI's project answer the cswap update check reads.
public struct PyPIProject: Decodable, Sendable {
    public let info: Info

    public struct Info: Decodable, Sendable {
        public let version: String
    }
}

public enum ReleaseChecksum {
    /// The hex digest from a line of `shasum -a 256` output.
    public static func digest(in text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isWhitespace).first, first.count == 64 else { return nil }
        return first.allSatisfy(\.isHexDigit) ? String(first).lowercased() : nil
    }
}
