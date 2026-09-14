# QuotaBar

CodexとClaude Codeの残り利用枠を、macOSのメニューバーに電池型ゲージと％で表示するアプリです。SwiftUI + AppKit製。外部ライブラリ・APIキーの入力は不要です。

## 起動

GitHubにはソースコードを掲載しています。最初に次のコマンドでアプリをビルドできます。

```bash
git clone https://github.com/adachic/QuotaBar.git
cd QuotaBar
bash scripts/build.sh
open dist/QuotaBar.app
```

1. ビルド済みの **QuotaBar.app** を開いてください。常用する場合は「アプリケーション」フォルダに移動してください。
2. メニューバーに **`</>` と `✳` の電池型ゲージ** が表示されます。左側がCodex、右側がClaude Codeです。macOS側で並び順を変更している場合は、その位置を引き継ぎます。
3. どちらかをクリックすると詳細を表示します。歯車で設定、電源ボタンで終了できます。Dockには表示しません。
4. Claude Codeに接続できない場合は「Claude Codeに接続」をクリックしてください。macOSがキーチェーンの許可を求めた場合は、ご自身で許可してください。

初期設定は「少ない方」を表示し、3分間隔で更新します。ログイン時の自動起動は設定からオンにできます。

詳細パネルは両サービスを一画面に収めるコンパクトな配置で、スクロールは不要です。内容の実際の高さを測ってパネルをリサイズし、小さい画面では全体を縮小して見切れを防ぎます。外部ディスプレイの接続変更にも追従します。

## 表示

| 項目 | 動作 |
| --- | --- |
| 5時間 | 短時間枠を表示。提供されないアカウントでは「—」 |
| 週間 | 週間枠を表示。提供されないアカウントでは「—」 |
| 少ない方 | 取得できた短時間枠・週間枠のうち残りが少ない枠を表示。初期設定 |
| ％ | `100 − 使用率` を0〜100に収め、小数点以下を切り捨て |
| 色 | 詳細パネルはCodexが緑、Claudeがテラコッタ。20％以下はオレンジ、10％以下は赤 |
| メニューバー | macOSのバッテリー表示に合わせたモノクロ。ライト／ダークで自動切り替え |
| リセット | あと何時間・何日かを表示。各行にカーソルを合わせると日時を表示 |
| 前回の値 | 取得失敗時は最後に取得した残量を保持し、古い値であることを明示。メニューバーには `·` を付加 |
| リセット確認待ち | リセット時刻を過ぎた値はゲージに使わず、再取得を待機。100％と推測しない |

表示と「少ない方」の比較対象は、全モデル共通の短時間・週間枠です。モデル専用枠、追加課金やクレジットの残高とは別の指標です。

## 接続方法

### Codex

インストール済みのCodex CLIに接続し、公式App Serverの `initialize` → `initialized` → `account/rateLimits/read` を使用します。`rateLimitsByLimitId.codex` を優先し、互換用の `rateLimits` にも対応します。ウィンドウの長さはサーバーから返された分数を使います。週間枠だけのアカウントにも対応しています。

- Codex CLIでChatGPTアカウントにログインしておいてください。APIキーだけの利用ではサブスクリプション枠を取得できません。
- `~/.local/bin/codex`、Homebrew、Codex／ChatGPTアプリに内蔵されたCLIを自動検出します。独自の場所は設定から選択できます。
- 読み取りごとに短時間だけCLIを起動し、終了します。CLIは自身の `~/.codex` 状態DBやログを更新することがあります。
- 会話作成・モデル呼び出し・リセットクレジット消費は行いません。

参照: [OpenAI公式 App Serverドキュメント](https://learn.chatgpt.com/docs/app-server)

### Claude Code

ログイン済みClaude CodeのmacOSキーチェーン項目を読み、`https://api.anthropic.com/api/oauth/usage` に利用状況のGETリクエストを送ります。キーチェーン項目が存在しない場合のみ、Claude Code自身の `.credentials.json` を読みます。

- Claude Codeで `/login` を完了しておいてください。APIキーだけの利用には対応していません。
- この利用状況エンドポイントは一般向け公開APIとして保証されていません。サービス側の仕様や権限の変更で取得できなくなる可能性があります。
- 期限切れや権限不足が表示された場合は、Claude Code側でログインを更新して再接続してください。QuotaBar自身は認証情報の更新・書き換えを行いません。
- トークンはメモリ上でのみ扱い、固定のAnthropic HTTPS宛先にだけ送信します。リダイレクト追従を無効化し、ログ・設定・キャッシュにトークンを保存しません。
- 自動更新では認証ダイアログを表示しません。必要な場合はユーザーが接続ボタンから許可します。
- HTTP 429では `Retry-After` を尊重して再試行を待ちます。

Claude Codeには公式の[ステータスライン用利用率データ](https://code.claude.com/docs/en/statusline#rate-limit-usage)もあります。このアプリはClaude Codeを操作していない間の更新にも対応するため、利用状況エンドポイントを使用しています。

## 開発

- macOS 14以降、Swift 5.10以降／Xcode Command Line Tools
- 今回のビルド: Apple Silicon（arm64）
- 同梱アプリはローカル利用向けのアドホック署名です。Developer ID署名・Apple公証は含みません。
- ローカルのキーチェーンとCLIを利用するため、App Sandboxは有効にしていません。

```bash
swift test
bash scripts/build.sh
open dist/QuotaBar.app
```

ビルド先と中間ファイル先は変更できます。

```bash
QUOTABAR_BUILD_DIR=/tmp/quotabar-build bash scripts/build.sh /tmp/quotabar-output
```

取得確認用のコマンドは、トークンやアカウント識別子を出力しません。残量と日時だけを出力します。

```bash
dist/QuotaBar.app/Contents/MacOS/QuotaBar --check
dist/QuotaBar.app/Contents/MacOS/QuotaBar --check --codex-only
dist/QuotaBar.app/Contents/MacOS/QuotaBar --check --claude-only
```

CLIからキーチェーンの対話を許可する場合のみ `--allow-keychain` を追加します。通常はアプリの接続ボタンを使用してください。

```bash
open dist/QuotaBar.app --args --demo
```

`--demo` はサンプルデータを使用し、パネルに「デモ」と明記します。ネットワーク接続や設定保存は行いません。実データとは混在させません。

## ファイル構成

- `Sources/QuotaCore`: 残量モデル、レスポンス解析、Codex stdio通信、Claude接続
- `Sources/QuotaBar`: メニューバー、SwiftUIパネル、更新と設定
- `Tests/QuotaCoreTests`: 残量計算、欠損・期限切れ、週間枠のみのアカウント、認証データ、429、通信処理
- `scripts/build.sh`: `.app` の作成とアドホック署名
- `Resources`: アプリアイコン、Info.plist

## アンインストール

設定で「ログイン時に起動」をオフにし、電源ボタンで終了してからアプリを削除してください。設定は `dev.local.QuotaBar` のmacOSユーザー設定領域に保存されます。Codex・Claude Codeの設定や認証情報は削除しません。
