# Prunlet — Anti “blocked by policy”

Prunletは、`blocked by policy`による清掃の停止を減らすために、AIエージェントのファイル・フォルダー削除を専用CLI・MCPへ集約するWindows用ツールです。許可された削除を最初からPrunletへ任せる使い方に揃えます。

指定した対象を、同じボリュームのPrunlet専用領域へrenameして退避し、操作IDを使って元へ戻せます。新規削除ではファイル内容をコピーしません。Codexフックは直接削除を検査・拒否してCLI手順を案内します。提供元はKagayoiです。

並行操作でロックを待つ間は、経過時間とロック取得を通知します。CLI・MCPでの確認方法は[使用中のファイルと同時実行](docs/integration.md#使用中のファイルと同時実行)を参照してください。

ファイルと空フォルダーを扱い、`--recursive`を明示するとフォルダー全体を削除できます。シンボリックリンク・ジャンクションはリンク自体を削除し、リンク先を辿りません。ワイルドカード・ネットワークパス・未知のreparseタグ・リンク自体がADSを持つ場合は扱いません。通常の削除であり、ディスク上のデータを復元不能にする消去機能はありません。

ファイル・フォルダーは同じオブジェクトのまま移動するため、ADS（`Zone.Identifier`を含む）、ACL、読み取り専用などの通常属性、圧縮状態、ハードリンク関係を保持します。ハードリンクの外部別名から書き込むと保管中の内容にも反映されるため、保存時点の不変コピーではありません。シンボリックリンクとジャンクションもリンク自体を移動します。Windowsが移動を拒否した場合は属性や権限を書き換えず、元対象を残して失敗を返します。

通常のローカル絶対パスに加え、`C:/...`表記、`\\?\C:\...`形式、8.3短縮名、CodexのMSIXによるAppData転送を扱います。通常ファイル・フォルダーの実体と祖先を確認して実体パスへ揃えるため、保存場所の転送や表記の違いだけを理由に追加の許可を求めません。結果の`path`と新しい復元記録には実体パスを保存します。

大文字小文字を区別するディレクトリも属性と正確な名前を同じオブジェクトのまま保持します。旧コピー形式の復元では属性の再設定が必要になる場合があります。[保存形式と互換性](DESIGN.md#旧コピー形式の互換性)を参照してください。

## `blocked by policy`対策としての使い方

AIが生成した`Remove-Item`や`rm`などの削除コマンドで清掃が止まりやすい環境では、許可されたファイル・フォルダーの削除を、最初からPrunlet CLIへ任せるようにします。対象の検証、専用領域への退避、操作IDによる復元を専用ツールへ集約できます。

Codexでは、次の順序で利用します。

1. 下の[インストールと更新](#インストールと更新)のコマンドを、`-RegisterCodex -RegisterAgentInstructions`付きで実行します。CLI・MCP・フックと、Prunlet CLIを最初から使う共通指示を登録します。
2. Codexで`/hooks`を開いてPrunletフックを信頼し、Codexを再起動して登録内容を読み込みます。
3. 通常どおり作業や清掃を依頼します。共通指示は、配置済みCLIと設定の絶対パスを使い、CMD（`shell: cmd.exe`、`login: false`）からPrunletを直接呼び出すようCodexへ指示します。各リポジトリへ同じ指示を追加する必要はありません。

清掃を明示して依頼する場合は、たとえば次のように伝えます。

> 今回作成した不要な一時ファイルと作業フォルダーを、最初からPrunlet CLIで清掃してください。

空白・Unicode・長いパス・複数対象はUTF-8のJSON一覧を`--paths-file`で渡し、非空フォルダーには`--recursive`を明示します。実際のコマンドと復元方法は、後述の「削除・復元」を参照してください。

フックは直接削除を検出・拒否してCLI手順を案内する補助で、自動変換は行いません。失敗と再試行を繰り返さずに済むよう、共通指示による初回からのCLI利用を基本にします。ホストやOSの権限・承認・管理ポリシーは引き続き適用されます。Prunletの呼出し自体が拒否された場合は停止し、別経路で再試行しません。登録と検査範囲の詳細は[連携手順](docs/integration.md)を参照してください。

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

共通指示を登録した導入の更新でも、同じ`-RegisterAgentInstructions`を指定してください。指定しない更新では共通指示に書き込みません。その間に配置済みguideだけが更新されると、古い共通指示を利用者の編集と区別できず、後の自動更新・解除が停止することがあります。詳細は[エージェント共通指示](docs/integration.md#エージェント共通指示)を参照してください。

更新時は最新版のインストーラーを再取得して実行します。既存の`config.json`と復元データを保持します。削除対象フォルダーの事前登録は不要です。旧`-AllowedRoot`は互換引数として受理しますが、削除範囲を制限しません。配置先は`-InstallDirectory`で変更できます。利用者のクローンパスをCodex設定へ登録することはありません。

取得したbootstrapファイルは一時物です。導入結果を確認して、そのbootstrap専用ディレクトリだけを清掃してください。アプリの配置先と復元用データは清掃対象に含めません。

更新前の製品や登録前のCodex設定のバックアップがある場合、導入結果の`updateBackupDirectory`に保存先が表示されます。既定は`%LOCALAPPDATA%\Codex\TaskArtifacts\Prunlet\install-<ID>`です。動作とCodex登録を確認し、復旧が不要になってから、その導入分のバックアップだけを清掃してください。連携スクリプトの設定バックアップは[連携手順](docs/integration.md)を参照してください。

MSIX環境でAppDataが別の実体へ転送される場合は、`-UpdateBackupRoot <実体の絶対パス>`で更新バックアップの親を明示できます。その下へ導入ごとの`install-<ID>`を作ります。導入ごとの保存先がリポジトリ、Codex home、配置先、作業場所、復元データと重なる場合は拒否します。旧PowerShellバックエンドの退役ではPrunlet Coreを使い、`retirement-config.json`と削除結果も同じ更新バックアップへ保持します。

## 初期設定

復元データの保存先を指定し、そのディレクトリを事前に作成します。削除対象はローカルドライブ内の通常ファイル・フォルダーで、対象フォルダーの許可リストはありません。復元データの保存先内は通常削除から保護します。復元データは既定で7日間・合計10 GiBまで保持し、期限切れや容量超過時に自動整理します。

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
```

新方式の`backupDirectory`は中央の操作記録と旧コピーの保存先です。退避実体は既定で各ボリュームの`<volumeRoot>\.Prunlet-Recovery-<SID>\<storeKey>\<operationId>\0000.entry`に置きます。任意の`volumeRecoveryDirectories`でボリューム別専用baseを指定できますが、必ず対象と同じボリュームに置きます。異なるボリュームへのコピーfallbackはありません。配置と保護の詳細は[設計](DESIGN.md#ボリューム別の復元領域)を参照してください。

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

空フォルダーは通常の`delete`、内容があるフォルダーは`delete --recursive --paths-file <絶対JSONパス>`で削除します。削除前にツリー全体を検査・容量走査し、フォルダーごと同じボリュームの専用領域へ移動します。データ内容のコピーはありませんが、大量の項目の走査には時間とハンドルが必要です。復元は退避実体を元へ戻す消費型で、既存のファイル・フォルダーには上書きもマージもせず`conflict`を返します。整合する復元済み操作の再実行は`already_restored`です。

単純なパスは`delete [--dry-run] [--recursive] -- <絶対パス> [...]`でも指定できます。長い対象パスも通常のローカル絶対パスで指定でき、`\\?\C:\...`形式も受け付けます。元の削除がホストに拒否された場合、別shellやPrunletへ付け替えて再試行しません。

出力はJSONです。削除結果の`operationId`と各ファイルの`status`を確認してください。欠損ファイルは`already_absent`として返します。復元先に項目が存在するときは上書きせず、退避実体を保持します。失敗時は終了コードが0以外になります。

既存schema 1/2/3のコピー形式も復元・整理できます。旧形式はACL等の再現や復元後のコピー保持など新方式と挙動が異なります。[互換経路の設計](DESIGN.md#旧コピー形式の互換性)を参照し、旧版でschema 4を操作しないでください。復元できるのは退避実体または旧コピーが保持されている間だけです。

## 復元データの保持と自動整理

既定の保存期間は操作の作成から7日、新しい退避実体と旧コピーの合計の容量上限は10 GiBです。新しい削除の前に期限切れの復元データを整理し、必要な容量が不足するときは7日以内でも古い操作から整理します。1操作内の復元データはまとめて整理するため、上限より少ない容量になる場合があります。旧設定で項目が省略されている場合も、この既定値が適用されます。

`retentionDays`は1〜36,500日の整数、`maxRecoveryBytes`は正の整数（バイト数）です。削除前に元対象と既存の復元データを走査し、整理前後に容量を検証します。1回の入力合計だけで上限を超える場合は、既存データを0バイトまで安全に整理してから、今回のサイズを有効予算として退避します。この例外は設定を変更せず、次の削除やmaintainでは通常上限を再適用します。不正・破損・使用中などで容量を安全に確保できなければ元対象を残して停止します。[容量制御の詳細](DESIGN.md#復元データの自動整理)を参照してください。

インストーラーは、現在のWindowsユーザーで毎日03:00とログオン時に`maintain --apply`を実行するタスクを登録します。03:00にPCの電源が入っていない場合も、次にそのユーザーがログオンした後に整理します。ログオン中のスリープなどで予定時刻を逃した場合は、`StartWhenAvailable`により実行可能になった後に繰り越します。実行時刻にはWindowsタスクスケジューラーの遅延があり、PCを整理のために起こす設定は行いません。管理者権限やパスワードは使用しません。更新時は同じ実行先の既存タスクを再登録せず、利用者による時刻変更や無効化を保持します。CLIとMCPの実削除も同じ保持方針を適用します。dry-run、復元、操作一覧、hook入力の検査では自動整理しません。

定期整理タスクはCodex連携を解除しても残ります。タスクだけを解除する手順は[連携手順の「解除と復元」](docs/integration.md#解除と復元)を参照してください。解除後も実削除時の自動整理は行われます。

```text
prunlet --config <絶対パス> maintain
prunlet --config <絶対パス> maintain --apply
```

`maintain`と`--dry-run`は検査のみです。`--apply`で期限と容量に従って整理します。旧コピーにも適用されます。整理では新方式の実体IDと記録、旧方式のサイズ・ハッシュを検証してから復元データを削除し、操作の記録・ロックを残します。整理後はその操作を復元できません。

更新後は、同じ復元領域を使う旧Prunlet CLI・MCPを終了し、新版で起動してください。旧プロセスが書き込んでいる間は容量上限を厳密には保証できません。

特定の操作を期限前に整理するには、`purge <operationId>`で検査し、`purge <operationId> --apply`で適用します。失敗項目に紐づく途中コピーも検証して整理し、中断後は同じ操作IDで再開できます。専用領域を手動削除せず、CLIから整理してください。新方式は同一ボリュームの退避を必須とし、コピー方式への切替はありません。

## 操作履歴の物理容量を減らす

復元データを整理した後も、監査と中断再開に使うJSON・ロックは残ります。この履歴は復元データの容量上限には含まれません。schema 4の移動記録は当面圧縮対象外で、理由付き`retained`となります。以下は旧schema 1/2/3のコピー形式の履歴についての説明です。NTFS上では、毎日03:00・ログオン時の既存の定期整理が、正常にpurge済みの履歴JSONも自動圧縮します。CLI・MCPの実削除前にも、その回で復元コピーを自動整理した操作の履歴を圧縮します。

定期・明示`maintain --apply`の結果は`historyCompaction`で確認できます。手動`purge`で残った履歴も次回の定期・明示maintainで圧縮します。自動処理の`skipped_compressed`は既に圧縮済みという意味で、JSONの内容を再検証した結果ではありません。検証範囲と自動処理の設計は[操作履歴の圧縮](DESIGN.md#操作履歴の圧縮)を参照してください。

全履歴を内容から検証して検査・圧縮する場合は、次を実行します。

```text
prunlet --config <絶対パス> compact-history
prunlet --config <絶対パス> compact-history --apply
```

既定と`--dry-run`は検査のみです。`--apply`は、コピーが残っておらず、正常なpurge結果を持つ操作の既知JSONだけをNTFS圧縮します。ファイル名・JSONの内容・ロック・既存の操作IDは保持し、ファイルを削除・置換しません。圧縮前後のSHA-256と長さを照合し、結果の`physicalBytesBefore`・`physicalBytesAfter`でファイルシステムが報告する物理容量を確認できます。論理サイズは変わらず、検査だけでは圧縮後の容量を見積もりません。

復元コピーが残る操作、使用中の操作、不正な記録、未知の項目、リンク・ADS・読み取り専用属性などがある操作は、理由を警告へ返して保持します。非NTFSの保存先には適用しません。自動整理の保持期間・容量上限や定期タスクは変更しません。

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
