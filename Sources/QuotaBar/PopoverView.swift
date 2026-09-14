import SwiftUI
import QuotaCore

extension Provider {
    var tint: Color { self == .codex ? Color(red: 0.12, green: 0.60, blue: 0.49) : Color(red: 0.76, green: 0.43, blue: 0.30) }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    var onResize: (NSSize) -> Void = { _ in }
    @State private var naturalHeight: CGFloat = 430
    private let contentWidth: CGFloat = 360
    private var scale: CGFloat {
        min(1, store.panelSize.height / max(1, naturalHeight), store.panelSize.width / contentWidth)
    }
    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.vertical, 13)
            if store.settingsVisible {
                settings
            } else {
                dashboard
            }
            footer
        }
        .frame(width: contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
        })
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: contentWidth * scale, height: naturalHeight * scale, alignment: .topLeading)
        .background(.regularMaterial)
        .environment(\.locale, Locale(identifier: "ja_JP"))
        .onPreferenceChange(PanelHeightKey.self) { height in
            if height > 0, abs(height - naturalHeight) > 0.5 { naturalHeight = height }
        }
        .onChange(of: naturalHeight) { _, _ in resize() }
        .onChange(of: store.panelSize) { _, _ in resize() }
        .onAppear { resize() }
    }
    private func resize() { onResize(NSSize(width: contentWidth * scale, height: naturalHeight * scale)) }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)).frame(width: 34, height: 34)
                Image(systemName: "battery.75percent").font(.system(size: 19, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("QuotaBar").font(.system(size: 15, weight: .semibold))
                Text(store.settingsVisible ? "いつも、ひと目で。" : "利用できる残量")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if store.demo { Text("デモ").font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4).background(.quaternary, in: Capsule()) }
            Button { store.refreshAll() } label: {
                if store.isRefreshing { ProgressView().controlSize(.small).frame(width: 25, height: 25) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium)).frame(width: 25, height: 25) }
            }
            .buttonStyle(.plain).disabled(store.isRefreshing || store.demo)
            .help("今すぐ更新").accessibilityLabel("今すぐ更新")
        }
    }

    private var dashboard: some View {
        VStack(spacing: 10) {
            Picker("メニューバーに表示する枠", selection: $store.selection) {
                ForEach(DisplayWindow.allCases) { selection in Text(selection.title).tag(selection) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 2)
            VStack(spacing: 9) {
                ForEach(Provider.allCases) { provider in ProviderCard(store: store, provider: provider) }
            }
            HStack(spacing: 5) {
                Image(systemName: "info.circle").font(.system(size: 10))
                Text(store.selection == .lowest ? "取得できた枠のうち、残りが少ない方を表示" : "メニューバーには\(store.selection.title)枠の残量を表示")
                    .font(.system(size: 9))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary).padding(.horizontal, 3)
        }.padding(.horizontal, 14).padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text(footerText).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.settingsVisible.toggle()
                } label: {
                    Image(systemName: store.settingsVisible ? "chevron.left" : "gearshape")
                        .font(.system(size: 13)).frame(width: 26, height: 24)
                }
                .buttonStyle(.plain).help(store.settingsVisible ? "残量に戻る" : "設定")
                .accessibilityLabel(store.settingsVisible ? "残量に戻る" : "設定")
                Divider().frame(height: 12)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power").font(.system(size: 12)).frame(width: 26, height: 24)
                }.buttonStyle(.plain).help("QuotaBarを終了").accessibilityLabel("QuotaBarを終了")
            }.padding(.horizontal, 18).padding(.vertical, 10)
        }
    }
    private var statusColor: Color {
        if store.demo { return .secondary }
        if store.isRefreshing { return .secondary }
        if store.states.values.contains(where: { $0.error != nil }) { return .orange }
        return .green
    }
    private var footerText: String {
        if store.demo { return "プレビュー用のサンプルデータ" }
        if store.isRefreshing { return "利用状況を更新中…" }
        if store.states.values.contains(where: { $0.error != nil }) { return "接続状態を確認してください" }
        return "\(Int(store.interval / 60))分ごとに自動更新"
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("メニューバーに％を表示", isOn: $store.showPercent).toggleStyle(.switch).controlSize(.small)
            HStack {
                Text("更新間隔")
                Spacer()
                Picker("更新間隔", selection: $store.interval) {
                    Text("1分").tag(60.0); Text("3分").tag(180.0)
                    Text("5分").tag(300.0); Text("15分").tag(900.0)
                }.labelsHidden().frame(width: 95)
            }
            Toggle("ログイン時に起動", isOn: Binding(get: { store.loginItemEnabled }, set: { store.setLoginItem($0) }))
                .toggleStyle(.switch).controlSize(.small).disabled(store.demo)
            if let message = store.settingsMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("Codex CLI").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(CodexClient.findExecutable(override: store.codexPath)?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "見つかりません")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                HStack {
                    Button("ファイルを選択…") { store.chooseCodex() }
                    if !store.codexPath.isEmpty { Button("自動検出") { store.codexPath = ""; store.refresh(.codex) } }
                }.controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Claude Code").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text("初回はキーチェーンへのアクセスを許可してください。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Claude Codeに接続") { store.refresh(.claude, allowInteraction: true) }
                    .controlSize(.small).disabled(store.demo || store.state(.claude).refreshing)
            }
            Divider()
            Text("QuotaBar 1.0.1 · 認証情報は保存しません")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 11)).padding(.horizontal, 20).padding(.bottom, 15)
    }
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 430
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ProviderCard: View {
    @ObservedObject var store: UsageStore
    let provider: Provider
    private var state: ProviderState { store.state(provider) }
    private var window: UsageWindow? { store.selected(provider) }
    private var tint: Color {
        guard let window else { return .secondary }
        if store.isStale(provider) { return .secondary }
        if window.remainingPercent <= 10 { return .red }
        if window.remainingPercent <= 20 { return .orange }
        return provider.tint
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: provider.symbol).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(provider.tint).frame(width: 24, height: 24)
                    .background(provider.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 4) {
                    Button { NSWorkspace.shared.open(provider.usageURL) } label: {
                        HStack(spacing: 4) {
                            Text(provider.title).font(.system(size: 12, weight: .semibold))
                            Image(systemName: "arrow.up.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain).help("\(provider.title)の利用状況を開く")
                    if store.isStale(provider) {
                        Text("前回の値").font(.system(size: 9)).foregroundStyle(.orange)
                    } else if let fetched = state.snapshot?.fetchedAt {
                        Text("\(fetched.formatted(.dateTime.hour().minute())) 更新")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(window.map { String($0.displayPercent) } ?? "—")
                            .font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("%").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    }
                    Text("\(window?.title ?? store.selection.title)・残り").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                BatteryGauge(fraction: window.map { $0.remainingPercent / 100 }, tint: tint)
                    .frame(width: 53, height: 23).padding(.leading, 2).accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(provider.title) \(window?.title ?? store.selection.title) 残り \(window.map { "\($0.displayPercent)パーセント" } ?? "未取得")\(store.isStale(provider) ? "、前回の値" : "")")
            if let snapshot = state.snapshot {
                if window == nil {
                    Text(snapshot.windows.contains { $0.hasReset(at: store.now) } ? "リセット後の残量を確認待ちです" : "選択した枠は提供されていません")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    ForEach(snapshot.windows.filter { $0.id == "session" || $0.id == "weekly" }) { row in
                        WindowRow(window: row, tint: provider.tint, now: store.now, stale: store.isStale(provider))
                    }
                }
            } else if state.refreshing {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("利用状況を取得しています…").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(height: 22)
            }
            if let error = state.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if state.needsConnection && provider == .claude {
                        Button("Claude Codeに接続") { store.refresh(.claude, allowInteraction: true) }
                            .controlSize(.small).disabled(state.refreshing)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.66), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.045), lineWidth: 1))
    }
}

