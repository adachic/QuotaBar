import XCTest
@testable import QuotaCore

final class UsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testUsedPercentageBecomesRemainingAndClamps() {
        XCTAssertEqual(UsageWindow(id: "session", title: "5時間", usedPercent: 18).displayPercent, 82)
        XCTAssertEqual(UsageWindow(id: "session", title: "5時間", usedPercent: 23.5).displayPercent, 76)
        XCTAssertEqual(UsageWindow(id: "session", title: "5時間", usedPercent: 150).displayPercent, 0)
        XCTAssertEqual(UsageWindow(id: "session", title: "5時間", usedPercent: -20).displayPercent, 100)
    }
    func testCodexPrefersCoreMultiBucketOverLegacyAndOtherModels() throws {
        let json = #"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":18,"windowDurationMins":300,"resetsAt":1900000000},"secondary":{"usedPercent":36,"windowDurationMins":10080}},"codex_other":{"primary":{"usedPercent":100}}}}"#
        let result = try UsageParser.codex(data(json), at: now)
        XCTAssertEqual(result.selected(.session, at: now)?.displayPercent, 82)
        XCTAssertEqual(result.selected(.weekly, at: now)?.displayPercent, 64)
        XCTAssertEqual(result.selected(.lowest, at: now)?.id, "weekly")
        XCTAssertEqual(result.plan, "pro")
        XCTAssertEqual(result.fetchedAt, now)
    }
    func testLegacyCodexAndMissingWeekly() throws {
        let result = try UsageParser.codex(data(#"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300},"secondary":null}}"#))
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.selected(.session)?.displayPercent, 88)
        XCTAssertNil(result.selected(.weekly))
    }
    func testCodexWeeklyOnlyAccountUsesTheActualWindowDuration() throws {
        let result = try UsageParser.codex(data(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":10080},"secondary":null}}"#))
        XCTAssertNil(result.selected(.session))
        XCTAssertEqual(result.selected(.weekly)?.displayPercent, 80)
        XCTAssertEqual(result.selected(.lowest)?.title, "週間")
    }
    func testUnknownIsNeverZeroOrOneHundred() {
        for json in [#"{"rateLimits":null}"#, #"{"rateLimits":{"primary":{"usedPercent":null}}}"#,
                     #"{"rateLimits":{"primary":{"usedPercent":true}}}"#,
                     #"{"rateLimits":{"primary":{"usedPercent":"20"}}}"#,
                     #"{"rateLimits":{"limitId":"codex_other","primary":{"usedPercent":20}}}"#] {
            XCTAssertThrowsError(try UsageParser.codex(data(json)))
        }
        XCTAssertThrowsError(try UsageParser.claude(data(#"{"five_hour":null,"seven_day":null}"#)))
    }
    func testClaudeFractionalAndOptionalModelWindows() throws {
        let json = #"{"five_hour":{"utilization":33.5,"resets_at":"2030-01-01T12:00:00.123Z"},"seven_day":{"utilization":59,"resets_at":"2030-01-03T12:00:00Z"},"seven_day_sonnet":{"utilization":99,"resets_at":null},"seven_day_opus":null,"extra_usage":{"utilization":100}}"#
        let snapshot = try UsageParser.claude(data(json), at: now)
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.selected(.session, at: now)?.displayPercent, 66)
        XCTAssertEqual(snapshot.selected(.lowest, at: now)?.displayPercent, 41)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertNotNil(snapshot.windows[1].resetsAt)
        XCTAssertNil(snapshot.windows[2].resetsAt)
    }
    func testExpiredWindowWaitsForServerWithoutAssumingAFullReset() {
        let snapshot = UsageSnapshot(provider: .codex, windows: [
            .init(id: "session", title: "5時間", usedPercent: 99, resetsAt: now.addingTimeInterval(-1)),
            .init(id: "weekly", title: "週間", usedPercent: 20, resetsAt: now.addingTimeInterval(100))
        ], fetchedAt: now)
        XCTAssertNil(snapshot.selected(.session, at: now))
        XCTAssertEqual(snapshot.selected(.lowest, at: now)?.displayPercent, 80)
        XCTAssertFalse(snapshot.isStale(at: now.addingTimeInterval(359)))
        XCTAssertTrue(snapshot.isStale(at: now.addingTimeInterval(361)))
    }
    func testRateLimitRetryAfterIsRespectedAndBounded() throws {
        XCTAssertNoThrow(try ClaudeClient.validate(status: 200))
        XCTAssertThrowsError(try ClaudeClient.validate(status: 429, retryAfter: "600")) { error in
            XCTAssertEqual(error as? UsageError, .throttled(600))
        }
        XCTAssertThrowsError(try ClaudeClient.validate(status: 429, retryAfter: "-2")) { error in
            XCTAssertEqual(error as? UsageError, .throttled(60))
        }
        XCTAssertThrowsError(try ClaudeClient.validate(status: 401)) { error in
            XCTAssertEqual(error as? UsageError, .notSignedIn(.claude))
        }
        XCTAssertThrowsError(try ClaudeClient.validate(status: 403)) { error in
            XCTAssertEqual(error as? UsageError, .missingScope)
        }
        XCTAssertThrowsError(try ClaudeClient.validate(status: 302))
    }
    func testCredentialParsingRequiresAUsableSubscriptionToken() throws {
        XCTAssertEqual(try ClaudeCredentials.token(from: data(#"{"claudeAiOauth":{"accessToken":"test-only","scopes":["user:profile"],"expiresAt":4102444800000}}"#)), "test-only")
        XCTAssertThrowsError(try ClaudeCredentials.token(from: data(#"{"claudeAiOauth":{"accessToken":"test-only","expiresAt":1000}}"#)))
        XCTAssertThrowsError(try ClaudeCredentials.token(from: data(#"{"claudeAiOauth":{"accessToken":"test-only","scopes":["user:inference"]}}"#)))
        XCTAssertThrowsError(try ClaudeCredentials.token(from: data(#"{"apiKey":"test-only"}"#)))
    }
}

final class CodexTransportTests: XCTestCase {
    private func withServer(_ script: String, body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-test-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
    func testHandshakeIgnoresNotificationsAndAssemblesFragmentedLines() throws {
        try withServer(#"""
        read -r init
        printf '%s\n' '{"method":"noise"}' '{"id":0,"result":{}}'
        read -r initialized
        read -r request
        printf '%s' '{"id":1,"result":{"rateLimits":'
        printf '%s\n' '{"primary":{"usedPercent":12,"windowDurationMins":300}}}}'
        read -r end
        """#) { url in
            let response = try CodexClient.readRateLimits(executable: url, timeout: 3)
            XCTAssertEqual(try UsageParser.codex(response).selected(.session)?.displayPercent, 88)
        }
    }
    func testServerErrorAndPrematureExit() throws {
        try withServer("read -r init\nprintf '%s\\n' '{\"id\":0,\"error\":{\"code\":-1}}'\n") { url in
            XCTAssertThrowsError(try CodexClient.readRateLimits(executable: url, timeout: 3))
        }
        try withServer("exit 1\n") { url in
            XCTAssertThrowsError(try CodexClient.readRateLimits(executable: url, timeout: 3))
        }
    }
    func testHangingServerIsTerminatedOnDeadline() throws {
        try withServer("exec /bin/sleep 10\n") { url in
            let start = Date()
            XCTAssertThrowsError(try CodexClient.readRateLimits(executable: url, timeout: 0.2)) { error in
                XCTAssertEqual(error as? UsageError, .timeout)
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }
}
