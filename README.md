# Prunlet

Windowsのファイル削除をCLI・MCPから利用するツールです。指定したファイルを検証済みバックアップへ保存してから削除し、操作IDを使って復元できます。Codexフックは直接削除を検査・拒否してCLI手順を案内します。提供元はKagayoiです。

初版はファイルのみを扱います。フォルダー・再帰削除・ワイルドカード・リンク・ネットワークパスは扱いません。通常の削除であり、ディスク上のデータを復元不能にする消去機能はありません。

代替データストリーム（ADS）を持つファイルも、本体だけのバックアップで情報を失わないため削除を拒否します。ブラウザから取得したファイルの`Zone.Identifier`も該当します。読み取り専用ファイルの属性を勝手に解除することはありません。

大文字小文字を区別するディレクトリを含むパスは扱いません。ディレクトリのcase-sensitive属性を取得できないOS・ファイルシステムでも、パス実体の誤照合を防ぐため処理を停止します。

## インストールと更新

Windows、.NET 10 SDK、PowerShell 7が必要です。インストール元は[GitHubリポジトリ](https://github.com/1llum1n4t1s/Prunlet)の既定ブランチの最新HEADです。開発用クローンは使用しません。

Windows ARM64では、下の実行コマンドに`-Runtime win-arm64`を追加してください。既定は`win-x64`で、ARM64での未指定は停止します。x64エミュレーションを選ぶ場合も`-Runtime win-x64`の明示指定が必要です。

```powershell
$installerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Codex\Prunlet\bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $installerDirectory | Out-Null
$installer = Join-Path $installerDirectory 'Install-Prunlet.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.ps1' -OutFile $installer
pwsh -NoProfile -File $installer -RegisterCodex -RegisterAgentInstructions
```

インストーラーはGitHub APIから既定ブランチと最新コミットを取得し、そのコミットのアーカイブを取得してビルドします。導入処理中は取得したSHAでソースを揃えますが、次回の導入・更新は再び最新HEADを解決します。取得失敗やリモートの実装不足では停止し、ローカルクローンへ切り替えません。

既定の配置先は`%USERPROFILE%\.local\Prunlet`です。`bin\prunlet.exe`と登録用スクリプト・共通指示を配置し、`source-info.json`に取得元・ブランチ・コミットを記録します。`-RegisterCodex`を指定すると共通MCPとネイティブexeのフックも登録します。起動時にダウンロードやビルドは行いません。

`-RegisterCodex`を指定した導入・更新後は、Codexで`/hooks`を開いてPrunletフックの定義を確認し、信頼してください。インストーラーは信頼設定を変更せず、結果の`requiresHookTrust`でこの操作が必要なことを通知します。Codexを再起動し、MCP・共通指示・フックの読込みを確認してください。登録と解除の詳細は[連携手順](docs/integration.md#登録)を参照してください。

上の`-RegisterAgentInstructions`は、Codex homeの`PRUNLET.md`と、共通`AGENTS.md`の専用参照・配置済みexeと設定の絶対パスを登録する明示オプションです。各リポジトリへ追記せず、最初からCMD上のPrunlet CLIで削除するようCodexへ指示します。exe・設定のパス自体をCMDで安全に表現できない場合は、実行前に同じCoreを使うMCPを選びます。共通指示を変更したくない場合はこのオプションを外してください。

共通指示を登録した導入の更新でも、同じ`-RegisterAgentInstructions`を指定してください。指定しない更新では共通指示に書き込みません。古い共通指示と新しい配置済みguideが異なる場合は、利用者の編集との区別を付けられないため自動更新・解除を拒否します。

更新時は最新版のインストーラーを再取得して実行します。既存の`config.json`と復元データを保持します。削除対象フォルダーの事前登録は不要です。旧`-AllowedRoot`は互換引数として受理しますが、削除範囲を制限しません。配置先は`-InstallDirectory`で変更できます。利用者のクローンパスをCodex設定へ登録することはありません。

取得したbootstrapファイルは一時物です。導入結果を確認して、そのbootstrap専用ディレクトリだけを清掃してください。アプリの配置先と復元用データは清掃対象に含めません。

更新前の製品や登録前のCodex設定のバックアップがある場合、導入結果の`updateBackupDirectory`に保存先が表示されます。既定は`%LOCALAPPDATA%\Codex\TaskArtifacts\Prunlet\install-<ID>`です。動作とCodex登録を確認し、復旧が不要になってから、その導入分のバックアップだけを清掃してください。連携スクリプトの設定バックアップは[連携手順](docs/integration.md)を参照してください。

MSIX環境でAppDataが別の実体へ転送される場合は、`-UpdateBackupRoot <実体の絶対パス>`で更新バックアップの親を明示できます。その下へ導入ごとの`install-<ID>`を作ります。導入ごとの保存先がリポジトリ、Codex home、配置先、作業場所、復元データと重なる場合は拒否します。旧PowerShellバックエンドの退役ではPrunlet Coreを使い、`retirement-config.json`と削除結果も同じ更新バックアップへ保持します。

## 初期設定

復元データの保存先を指定し、そのディレクトリを事前に作成します。削除対象はローカルドライブ内の通常ファイルで、対象フォルダーの許可リストはありません。復元データの保存先内は通常削除から保護し、コピーの整理にはCLIの明示`purge`を使います。

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
```

インストーラーを利用した場合は初期化済みです。手動の`init`も既存設定を上書きしません。旧`--allowed-root`と設定の`allowedRoots`はschema 1との互換用に受理しますが、削除範囲の判定には使いません。`allowedRoots`を省略・空配列・nullにした設定や、記録された旧ルートが存在しなくなった設定も使用できます。

```json
{
  "schema": 1,
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery"
}
```

## 削除・復元

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --dry-run --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json operations
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json restore 0123456789abcdef0123456789abcdef
```

例のexe・設定は実際の配置済み絶対パスへ、復元のIDは削除結果の`operationId`へ置き換えてください。Codexのshell toolは`cmd.exe`、`login: false`を指定します。空白・Unicode・多数・長い対象パスはコマンドへ展開せず、絶対パスのUTF-8 JSONファイルへ入れます。`--paths-file`は1〜256件の文字列配列、最大1 MiBを受け付け、ファイルを読み取って通常のパス検証を適用します。

```json
["C:\\work\\project\\unused.txt", "C:\\work\\project\\other.txt"]
```

単純なパスは`delete [--dry-run] -- <絶対パス> [...]`でも指定できます。長い対象パスも通常のローカル絶対パスを入力します。`\\?\`は内部Win32呼出しだけで使用し、入力に付けません。元の削除がホストに拒否された場合、別shellやPrunletへ付け替えて再試行しません。

出力はJSONです。削除結果の`operationId`と各ファイルの`status`を確認してください。欠損ファイルは`already_absent`として返します。復元先にファイルが存在するときは上書きせず、バックアップを保持します。失敗時は終了コードが0以外になります。

バックアップは自動で消しません。復元はファイル本体と最終書込日時が対象で、ACL・所有者・拡張属性を再現する機能ではありません。復元が不要になった操作は、`purge <operationId>`で検査し、内容を確認して`purge <operationId> --apply`を実行します。既定と`--dry-run`は検査のみです。適用すると検証済みの`.bak`だけを削除し、操作の記録・ロックを保持します。その操作は復元できなくなります。中断後は同じ操作IDで再開できます。保存フォルダーの手動削除、保存期間による自動削除、バックアップを省略するモードはありません。

## MCP

`prunlet --config <絶対パス> mcp`でローカルstdioサーバーを起動します。標準出力はJSON-RPC専用です。MCPプロトコルの2025-11-25・2025-06-18・2024-11-05に対応します。

| ツール | 引数 | 用途 |
| --- | --- | --- |
| `delete_files` | `paths`、任意の`dryRun` | バックアップ付き削除 |
| `restore_files` | `operationId` | 上書きしない復元 |
| `list_operations` | なし | 保存された操作IDの一覧（復元可否は復元時に検証） |

サーバーは削除ツールの用途を`instructions`で通知します。通常入口はCLIで、MCPは配置済みexe・設定をCMDで安全に表現できない場合などの代替入口です。purgeは明示CLI操作です。

## Codexとの連携

共通MCP登録、削除入力の検査、解除手順は[連携手順](docs/integration.md)を参照してください。ネイティブexeのフックは認識した直接削除を拒否してCLI手順を案内し、削除や入力の自動置換は行いません。Codex側の承認や管理ポリシーを維持します。PowerShellは導入・ビルド・E2Eの管理スクリプトで使い、通常の削除backendには使いません。

## 保存先の実体検証で停止する場合

MSIX版のアプリから配置すると、AppDataの新しいフォルダーがパッケージ専用のLocalCacheへ転送される場合があります。Prunletは指定パスと開いたハンドルの実体が異なると停止します。検証を無効化せず、exe・設定・復元データを`%USERPROFILE%\.local\Prunlet`など、転送されない専用ディレクトリへ配置してください。CodexパッケージのLocalCacheを復元データの恒久保存先にすることは推奨しません。

## 開発資料

開発時のビルドと作業規約は[AGENTS.md](AGENTS.md)、構造と設計判断は[DESIGN.md](DESIGN.md)、E2Eの実行方法と検証範囲は[検証手順](docs/verification.md)を参照してください。
