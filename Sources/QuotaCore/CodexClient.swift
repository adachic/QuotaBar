import Foundation
import Darwin

public enum CodexClient {
    public static func findExecutable(override: String? = nil) -> URL? {
        let fm = FileManager.default
        if let override, !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "/Applications/Codex.app/Contents/Resources/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex",
                          "\(home)/Applications/Codex.app/Contents/Resources/codex"]
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return (candidates + paths).first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    public static func fetch(executable: URL, timeout: TimeInterval = 25) async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) {
            let data = try readRateLimits(executable: executable, timeout: timeout)
            return try UsageParser.codex(data)
        }.value
    }

    // A short-lived stdio connection. No threads, turns, inference, or reset credits are created.
    static func readRateLimits(executable: URL, timeout: TimeInterval) throws -> Data {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UsageError.codexUnavailable }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let stop = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < stop { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": [
            "name": "quota_bar", "title": "QuotaBar", "version": "1.0.0"]]])
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var pending = Data()
        var initialized = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw UsageError.codexUnavailable }
            if ready == 0 { if !process.isRunning { throw UsageError.codexUnavailable }; continue }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageError.codexUnavailable }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count <= 2_000_000 else { throw UsageError.invalidResponse }
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                guard let id = message["id"] as? Int else { continue }
                if message["error"] != nil { throw UsageError.server("rpc") }
                if id == 0 && !initialized {
                    initialized = true
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 1, "method": "account/rateLimits/read"])
                } else if id == 1 && initialized {
                    guard let result = message["result"] as? [String: Any] else { throw UsageError.invalidResponse }
                    return try JSONSerialization.data(withJSONObject: result)
                }
            }
        }
        throw UsageError.timeout
    }
}
