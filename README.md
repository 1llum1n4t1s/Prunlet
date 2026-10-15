# Prunlet — Anti “blocked by policy”

Windowsのファイル・フォルダー削除をCLI・MCPから利用するツールです。指定した対象の復元データを検証・保存してから削除し、操作IDを使って復元できます。Codexフックは直接削除を検査・拒否してCLI手順を案内します。提供元はKagayoiです。

ファイルと空フォルダーを扱い、`--recursive`を明示するとフォルダー全体を削除できます。シンボリックリンク・ジャンクションはリンク自体を削除し、リンク先を辿りません。ワイルドカード・ネットワークパス・未知のreparseタグ・リンク自体がADSを持つ場合は扱いません。通常の削除であり、ディスク上のデータを復元不能にする消去機能はありません。

ファイル・フォルダーの代替データストリーム（ADS）も内容を検証して保存・復元します。ブラウザから取得したファイルの`Zone.Identifier`も含み、末尾に空白・ピリオドがあるストリーム名も区別して保持します。ハードリンクは指定した名前だけを削除し、他の名前から参照される内容を変えません。復元は保存時点の独立コピーとなり、元のハードリンクとの共有関係は再作成しません。シンボリックリンクの復元には、Windowsが許可する管理者権限またはDeveloper Modeが必要です。PrunletがOSの設定や権限を変更することはありません。読み取り専用ファイルの属性を勝手に解除することはありません。

通常のローカル絶対パスに加え、`C:/...`表記、`\\?\C:\...`形式、8.3短縮名、CodexのMSIXによるAppData転送を扱います。通常ファイル・フォルダーの実体と祖先を確認して実体パスへ揃えるため、保存場所の転送や表記の違いだけを理由に追加の許可を求めません。結果の`path`と新しい復元記録には実体パスを保存します。

大文字小文字を区別するディレクトリは、属性と正確な名前を保存・復元します。属性を取得・設定できないOS・ファイルシステムでは、情報を失わないため処理を停止します。

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

復元データの保存先を指定し、そのディレクトリを事前に作成します。削除対象はローカルドライブ内の通常ファイル・フォルダーで、対象フォルダーの許可リストはありません。復元データの保存先内は通常削除から保護します。コピーは既定で7日間・合計10 GiBまで保持し、期限切れや容量超過時に自動整理します。

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
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery",
  "retentionDays": 7,
  "maxRecoveryBytes": 10737418240
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

空フォルダーは通常の`delete`で削除できます。内容があるフォルダーは`delete --recursive --paths-file <絶対JSONパス>`を明示し、全内容のバックアップとフォルダー記録を保存してから、子から親の順に削除します。未知のreparseタグや使用中ファイルが混在すると、そのツリーの削除を開始しません。列挙後に追加されたファイルは削除せず残します。空の子フォルダーも同じ`operationId`で復元できます。復元時にすでにある通常フォルダーはそのまま使い、既存ファイルは上書きせず`conflict`として返します。再帰操作は32,768件・復元記録8 MiBを超えるフォルダーにも対応します。必要なメモリ・ハンドル・バックアップ容量は対象数に応じて増えます。大きな記録の復元・整理にも対応版を使用してください。

単純なパスは`delete [--dry-run] [--recursive] -- <絶対パス> [...]`でも指定できます。長い対象パスも通常のローカル絶対パスで指定でき、`\\?\C:\...`形式も受け付けます。元の削除がホストに拒否された場合、別shellやPrunletへ付け替えて再試行しません。

出力はJSONです。削除結果の`operationId`と各ファイルの`status`を確認してください。欠損ファイルは`already_absent`として返します。復元先にファイルが存在するときは上書きせず、バックアップを保持します。失敗時は終了コードが0以外になります。

復元時は最終書込日時も戻しますが、ACL・所有者・拡張属性は再現しません。復元できるのはコピーが保持されている期間だけです。保持方針は次節を参照してください。

## 復元コピーの保持と自動整理

