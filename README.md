# Prunlet

Windowsのファイル削除をCLI・MCP・Codexフックから利用するツールです。指定した範囲のファイルを検証済みバックアップへ保存してから削除し、操作IDを使って復元できます。提供元はKagayoiです。

初版はファイルのみを扱います。フォルダー・再帰削除・ワイルドカード・リンク・ネットワークパスは扱いません。通常の削除であり、ディスク上のデータを復元不能にする消去機能はありません。

代替データストリーム（ADS）を持つファイルも、本体だけのバックアップで情報を失わないため削除を拒否します。ブラウザから取得したファイルの`Zone.Identifier`も該当します。読み取り専用ファイルの属性を勝手に解除することはありません。

大文字小文字を区別するディレクトリを含むパスは扱いません。ディレクトリのcase-sensitive属性を取得できないOS・ファイルシステムでも、範囲の誤判定を防ぐため処理を停止します。

## インストールと更新

Windows、.NET 10 SDK、PowerShell 7が必要です。インストール元は[GitHubリポジトリ](https://github.com/1llum1n4t1s/Prunlet)の既定ブランチの最新HEADです。開発用クローンは使用しません。

Windows ARM64では、下の実行コマンドに`-Runtime win-arm64`を追加してください。既定は`win-x64`で、ARM64での未指定は停止します。x64エミュレーションを選ぶ場合も`-Runtime win-x64`の明示指定が必要です。

```powershell
$installerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Codex\Prunlet\bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $installerDirectory | Out-Null
$installer = Join-Path $installerDirectory 'Install-Prunlet.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.ps1' -OutFile $installer
pwsh -NoProfile -File $installer -AllowedRoot 'C:\work\project' -RegisterCodex -RegisterAgentInstructions
```

インストーラーはGitHub APIから既定ブランチと最新コミットを取得し、そのコミットのアーカイブを取得してビルドします。導入処理中は取得したSHAでソースを揃えますが、次回の導入・更新は再び最新HEADを解決します。取得失敗やリモートの実装不足では停止し、ローカルクローンへ切り替えません。

既定の配置先は`%USERPROFILE%\.local\Prunlet`です。`bin\prunlet.exe`と連携スクリプト・共通指示を配置し、`source-info.json`に取得元・ブランチ・コミットを記録します。`-RegisterCodex`を指定すると共通MCPとフックも登録します。起動時にダウンロードやビルドは行いません。

上の`-RegisterAgentInstructions`は、Codex homeの`PRUNLET.md`と、共通`AGENTS.md`の専用参照を登録する明示オプションです。各リポジトリへ追記せず、最初からPrunlet MCPで削除するようCodexへ指示します。共通指示を変更したくない場合はこのオプションを外してください。コマンドの機械的な強制とは別の仕組みです。

共通指示を登録した導入の更新でも、同じ`-RegisterAgentInstructions`を指定してください。指定しない更新では共通指示に書き込みません。古い共通指示と新しい配置済みguideが異なる場合は、利用者の編集との区別を付けられないため自動更新・解除を拒否します。

更新時は最新版のインストーラーを再取得して実行します。既存の`config.json`と復元データを保持します。初回は`-AllowedRoot`で削除を許可する既存ディレクトリを指定し、複数指定するときはPowerShellの配列を渡してください。配置先は`-InstallDirectory`で変更できます。利用者のクローンパスをCodex設定へ登録することはありません。

取得したbootstrapファイルは一時物です。導入結果を確認して、そのbootstrap専用ディレクトリだけを清掃してください。アプリの配置先と復元用データは清掃対象に含めません。

更新前の製品や登録前のCodex設定のバックアップがある場合、導入結果の`updateBackupDirectory`に保存先が表示されます。既定は`%LOCALAPPDATA%\Codex\TaskArtifacts\Prunlet\install-<ID>`です。動作とCodex登録を確認し、復旧が不要になってから、その導入分のバックアップだけを清掃してください。連携スクリプトの設定バックアップは[連携手順](docs/integration.md)を参照してください。

## 初期設定

許可する削除範囲と、復元データの保存先を明示します。両方のディレクトリは事前に作成してください。バックアップ保存先は許可範囲と互いに包含しない場所に置きます。

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --allowed-root 'C:\work\project' --backup-directory $backup
```

インストーラーを利用した場合は初期化済みです。手動の`init`も既存設定を上書きしません。許可範囲を追加するときは`--allowed-root`を繰り返します。MCPの引数から範囲を拡張することはできません。

```json
{
  "schema": 1,
  "allowedRoots": ["C:\\work\\project"],
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery"
}
```

## 削除・復元

```powershell
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
& $exe --config $config delete --dry-run -- 'C:\work\project\unused.txt'
& $exe --config $config delete -- 'C:\work\project\unused.txt' 'C:\work\project\other.txt'
& $exe --config $config operations
& $exe --config $config restore '<削除結果に含まれるoperationId>'
```

出力はJSONです。削除結果の`operationId`と各ファイルの`status`を確認してください。欠損ファイルは`already_absent`として返します。復元先にファイルが存在するときは上書きせず、バックアップを保持します。失敗時は終了コードが0以外になります。

バックアップは自動で消しません。復元が不要になった操作の保存フォルダーだけを、内容を確認してから清掃してください。復元はファイル本体と最終書込日時が対象で、ACL・所有者・拡張属性を再現する機能ではありません。

## MCP

`prunlet --config <絶対パス> mcp`でローカルstdioサーバーを起動します。標準出力はJSON-RPC専用です。MCPプロトコルの2025-11-25・2025-06-18・2024-11-05に対応します。

| ツール | 引数 | 用途 |
| --- | --- | --- |
| `delete_files` | `paths`、任意の`dryRun` | バックアップ付き削除 |
| `restore_files` | `operationId` | 上書きしない復元 |
| `list_operations` | なし | 保存された操作IDの一覧（復元可否は復元時に検証） |

サーバーは削除ツールの用途を`instructions`で通知します。各リポジトリへの記載は不要ですが、ツールを最初から選ぶかどうかは利用するエージェントの判断に依存します。

## Codexとの連携

共通MCP登録、削除コマンドの入力置換、解除手順は[連携手順](docs/integration.md)を参照してください。フックは認識できる単独の削除コマンドだけを専用CLIへ置換し、フック自身は削除を実行しません。Codex側の承認や管理ポリシーを無効化する機能はありません。

## 保存先の実体検証で停止する場合

MSIX版のアプリから配置すると、AppDataの新しいフォルダーがパッケージ専用のLocalCacheへ転送される場合があります。Prunletは指定パスと開いたハンドルの実体が異なると停止します。検証を無効化せず、exe・設定・復元データを`%USERPROFILE%\.local\Prunlet`など、転送されない専用ディレクトリへ配置してください。CodexパッケージのLocalCacheを復元データの恒久保存先にすることは推奨しません。

## 開発資料

開発時のビルドと作業規約は[AGENTS.md](AGENTS.md)、構造と設計判断は[DESIGN.md](DESIGN.md)、E2Eの実行方法と検証範囲は[検証手順](docs/verification.md)を参照してください。