struct BatteryGauge: View {
    let fraction: Double?
    let tint: Color
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 6
            let height = geometry.size.height
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.20)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1.8).frame(width: width)
                if let fraction {
                    RoundedRectangle(cornerRadius: height * 0.11)
                        .fill(tint.gradient)
                        .frame(width: max(0, (width - 8) * min(1, max(0, fraction))), height: height - 8)
                        .padding(.leading, 4)
                } else {
                    Text("—").font(.system(size: height * 0.5, weight: .medium))
                        .foregroundStyle(.tertiary).frame(width: width)
                }
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 2, topTrailingRadius: 2)
                    .fill(tint.opacity(0.4)).frame(width: 3, height: height * 0.35).offset(x: width + 2)
            }
        }
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let tint: Color
    let now: Date
    let stale: Bool
    private var expired: Bool { window.hasReset(at: now) }
    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.system(size: 10, weight: .medium))
                Spacer()
                Text(resetText).font(.system(size: 9)).foregroundStyle(.secondary)
                Text(expired ? "—" : "\(window.displayPercent)%")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule().fill(stale || expired ? Color.secondary.opacity(0.35) : window.remainingPercent <= 10 ? .red : tint)
                        .frame(width: expired ? 0 : geometry.size.width * window.remainingPercent / 100)
                }
            }.frame(height: 3)
        }.help(window.resetsAt.map { "リセット: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "リセット時刻は未提供")
    }
    private var resetText: String {
        guard let date = window.resetsAt else { return "リセット時刻 未提供" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "リセット確認待ち" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 { return "あと\(minutes / 1440)日\((minutes % 1440) / 60)時間" }
        if minutes >= 60 { return "あと\(minutes / 60)時間\(minutes % 60)分" }
        return "あと\(minutes)分"
    }
}
