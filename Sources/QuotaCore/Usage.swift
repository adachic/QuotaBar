import Foundation

public enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex, claude
    public var id: String { rawValue }
    public var title: String { self == .codex ? "Codex" : "Claude Code" }
    public var symbol: String { self == .codex ? "chevron.left.forwardslash.chevron.right" : "asterisk" }
    public var usageURL: URL {
        URL(string: self == .codex ? "https://chatgpt.com/codex/settings/usage" : "https://claude.ai/settings/usage")!
    }
}

public enum DisplayWindow: String, CaseIterable, Identifiable, Sendable {
    case session, weekly, lowest
    public var id: String { rawValue }
    public var title: String {
        switch self { case .session: "5時間"; case .weekly: "週間"; case .lowest: "少ない方" }
    }
}

public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var durationMinutes: Int?

    public init(id: String, title: String, usedPercent: Double, resetsAt: Date? = nil, durationMinutes: Int? = nil) {
        self.id = id; self.title = title; self.usedPercent = usedPercent
        self.resetsAt = resetsAt; self.durationMinutes = durationMinutes
    }

    public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
    // Do not show 100% while some of the allowance has already been consumed.
    public var displayPercent: Int { Int(remainingPercent.rounded(.down)) }
    public func hasReset(at date: Date = Date()) -> Bool { resetsAt.map { $0 <= date } ?? false }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var provider: Provider
    public var windows: [UsageWindow]
    public var plan: String?
    public var fetchedAt: Date
    public init(provider: Provider, windows: [UsageWindow], plan: String? = nil, fetchedAt: Date = Date()) {
        self.provider = provider; self.windows = windows; self.plan = plan; self.fetchedAt = fetchedAt
    }
    public func selected(_ selection: DisplayWindow, at date: Date = Date()) -> UsageWindow? {
        // An elapsed reset never implies a fresh 100% allowance. Wait for the server.
        let valid = windows.filter { !$0.hasReset(at: date) }
        switch selection {
        case .session: return valid.first { $0.id == "session" }
        case .weekly: return valid.first { $0.id == "weekly" }
        case .lowest:
            return valid.filter { $0.id == "session" || $0.id == "weekly" }
                .min { $0.remainingPercent < $1.remainingPercent }
        }
    }
    public func isStale(at date: Date = Date(), interval: TimeInterval = 180) -> Bool {
        date.timeIntervalSince(fetchedAt) > max(300, interval * 2)
    }
}

public enum UsageError: Error, LocalizedError, Equatable, Sendable {
    case missingCodex, codexUnavailable, notSignedIn(Provider), keychainLocked
    case missingScope, invalidResponse, noLimits, timeout, offline
    case http(Int), throttled(TimeInterval), server(String)
    public var errorDescription: String? {
        switch self {
        case .missingCodex: return "Codex CLIが見つかりません。設定で実行ファイルを選択してください。"
        case .codexUnavailable: return "Codexに接続できません。CLIでログインと設定を確認してください。"
        case .notSignedIn(.codex): return "Codex CLIでChatGPTアカウントにログインしてください。"
        case .notSignedIn(.claude): return "Claude Codeで /login を実行し、再接続してください。"
        case .keychainLocked: return "キーチェーンを読み取れません。接続ボタンでアクセスを許可してください。"
        case .missingScope: return "Claude Codeで /login を実行し、利用状況のアクセス権を更新してください。"
        case .invalidResponse: return "利用状況の形式を読み取れません。サービス側の仕様が変わった可能性があります。"
        case .noLimits: return "取得できる利用枠がありません。サブスクリプションのログインを確認してください。"
        case .timeout: return "接続がタイムアウトしました。しばらくしてから再試行してください。"
        case .offline: return "ネットワークに接続できません。"
        case .http(let code): return "利用状況を取得できません（HTTP \(code)）。"
        case .throttled: return "アクセスが混み合っています。時間をおいて自動で再試行します。"
        case .server: return "Codexの利用状況を取得できません。CLIのログインを確認してください。"
        }
    }
}

public enum UsageParser {
    public static func codex(_ data: Data, at date: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.invalidResponse }
        let payload = root["result"] as? [String: Any] ?? root
        let byID = payload["rateLimitsByLimitId"] as? [String: Any]
        // Never substitute an unrelated model bucket for the core Codex allowance.
        let bucket = byID?["codex"] as? [String: Any] ?? payload["rateLimits"] as? [String: Any]
        guard let bucket else { throw UsageError.noLimits }
        if let id = bucket["limitId"] as? String, id != "codex" { throw UsageError.noLimits }
        var windows: [UsageWindow] = []
        for (key, fallbackID) in [("primary", "session"), ("secondary", "weekly")] {
            guard let raw = bucket[key] as? [String: Any], let percent = number(raw["usedPercent"]) else { continue }
            let duration = number(raw["windowDurationMins"]).flatMap { $0 > 0 && $0 < 1_000_000 ? Int($0) : nil }
            let id = duration.map { $0 >= 10_080 ? "weekly" : "session" } ?? fallbackID
            let title: String
            if let duration {
                title = duration == 10_080 ? "週間" : duration % 60 == 0 ? "\(duration / 60)時間" : "\(duration)分"
            } else { title = id == "weekly" ? "週間" : "短時間枠" }
            windows.append(UsageWindow(id: id, title: title, usedPercent: percent,
                                       resetsAt: unixDate(raw["resetsAt"]), durationMinutes: duration))
        }
        guard !windows.isEmpty else { throw UsageError.noLimits }
        return UsageSnapshot(provider: .codex, windows: windows, plan: bucket["planType"] as? String, fetchedAt: date)
    }

    public static func claude(_ data: Data, at date: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.invalidResponse }
        let keys = [("five_hour", "session", "5時間", 300), ("seven_day", "weekly", "週間", 10_080),
                    ("seven_day_sonnet", "sonnet", "Sonnet・週間", 10_080),
                    ("seven_day_opus", "opus", "Opus・週間", 10_080)]
        let windows: [UsageWindow] = keys.compactMap { key, id, title, duration in
            guard let raw = root[key] as? [String: Any], let used = number(raw["utilization"]) else { return nil }
            return UsageWindow(id: id, title: title, usedPercent: used,
                               resetsAt: isoDate(raw["resets_at"]), durationMinutes: duration)
        }
        guard !windows.isEmpty else { throw UsageError.noLimits }
        return UsageSnapshot(provider: .claude, windows: windows, fetchedAt: date)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func unixDate(_ value: Any?) -> Date? {
        number(value).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }
    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return unixDate(value) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

import CoreFoundation
