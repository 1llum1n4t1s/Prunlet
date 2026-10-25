# Prunlet — Anti “blocked by policy”

Prunletは、`blocked by policy`による清掃の停止を減らすために、AIエージェントのファイル・フォルダー削除を専用CLI・MCPへ集約するWindows用ツールです。許可された削除を最初からPrunletへ任せる使い方に揃えます。

指定したファイル・フォルダーをWindowsのゴミ箱へ移し、操作IDを使ってCLI・MCPから元へ戻せます。実体の保管・清掃はWindowsに任せ、Prunletは安全な復元に必要な記録を保持します。レジストリのキー・値は専用snapshotとトランザクションで保全して削除します。Codexフックは直接削除を検査・拒否してCLI手順を案内します。提供元はKagayoiです。

対応するCodexホストでは、ファイル・フォルダーの実削除と復元を初回から正式なsandbox権限申請付きで実行します。dry-runの成功だけではゴミ箱へのアクセス許可を保証できません。[sandboxとゴミ箱へのアクセス](docs/integration.md#sandboxとゴミ箱へのアクセス)を参照してください。

互いに重ならない削除は1つのPrunletプロセスで最大4件を並行処理し、MCPも複数の削除要求を受け付けます。同じ実体を共有するハードリンクの別名もまとめて指定でき、元の権限を検証したうえで上書きせずに復元できます。並行操作でロックを待つ間は、経過時間とロック取得を通知します。CLI・MCPでの確認方法は[使用中のファイルと同時実行](docs/integration.md#使用中のファイルと同時実行)を参照してください。

ファイルと空フォルダーを扱い、`--recursive`を明示するとフォルダー全体を削除できます。シンボリックリンク・ジャンクションはリンク自体を削除し、リンク先を辿りません。ワイルドカード・ネットワークパス・未知のreparseタグ・リンク自体がADSを持つ場合は扱いません。通常の削除であり、ディスク上のデータを復元不能にする消去機能はありません。

ゴミ箱項目の識別情報とFile IDを記録し、復元時に現在の実体と照合します。復元先に同名のファイル・フォルダーがあれば上書きもマージもせず停止します。ハードリンクの外部別名からの書込みは保管中の実体にも反映されるため、保存時点の不変コピーではありません。

新しい記録では元の所有者・グループ・DACLも保存し、CLI・MCPの復元時に完全一致を確認します。復元途中で止まった場合の再開条件と、ACL情報のない旧記録の制限は[連携手順](docs/integration.md#手動の設定準備)を参照してください。

通常のローカル絶対パスに加え、`C:/...`表記、`\\?\C:\...`形式、8.3短縮名、CodexのMSIXによるAppData転送を扱います。通常ファイル・フォルダーの実体と祖先を確認して実体パスへ揃えるため、保存場所の転送や表記の違いだけを理由に追加の許可を求めません。結果の`path`と新しい復元記録には実体パスを保存します。

大文字小文字を区別するディレクトリも属性と正確な名前を同じオブジェクトのまま保持します。旧コピー形式の復元では属性の再設定が必要になる場合があります。[保存形式と互換性](DESIGN.md#旧コピー形式の互換性)を参照してください。

## `blocked by policy`対策としての使い方

AIが生成した`Remove-Item`や`rm`などの削除コマンドで清掃が止まりやすい環境では、許可された削除を最初からPrunlet CLIへ任せます。対象の検証、Windowsのゴミ箱への移動、操作IDによる非上書き復元を専用ツールへ集約できます。

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

更新時は最新版のインストーラーを再取得して実行します。[保持容量の一度だけの移行](#復元データの保持と自動整理)を除き、既存の`config.json`と復元データを保持します。削除対象フォルダーの事前登録は不要です。旧`-AllowedRoot`は互換引数として受理しますが、削除範囲を制限しません。配置先は`-InstallDirectory`で変更できます。利用者のクローンパスをCodex設定へ登録することはありません。

取得したbootstrapファイルは一時物です。導入結果を確認して、そのbootstrap専用ディレクトリだけを清掃してください。アプリの配置先と復元用データは清掃対象に含めません。

更新前の製品や登録前のCodex設定のバックアップがある場合、導入結果の`updateBackupDirectory`に保存先が表示されます。既定は`%LOCALAPPDATA%\Codex\TaskArtifacts\Prunlet\install-<ID>`です。動作とCodex登録を確認し、復旧が不要になってから、その導入分のバックアップだけを清掃してください。連携スクリプトの設定バックアップは[連携手順](docs/integration.md)を参照してください。

MSIX環境でAppDataが別の実体へ転送される場合は、`-UpdateBackupRoot <実体の絶対パス>`で更新バックアップの親を明示できます。その下へ導入ごとの`install-<ID>`を作ります。導入ごとの保存先がリポジトリ、Codex home、配置先、作業場所、復元データと重なる場合は拒否します。旧PowerShellバックエンドの退役ではPrunlet Coreを使い、`retirement-config.json`と削除結果も同じ更新バックアップへ保持します。

## 初期設定

操作記録・レジストリsnapshot・既存の退避データの保存先を指定し、そのディレクトリを事前に作成します。対象はローカルドライブ内の通常ファイル・フォルダーで、対象フォルダーの許可リストはありません。保存先は通常削除から保護します。新しいファイル実体はWindowsのゴミ箱に置き、Prunletの7日・1 GiB設定の対象から外します。

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
```

`backupDirectory`は中央の操作記録、レジストリsnapshot、旧コピーの保存先です。既存schema 4の退避実体は既定で各ボリュームの`<volumeRoot>\.Prunlet-Recovery-<SID>\<storeKey>\<operationId>\0000.entry`にあります。任意の`volumeRecoveryDirectories`でボリューム別専用baseを指定できますが、必ず対象と同じボリュームに置きます。異なるボリュームへのコピーfallbackはありません。schema 6の復元中に使う一時領域を含む配置と保護の詳細は[設計](DESIGN.md#ボリューム別の復元領域)を参照してください。

インストーラーを利用した場合は初期化済みです。手動の`init`も既存設定を上書きしません。旧`--allowed-root`と設定の`allowedRoots`はschema 1との互換用に受理しますが、削除範囲の判定には使いません。`allowedRoots`を省略・空配列・nullにした設定や、記録された旧ルートが存在しなくなった設定も使用できます。

```json
{
  "schema": 1,
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery",
  "retentionDays": 7,
  "maxRecoveryBytes": 1073741824
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

空フォルダーは通常の`delete`、内容があるフォルダーは`delete --recursive --paths-file <絶対JSONパス>`でゴミ箱へ移します。ゴミ箱へ移せない場合は、永久削除や独自退避への切替を行わず失敗とします。復元はゴミ箱項目を消費し、既存のファイル・フォルダーには上書きもマージもせず`conflict`を返します。同一オブジェクトの復元を確認できる再実行は`already_restored`です。

Windowsのゴミ箱が容量や元パスの長さを受け付けない場合は、元データを残して失敗を返します。`--dry-run`は入力・実体の検査であり、実際のゴミ箱移動の成功を保証するものではありません。

対象や子フォルダーを他のアプリが使用している場合も移動できません。共有違反ではHRESULTと使用中の案内を返します。該当アプリを終了し、元の場所とゴミ箱に残った実体を確認してから明示的に再実行してください。

単純なパスは`delete [--dry-run] [--recursive] -- <絶対パス> [...]`でも指定できます。長い対象パスも通常のローカル絶対パスで指定でき、`\\?\C:\...`形式も受け付けます。元の削除がホストに拒否された場合、別shellやPrunletへ付け替えて再試行しません。

出力はJSONです。削除結果の`operationId`と各ファイルの`status`を確認してください。欠損ファイルは`already_absent`として返します。復元先に項目が存在するときは上書きせず、退避実体を保持します。失敗時は終了コードが0以外になります。

既存schema 1/2/3のコピー形式とschema 4の専用領域も、同じCLI・MCPから復元できます。旧形式の記録をゴミ箱形式へ自動変換しません。[互換経路の設計](DESIGN.md#旧コピー形式の互換性)を参照してください。

## レジストリの削除・復元

許可されたローカルのHKCU・HKLM・HKUのキーまたは値を、明示した32/64ビットviewで退避して削除できます。キーのパスは絶対指定し、`--`の後へ1件だけ渡します。`--value-name`を省略するとキー、指定すると文字通りの値名を対象にします。既定値は空の名前なので、PowerShellから空引数が失われない`--value-name=`を使えます。値削除と`--recursive`は併用できません。子キーを含む削除には`--recursive`が必要です。

```text
prunlet --config <絶対パス> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
prunlet --config <絶対パス> registry-delete --view 64 --recursive -- HKCU:\Software\Example
prunlet --config <絶対パス> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
prunlet --config <絶対パス> restore <operation-id>
```

schema 5の退避データ・記録・ロックは最初の書込みから現在のユーザーとSYSTEMだけがアクセスできるACLで作成し、ACL改変を検出した記録は復元・整理せず保全します。キーは未知の値型も含め型のuint値・生バイト列とOwner・Group・DACL・SACL（Mandatory Labelを含む）を保存します。完全なACL取得には`SeSecurityPrivilege`が必要で、トークンにある場合だけ一時有効化します。不足時は削除前に停止し、自動昇格しません。KTMトランザクションに対応しない環境へのfallbackはありません。値には独立したACLがなく、値の復元では親キーのACLを変更しません。

復元は元のviewへ行い、既存キー・値（空の既定値も含む）を上書き・マージしません。Owner/SACLの復元権限が不足した場合もロールバックして退避を保全します。ルート自体・HKCR/HKCC・リモート・相対指定・レジストリリンク・未知のschema・metadataや検証できない復元記録は拒否します。キーのclassも保存しますが、最終書込み時刻は復元せず、volatileキーも非volatileキーとして復元します。commit後の記録確定前に中断した操作は不明状態として保全し、自動整理・復元を拒否します。

MSIX由来の仮想viewで6801になる場合は、[通常Windowsの明示セッション](docs/integration.md#通常windowsのレジストリを明示して操作する)を利用できます。利用者が通常デスクトップで期限付きセッションを起動し、専用設定を選んだCLI・MCPから接続します。仮想viewからの自動切替や自動昇格は行わず、仮想view内のキーを通常Windows側の同名キーとして扱いません。

セッションの応答が失われた場合は、通知された`operationId`を保持し、`prunlet --config <同じ設定の絶対パス> registry-reconcile <operation-id>`で保存済みの結果を確認してください。同じ削除を再送せず、不明なcommit結果を現在のキーの有無から推測しません。復元成功後はsnapshotを消費するため、同じ操作IDから繰り返し復元できません。

## 復元データの保持と自動整理

新しいファイル・フォルダーの保持期間・容量・完全削除はWindowsのゴミ箱設定やストレージセンサー、利用者の操作に従います。Windows側で完全削除された項目はPrunletから復元できません。Prunletの`maintain`・`purge`はゴミ箱項目を消しません。

レジストリsnapshotと既存schema 1〜4の退避データには、従来の保持制御を維持します。既定は操作作成から7日・合計1 GiBです。正式インストーラーでの次回更新時に、既存設定も一度だけ`maxRecoveryBytes`を1 GiBへ移行します。移行済みを`capacityDefaultMigrationVersion: 1`として保存し、以後の明示的な容量変更を保持します。新規`init`も移行済みで作成します。設定読込・dry-runだけでは設定の変更や整理を行わず、移行後の整理は通常のレジストリ削除・明示`maintain --apply`・定期保守で行います。`retentionDays`は1〜36,500日の整数、`maxRecoveryBytes`は正の整数（バイト数）です。期限切れ、次いで必要容量に応じた古い操作を整理します。元対象の事前走査と整理前後の再走査、入力合計が上限を超える1操作だけの例外予算は、このPrunlet管理データに適用します。

インストーラーは、現在のWindowsユーザーで毎日03:00とログオン時に`maintain --apply`を実行するタスクを登録します。コンソールを持たない保守専用`prunlet-maintenance.exe`が同じCoreを実行するため、起動時にターミナルを表示しません。03:00にPCの電源が入っていない場合も、次にそのユーザーがログオンした後に整理します。ログオン中のスリープなどで予定時刻を逃した場合は、`StartWhenAvailable`により実行可能になった後に繰り越します。実行時刻にはWindowsタスクスケジューラーの遅延があり、PCを整理のために起こす設定は行いません。管理者権限やパスワードは使用しません。更新時は、既知の旧CLI登録の実行先だけを移行し、利用者による時刻変更や無効化、権限設定を保持します。移行済みのタスクは再登録しません。CLIとMCPのレジストリ削除前にも同じ保持方針を適用します。dry-run、復元、操作一覧、hook入力の検査では自動整理しません。

定期整理タスクはレジストリと旧退避データのために残し、Codex連携の解除だけでは削除しません。[タスクの解除手順](docs/integration.md#解除と復元)を参照してください。解除後もレジストリ削除前の自動整理は行われます。新規ファイル削除は旧退避データの整理を起動しません。

```text
prunlet --config <絶対パス> maintain
prunlet --config <絶対パス> maintain --apply
```

`maintain`と`--dry-run`は検査のみです。`--apply`で期限と容量に従って整理します。整理では旧schema 4の実体IDと記録、旧コピーのサイズ・ハッシュ、レジストリsnapshotの整合性を検証してから復元データを削除し、操作の記録・ロックを残します。整理後はその操作を復元できません。

更新後は、同じ復元領域を使う旧Prunlet CLI・MCPを終了し、新版で起動してください。旧プロセスが書き込んでいる間は容量上限を厳密には保証できません。

特定の旧退避・レジストリ操作を期限前に整理するには、`purge <operationId>`で検査し、`purge <operationId> --apply`で適用します。失敗項目に紐づく途中コピーも検証して整理し、中断後は同じ操作IDで再開できます。専用領域を手動削除せず、CLIから整理してください。

## 操作履歴の物理容量を減らす

復元データを整理した後も、監査と中断再開に使うJSON・ロックは残ります。この履歴は復元データの容量上限には含まれません。schema 4の移動記録・schema 5のレジストリ記録・schema 6のゴミ箱記録は当面圧縮対象外で、理由付き`retained`となります。以下は旧schema 1/2/3のコピー形式の履歴についての説明です。NTFS上では、毎日03:00・ログオン時の既存の定期整理が、正常にpurge済みの履歴JSONも自動圧縮します。CLI・MCPのレジストリ削除前にも、その回で復元コピーを自動整理した操作の履歴を圧縮します。

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
| `delete_registry` | `path`・`view`（`"32"`/`"64"`）、任意の`valueName`・`recursive`・`dryRun` | キーまたは値を保全して削除。空の`valueName`は既定値 |
| `restore_registry` | `operationId` | レジストリ操作を非上書きで復元 |
| `reconcile_registry` | `operationId` | 切断後に保存済みの結果を読取り確認。削除・復元を再送しない |
| `list_operations` | なし | 保存された操作IDの一覧（復元可否は復元時に検証） |

サーバーは削除ツールの用途を`instructions`で通知します。通常入口はCLIで、MCPは配置済みexe・設定をCMDで安全に表現できない場合などの代替入口です。purgeは明示CLI操作です。

## Codexとの連携

共通MCP登録、削除入力の検査、解除手順は[連携手順](docs/integration.md)を参照してください。ネイティブexeのフックは認識した直接削除を拒否してCLI手順を案内し、削除や入力の自動置換は行いません。Codex側の承認や管理ポリシーを維持します。PowerShellは導入・ビルド・E2Eの管理スクリプトで使い、通常の削除backendには使いません。

## 保存先の実体検証で停止する場合

MSIX版のアプリでは、AppDataの新しいフォルダーがパッケージ専用のLocalCacheへ転送される場合があります。通常ディレクトリの転送は実体へ解決して扱いますが、祖先のリンクや実体・属性を検証できない場合は停止します。エラーに示されたパスと属性を確認し、検証を無効化せず、必要ならexe・設定・復元データを`%USERPROFILE%\.local\Prunlet`などの専用ディレクトリへ配置してください。CodexパッケージのLocalCacheを復元データの恒久保存先にすることは推奨しません。

## レジストリのトランザクションが利用できない場合

`ERROR_RM_NOT_ACTIVE`（6801）などで対象hiveのトランザクションが利用できない場合は、削除をcommitせず元データを保全して停止します。同じPCでもhiveごとに利用可否が異なる場合があります。非トランザクション削除への切替や、原因未確認のOS修復は行わず、エラーと対象hive・viewを確認してください。

## 開発資料

開発時のビルドと作業規約は[AGENTS.md](AGENTS.md)、構造と設計判断は[DESIGN.md](DESIGN.md)、E2Eの実行方法と検証範囲は[検証手順](docs/verification.md)を参照してください。