既定の保存期間は操作の作成から7日、復元コピー全体の容量上限は10 GiBです。新しい削除の前に期限切れのコピーを整理し、必要な容量が不足するときは7日以内でも古い操作から整理します。1操作内のコピーはまとめて整理するため、上限より少ない容量になる場合があります。旧設定で項目が省略されている場合も、この既定値が適用されます。

`retentionDays`は1〜36,500日の整数、`maxRecoveryBytes`は正の整数（バイト数）で期間と上限を変更できます。1回の削除に必要なコピーだけで上限を超える場合は、元のファイルを消さずに停止します。破損したコピーや使用中の操作は自動で消さず、容量を安全に確保できなければ新しい削除も停止して理由を返します。

インストーラーは、現在のWindowsユーザーで毎日03:00とログオン時に`maintain --apply`を実行するタスクを登録します。ログインしていない間は実行されず、ログオン後に整理します。管理者権限やパスワードは使用しません。更新時は同じ実行先の既存タスクを再登録せず、利用者による時刻変更や無効化を保持します。CLIとMCPの実削除も同じ保持方針を適用します。dry-run、復元、操作一覧、hook入力の検査では自動整理しません。

定期整理タスクはCodex連携を解除しても残ります。タスクだけを解除する手順は[連携手順の「解除と復元」](docs/integration.md#解除と復元)を参照してください。解除後も実削除時の自動整理は行われます。

```text
prunlet --config <絶対パス> maintain
prunlet --config <絶対パス> maintain --apply
```

`maintain`と`--dry-run`は検査のみです。`--apply`で期限と容量に従って整理します。既存の復元コピーにも適用されます。整理ではサイズ・ハッシュを検証したコピーだけを削除し、操作の記録・ロックを残します。整理後はその操作を復元できません。

更新後は、同じ復元領域を使う旧Prunlet CLI・MCPを終了し、新版で起動してください。旧プロセスが書き込んでいる間は容量上限を厳密には保証できません。

特定の操作を期限前に整理するには、`purge <operationId>`で検査し、`purge <operationId> --apply`で適用します。失敗項目に紐づく途中コピーも検証して整理し、中断後は同じ操作IDで再開できます。保存フォルダーの手動削除や、バックアップを省略するモードはありません。

## MCP

`prunlet --config <絶対パス> mcp`でローカルstdioサーバーを起動します。標準出力はJSON-RPC専用です。MCPプロトコルの2025-11-25・2025-06-18・2024-11-05に対応します。

| ツール | 引数 | 用途 |
| --- | --- | --- |
| `delete_files` | `paths`、任意の`dryRun`・`recursive` | ファイル・空フォルダー、明示再帰で内容も削除 |
| `restore_files` | `operationId` | 上書きしない復元 |
| `list_operations` | なし | 保存された操作IDの一覧（復元可否は復元時に検証） |

サーバーは削除ツールの用途を`instructions`で通知します。通常入口はCLIで、MCPは配置済みexe・設定をCMDで安全に表現できない場合などの代替入口です。purgeは明示CLI操作です。

## Codexとの連携

共通MCP登録、削除入力の検査、解除手順は[連携手順](docs/integration.md)を参照してください。ネイティブexeのフックは認識した直接削除を拒否してCLI手順を案内し、削除や入力の自動置換は行いません。Codex側の承認や管理ポリシーを維持します。PowerShellは導入・ビルド・E2Eの管理スクリプトで使い、通常の削除backendには使いません。

## 保存先の実体検証で停止する場合

MSIX版のアプリでは、AppDataの新しいフォルダーがパッケージ専用のLocalCacheへ転送される場合があります。通常ディレクトリの転送は実体へ解決して扱いますが、祖先のリンクや実体・属性を検証できない場合は停止します。エラーに示されたパスと属性を確認し、検証を無効化せず、必要ならexe・設定・復元データを`%USERPROFILE%\.local\Prunlet`などの専用ディレクトリへ配置してください。CodexパッケージのLocalCacheを復元データの恒久保存先にすることは推奨しません。

## 開発資料

開発時のビルドと作業規約は[AGENTS.md](AGENTS.md)、構造と設計判断は[DESIGN.md](DESIGN.md)、E2Eの実行方法と検証範囲は[検証手順](docs/verification.md)を参照してください。
