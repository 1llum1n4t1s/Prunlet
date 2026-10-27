# Prunlet — Anti “blocked by policy”

Prunletは、`blocked by policy`による清掃の停止を減らすために、AIエージェントのファイル・フォルダー削除を専用CLI・MCPへ集約するWindows用ツールです。許可された削除を最初からPrunletへ任せる使い方に揃えます。

指定したファイル・フォルダーをWindowsのゴミ箱へ移します。Prunletはファイルの操作記録・操作ID・復元用snapshotを保存せず、復元と保持期間の管理はWindowsのゴミ箱で行います。レジストリのキー・値は専用snapshotとトランザクションで保全し、操作IDによる非上書き復元を提供します。Codexフックは直接削除を検査・拒否してCLI手順を案内します。提供元はKagayoiです。

ファイルと空フォルダーを扱い、`--recursive`を明示するとフォルダー全体を削除できます。リンク先を辿らず、ゴミ箱へ移せない場合に永久削除や独自退避へ切り替えることはありません。ハードリンクは生存する別名と内容を共有するため、保存時点の不変コピーではありません。

対応するCodexホストでは、実削除を初回から正式なsandbox権限申請付きで実行します。dry-runはゴミ箱へのアクセス許可を保証しません。[連携手順](docs/integration.md)で入力形式・権限・ロック通知を確認してください。

## `blocked by policy`対策としての使い方

AIが生成した`Remove-Item`や`rm`などの削除コマンドで清掃が止まりやすい環境では、許可された削除を最初からPrunlet CLIへ任せます。対象の検証とWindowsのゴミ箱への移動を専用ツールへ集約できます。

Codexでは、次の順序で利用します。

