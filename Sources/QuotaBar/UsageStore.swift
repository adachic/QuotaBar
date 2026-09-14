import AppKit
import Combine
import QuotaCore
import ServiceManagement

struct ProviderState {
    var snapshot: UsageSnapshot?
    var error: String?
    var refreshing = false
    var retryAfter: Date?
    var needsConnection = false
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var states: [Provider: ProviderState] = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderState()) })
    @Published var selection: DisplayWindow {
        didSet { if !demo { UserDefaults.standard.set(selection.rawValue, forKey: "displayWindow") } }
    }
    @Published var showPercent: Bool {
        didSet { if !demo { UserDefaults.standard.set(showPercent, forKey: "showPercent") } }
    }
    @Published var interval: Double {
        didSet { if !demo { UserDefaults.standard.set(interval, forKey: "refreshInterval") }; schedule() }
    }
    @Published var codexPath: String {
        didSet { if !demo { UserDefaults.standard.set(codexPath, forKey: "codexPath") } }
    }
    @Published var settingsVisible = false
    @Published var panelSize = NSSize(width: 370, height: 620)
    @Published var loginItemEnabled = SMAppService.mainApp.status == .enabled
    @Published var settingsMessage: String?
    @Published var now = Date()
    let demo: Bool
    private var timer: Timer?
    private var clockTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(demo: Bool = false) {
        self.demo = demo
        let defaults = UserDefaults.standard
        selection = demo ? .lowest : DisplayWindow(rawValue: defaults.string(forKey: "displayWindow") ?? "") ?? .lowest
        showPercent = demo ? true : defaults.object(forKey: "showPercent") as? Bool ?? true
        let savedInterval = defaults.double(forKey: "refreshInterval")
        interval = [60, 180, 300, 900].contains(savedInterval) ? savedInterval : 180
        codexPath = defaults.string(forKey: "codexPath") ?? ""
        if demo {
            let now = Date()
            states[.codex]?.snapshot = UsageSnapshot(provider: .codex, windows: [
                .init(id: "session", title: "5時間", usedPercent: 18, resetsAt: now.addingTimeInterval(2 * 3600 + 24 * 60)),
                .init(id: "weekly", title: "週間", usedPercent: 36, resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600))
            ], plan: "Pro")
            states[.claude]?.snapshot = UsageSnapshot(provider: .claude, windows: [
                .init(id: "session", title: "5時間", usedPercent: 33, resetsAt: now.addingTimeInterval(3600 + 48 * 60)),
                .init(id: "weekly", title: "週間", usedPercent: 59, resetsAt: now.addingTimeInterval(2 * 86400 + 8 * 3600))
            ])
        }
    }

    var isRefreshing: Bool { states.values.contains { $0.refreshing } }
    func state(_ provider: Provider) -> ProviderState { states[provider] ?? ProviderState() }
    func selected(_ provider: Provider) -> UsageWindow? { state(provider).snapshot?.selected(selection, at: now) }
    func isStale(_ provider: Provider) -> Bool {
        let state = state(provider)
        return state.snapshot != nil && (state.error != nil || state.snapshot!.isStale(at: now, interval: interval))
    }
    func start() {
        guard !demo else { return }
        refreshAll()
        schedule()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refreshAll() } }
    }
    func stop() {
        timer?.invalidate(); clockTimer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
    private func schedule() {
        timer?.invalidate()
        guard !demo else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        timer?.tolerance = 10
    }
    func refreshAll() {
        now = Date()
        for provider in Provider.allCases { refresh(provider) }
    }
    func refresh(_ provider: Provider, allowInteraction: Bool = false) {
        guard !demo, !state(provider).refreshing else { return }
        if let retry = state(provider).retryAfter, retry > Date() { return }
        states[provider]?.refreshing = true
        let executable = CodexClient.findExecutable(override: codexPath)
        Task {
            do {
                let snapshot: UsageSnapshot
                if provider == .codex {
                    guard let executable else { throw UsageError.missingCodex }
                    snapshot = try await CodexClient.fetch(executable: executable)
                } else {
                    snapshot = try await ClaudeClient.fetch(allowInteraction: allowInteraction)
                }
                states[provider] = ProviderState(snapshot: snapshot)
            } catch {
                states[provider]?.refreshing = false
                states[provider]?.error = (error as? UsageError)?.localizedDescription ?? "接続を確認して再試行してください。"
                if case UsageError.throttled(let delay) = error {
                    states[provider]?.retryAfter = Date().addingTimeInterval(delay)
                }
                if case UsageError.keychainLocked = error { states[provider]?.needsConnection = true }
                if case UsageError.notSignedIn = error { states[provider]?.needsConnection = true }
            }
            now = Date()
        }
    }
    func setLoginItem(_ enabled: Bool) {
        guard !demo else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            settingsMessage = SMAppService.mainApp.status == .requiresApproval
                ? "システム設定の「ログイン項目」でQuotaBarを許可してください。" : nil
        } catch {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            settingsMessage = "アプリケーションフォルダに移動してから設定してください。"
        }
    }
    func chooseCodex() {
        let panel = NSOpenPanel()
        panel.title = "Codexの実行ファイルを選択"
        panel.message = "通常は ~/.local/bin/codex または /opt/homebrew/bin/codex にあります。"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            codexPath = url.path
            refresh(.codex)
        }
    }
}