1. 下の[インストールと更新](#インストールと更新)のコマンドを、`-RegisterCodex -RegisterAgentInstructions`付きで実行します。CLI・MCP・フックと、Prunlet CLIを最初から使う共通指示を登録します。
2. Codexで`/hooks`を開いてPrunletフックを信頼し、Codexを再起動して登録内容を読み込みます。
3. 通常どおり作業や清掃を依頼します。共通指示は、配置済みCLIと設定の絶対パスを使い、CMD（`shell: cmd.exe`、`login: false`）からPrunletを直接呼び出すようCodexへ指示します。各リポジトリへ同じ指示を追加する必要はありません。

清掃を明示して依頼する場合は、たとえば次のように伝えます。

> 今回作成した不要な一時ファイルと作業フォルダーを、最初からPrunlet CLIで清掃してください。

空白・Unicode・長いパス・複数対象はUTF-8のJSON一覧を`--paths-file`で渡し、非空フォルダーには`--recursive`を明示します。実際のコマンドと復元方法は、後述の「削除・復元」を参照してください。

フックは直接削除を検出・拒否してCLI手順を案内する補助で、自動変換は行いません。失敗と再試行を繰り返さずに済むよう、共通指示による初回からのCLI利用を基本にします。ホストやOSの権限・承認・管理ポリシーは引き続き適用されます。Prunletの呼出し自体が拒否された場合は停止し、別経路で再試行しません。登録と検査範囲の詳細は[連携手順](docs/integration.md)を参照してください。

Macなどへ送るPowerShellスクリプトを文字列として渡す場合は、`exec_command`で`shell: "pwsh"`を明示し、単引用ヒアストリングを使います。詳しくは[フックの連携手順](docs/integration.md)を参照してください。

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

更新時は最新版のインストーラーを再取得して実行します。既存の`config.json`は保持容量の一度だけの移行を除いて保持します。旧復元データは[明示移行](#旧ファイル復元データの移行)で扱います。削除対象フォルダーの事前登録は不要です。旧`-AllowedRoot`は互換引数として受理しますが、削除範囲を制限しません。配置先は`-InstallDirectory`で変更できます。利用者のクローンパスをCodex設定へ登録することはありません。

取得したbootstrapファイルは一時物です。導入結果を確認して、そのbootstrap専用ディレクトリだけを清掃してください。アプリの配置先と復元用データは清掃対象に含めません。

更新前の製品や登録前のCodex設定のバックアップがある場合、導入結果の`updateBackupDirectory`に保存先が表示されます。既定は`%LOCALAPPDATA%\Codex\TaskArtifacts\Prunlet\install-<ID>`です。動作とCodex登録を確認し、復旧が不要になってから、その導入分のバックアップだけを清掃してください。連携スクリプトの設定バックアップは[連携手順](docs/integration.md)を参照してください。

MSIX環境でAppDataが別の実体へ転送される場合は、`-UpdateBackupRoot <実体の絶対パス>`で更新バックアップの親を明示できます。その下へ導入ごとの`install-<ID>`を作ります。導入ごとの保存先がリポジトリ、Codex home、配置先、作業場所、復元データと重なる場合は拒否します。旧PowerShellバックエンドの退役ではPrunlet Coreを使い、`retirement-config.json`と削除結果も同じ更新バックアップへ保持します。

## 初期設定

インストーラーを利用した場合は初期化済みです。手動ではレジストリ復元データの保存先を指定します。`init`は既存設定を上書きしません。

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
& $exe --config $config migrate --dry-run
& $exe --config $config migrate --apply
```

`backupDirectory`はレジストリsnapshotと移行前の旧データを置く保護領域です。新しいファイル削除の記録・内容は保存しません。レジストリ記録は専用の`.registry-records-v1`配下へ保存します。設定の`allowedRoots`と旧`--allowed-root`は互換入力であり、削除範囲の許可リストには使いません。

手動の`init`は設定作成だけを行います。レジストリを使う前に`migrate --dry-run`で対象を確認し、`migrate --apply`を実行してください。未移行ならレジストリの通常操作は`migration_required`で停止し、旧ファイル領域を自動探索しません。ファイル削除はレジストリの移行状況に依存しません。

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
```

exe・設定は配置済みの絶対パスへ置き換えてください。Codexでは`cmd.exe`・`login: false`を指定します。空白・Unicode・多数・長い対象パスはshellへ展開せず、UTF-8 JSON配列の絶対パスで渡します。`--paths-file`は1〜256件、最大1 MiBです。

```json
["C:\\work\\project\\unused.txt", "C:\\work\\project\\other.txt"]
```

空フォルダーは通常の`delete`、内容があるフォルダーは`delete --recursive --paths-file <絶対JSONパス>`で扱います。単純なパスは`delete [--dry-run] [--recursive] -- <絶対パス> [...]`でも渡せます。ワイルドカード・ネットワークパス・未知のreparseタグは扱いません。リンクはリンク自体を削除し、リンク先を走査しません。

結果は`dryRun`・`items`・`warnings`です。各項目の`path`・`kind`・`status`と任意の`error`を確認します。状態は`recycled`・`would_recycle`・`already_absent`・`failed`・`ambiguous`で、ファイルの操作ID・backupPath・hash・sizeは返しません。`failed`と`ambiguous`は成功扱いになりません。

復元はWindowsのゴミ箱から行います。Prunletにはファイル復元コマンド・MCPツールがありません。Windows側で完全削除された項目は復元できません。ゴミ箱の復元先に既存項目がある場合は、Windowsの画面で競合を確認し、上書きしないでください。

使用中・権限不足・容量・パス制限などで移動できない場合は結果を確認してください。`ambiguous`は元対象とWindowsのゴミ箱を確認し、同じ削除を自動再送しません。dry-runの成功は実移動の成功を保証しません。

## レジストリの削除・復元

許可されたローカルのHKCU・HKLM・HKUのキーまたは値を、明示した32/64ビットviewで退避して削除できます。キーのパスは絶対指定し、`--`の後へ1件だけ渡します。`--value-name`を省略するとキー、指定すると文字通りの値名を対象にします。既定値は空の名前なので、PowerShellから空引数が失われない`--value-name=`を使えます。値削除と`--recursive`は併用できません。子キーを含む削除には`--recursive`が必要です。

```text
prunlet --config <絶対パス> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
prunlet --config <絶対パス> registry-delete --view 64 --recursive -- HKCU:\Software\Example
prunlet --config <絶対パス> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
prunlet --config <絶対パス> registry-restore <operation-id>
```

schema 5の退避データ・記録・ロックは最初の書込みから現在のユーザーとSYSTEMだけがアクセスできるACLで作成し、ACL改変を検出した記録は復元・整理せず保全します。キーは未知の値型も含め型のuint値・生バイト列とOwner・Group・DACL・SACL（Mandatory Labelを含む）を保存します。完全なACL取得には`SeSecurityPrivilege`が必要で、トークンにある場合だけ一時有効化します。不足時は削除前に停止し、自動昇格しません。KTMトランザクションに対応しない環境へのfallbackはありません。値には独立したACLがなく、値の復元では親キーのACLを変更しません。

復元は元のviewへ行い、既存キー・値（空の既定値も含む）を上書き・マージしません。Owner/SACLの復元権限が不足した場合もロールバックして退避を保全します。ルート自体・HKCR/HKCC・リモート・相対指定・レジストリリンク・未知のschema・metadataや検証できない復元記録は拒否します。キーのclassも保存しますが、最終書込み時刻は復元せず、volatileキーも非volatileキーとして復元します。commit後の記録確定前に中断した操作は不明状態として保全し、自動整理・復元を拒否します。

MSIX由来の仮想viewで6801になる場合は、[通常Windowsの明示セッション](docs/integration.md#通常windowsのレジストリを明示して操作する)を利用できます。利用者が通常デスクトップで期限付きセッションを起動し、専用設定を選んだCLI・MCPから接続します。仮想viewからの自動切替や自動昇格は行わず、仮想view内のキーを通常Windows側の同名キーとして扱いません。

セッションの応答が失われた場合は、通知された`operationId`を保持し、`prunlet --config <同じ設定の絶対パス> registry-reconcile <operation-id>`で保存済みの結果を確認してください。同じ削除を再送せず、不明なcommit結果を現在のキーの有無から推測しません。復元成功後はsnapshotを消費するため、同じ操作IDから繰り返し復元できません。

レジストリの`--dry-run`は、実削除と同じ対象・権限・再帰範囲でトランザクションへの接続も確認し、接続できない場合は失敗します。データの書込み・削除は行わず、後続の実削除の成功までは保証しません。

## 復元データの保持と自動整理

`retentionDays`（既定7日）と`maxRecoveryBytes`（既定1 GiB）はレジストリsnapshotだけに適用します。Windowsのゴミ箱はWindowsが保持・清掃し、Prunletは容量・期限・purgeの対象にしません。

旧設定で容量上限の移行印が未設定、または1未満の場合、latest導入時に一度だけ`maxRecoveryBytes`を1 GiBへ更新します。移行後の利用者による容量変更は再更新でも保持します。

`operations`はレジストリ操作IDを一覧し、`purge <registry-operation-id> [--dry-run | --apply]`と`maintain [--dry-run | --apply] [--audit-records]`もレジストリ専用です。省略時は検査のみです。削除前と明示・定期保守では、保護された記録を検査して保持条件を適用します。曖昧な記録や検証できないsnapshotは保全します。

Windowsのゴミ箱にある間のアクセス権と、復元先の親からの権限継承もWindowsの動作に従います。ハードリンクは内容だけでなくACLも共有するため、ゴミ箱への移動時の権限変更が、生存する別名にも反映されます。

## 旧ファイル復元データの移行

`migrate [--dry-run | --apply]`は、旧ファイルの退避データと操作記録を整理し、旧レジストリ記録を専用namespaceへ移します。**旧ファイルの復元互換は終了します。** 所有を確認できる旧ファイル領域は、形式の展開・内容hash検査・コピー・bundle化をせず、そのままWindowsのゴミ箱へ送ります。既にゴミ箱にあるファイルはWindows管理のままです。旧データを復元用に変換する処理や、元権限の参照ファイルは作りません。

通常のファイル削除・一覧・保守は旧操作ディレクトリを走査しません。インストーラーは登録と旧backend退役後に`migrate --apply --if-needed`を実行し、policy 2で評価済みの中央旧領域は再走査しません。後からオンラインになった所有済みstoreを拾うため、更新時は固定位置と小さな所有markerだけを確認します。

レジストリの保全・完全ACL・非上書き復元は維持します。レジストリの痕跡がある領域、所有を確認できない領域、オフラインや権限不足の領域は警告付きで残し、ファイル整理の未完了だけでレジストリ通常操作を止めません。

中断・結果不明のファイル整理は自動再送せず、固定の空gateで停止します。元フォルダーとWindowsゴミ箱を確認した後だけ、`migrate --apply --retry-legacy-discard`で明示的に再評価してください。インストーラーはこのackを自動指定しません。移行開始後に導入が失敗した場合も、新しいexe・設定・登録を保持し、旧binaryへ戻しません。

## MCP

`prunlet --config <絶対パス> mcp`でローカルstdioサーバーを起動します。標準出力はJSON-RPC専用です。MCPプロトコルの2025-11-25・2025-06-18・2024-11-05に対応します。

| ツール | 引数 | 用途 |
| --- | --- | --- |
| `delete_files` | `paths`、任意の`dryRun`・`recursive` | ファイル・空フォルダー、明示再帰で内容も削除 |
| `delete_registry` | `path`・`view`（`"32"`/`"64"`）、任意の`valueName`・`recursive`・`dryRun` | キーまたは値を保全して削除。空の`valueName`は既定値 |
| `restore_registry` | `operationId` | レジストリ操作を非上書きで復元 |
| `reconcile_registry` | `operationId` | 切断後に保存済みの結果を読取り確認。削除・復元を再送しない |
| `list_operations` | なし | レジストリ操作IDの一覧（復元可否は復元時に検証） |

サーバーは削除ツールの用途を`instructions`で通知します。通常入口はCLIで、MCPは配置済みexe・設定をCMDで安全に表現できない場合などの代替入口です。purgeは明示CLI操作です。

## Codexとの連携

共通MCP登録、削除入力の検査、解除手順は[連携手順](docs/integration.md)を参照してください。ネイティブexeのフックは認識した直接削除を拒否してCLI手順を案内し、削除や入力の自動置換は行いません。Codex側の承認や管理ポリシーを維持します。PowerShellは導入・ビルド・E2Eの管理スクリプトで使い、通常の削除backendには使いません。

## 保存先の実体検証で停止する場合

MSIX版のアプリでは、AppDataの新しいフォルダーがパッケージ専用のLocalCacheへ転送される場合があります。通常ディレクトリの転送は実体へ解決して扱いますが、祖先のリンクや実体・属性を検証できない場合は停止します。エラーに示されたパスと属性を確認し、検証を無効化せず、必要ならexe・設定・復元データを`%USERPROFILE%\.local\Prunlet`などの専用ディレクトリへ配置してください。CodexパッケージのLocalCacheを復元データの恒久保存先にすることは推奨しません。

## レジストリのトランザクションが利用できない場合

`ERROR_RM_NOT_ACTIVE`（6801）などで対象hiveのトランザクションが利用できない場合は、削除をcommitせず元データを保全して停止します。同じPCでもhiveごとに利用可否が異なる場合があります。非トランザクション削除への切替や、原因未確認のOS修復は行わず、エラーと対象hive・viewを確認してください。

## 開発資料

開発時のビルドと作業規約は[AGENTS.md](AGENTS.md)、構造と設計判断は[DESIGN.md](DESIGN.md)、E2Eの実行方法と検証範囲は[検証手順](docs/verification.md)を参照してください。
