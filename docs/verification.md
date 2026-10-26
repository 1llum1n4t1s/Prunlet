# E2E検証

Windows・.NET 10 SDK・PowerShell 7で実行する。ビルドは`scripts/Publish-Prunlet.ps1`へ外部の絶対出力先を渡す。直接の`dotnet build`・`dotnet publish`でリポジトリ内へ出力しない。metadata・TEMP/TMP・fixture・reportも未使用の外部D絶対パスへ隔離し、reportの親を先に作る。

各検証ではCLI・stdio MCP・hookの実プロセス、終了コード・stdout JSON・`passed`/`failed`を読む。skip・CaseFilter・準備だけの成功を全件合格にせず、権限・KTM・view・実offlineなど未検証の環境条件を明記する。今回の変更による結果と過去版の結果を混同しない。

## 通常E2Eの検証範囲

新しいファイル経路は、操作記録を作らずWindowsゴミ箱へ移す経路として検証する。旧schema 1〜4/6の復元・圧縮・終了履歴runnerを、新版通常経路の必須成功条件として使わない。旧版exeで作ったデータは下記の明示移行検証だけに使用する。

- CLIの単一・複数・Unicode・長いパス・`--paths-file`・空フォルダー・明示再帰とdry-run、MCPの入力型・余剰property・1〜256件上限を実プロセスで確認する。
- ファイル結果が`dryRun`・`items`・`warnings`で、項目が`path`・`kind`・`status`・任意`error`だけを返すことを確認する。`recycled`・`would_recycle`・`already_absent`・`failed`・`ambiguous`と終了コード/MCP `isError`を照合し、operationId・backupPath・hash・sizeを返さないことを確認する。
- 新規削除前後でPrunlet保存領域を比較し、操作manifest・PIDL・File ID・ACL snapshot・monitor・index・復元stageを作らないことを確認する。固定`maintenance.lock`と操作記録を区別する。通常削除・list・maintainが旧ファイル操作ディレクトリを走査しないことも確認する。
- 内容・File ID・ADS・通常属性・case-sensitiveな名前・ACLと、リンク先の保全・外部ハードリンク別名との共有を確認する。復元は今回fixtureのWindowsゴミ箱項目だけで行い、ゴミ箱全体の空化や既存項目の清掃は行わない。復元先に既存項目を作り、上書きせず競合を扱う。
- preflight失敗時の全対象保全、独立対象の並行完了、同一対象・親子の排他、共有ハードリンク検出時の排他、入力順を確認する。MCPの要求枠とworker枠・進捗分離・EOF後の完了を区別する。
- `restore`/`registry-restore`がファイルを復元せず、MCPの一覧が5ツールで`restore_files`を持たないことを確認する。hookの直接削除拒否・非削除入力通過・配置済みCLI案内・既存ホスト権限を確認する。

`scripts/Verify-RecordlessFiles.ps1 -ExecutablePath <今回のexe> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSONパス>`を実行する。追加オプションは実装済みスクリプトのparamと照合し、未実行のケース数を成功実績として記載しない。

## 旧復元データの明示移行

`scripts/Verify-FileRecordMigration.ps1`へ今回のexeと真正な旧版exeを渡す。旧schemaを新版で捏造せず、旧ファイルの退避root・操作記録が直接Windowsゴミ箱へ移り、sourceが不在になることを確認する。旧形式の展開・bundle・sidecar・保全コピー・復元互換を成功条件へ残さない。schema 6の元ゴミ箱項目は管理をWindowsへ委ね、metadataだけを整理する。

所有markerとroot layout、他config/privateBaseの保護、registry signal混在、未知の非所有領域、壊れたfile本文の非読取、dry-run不変更、policy未指定stateからversion 2、更新後の中央旧領域非走査と後から現れたowned store回収を検証する。通常delete/list/maintainが旧ファイルrootを探索しないことも確認する。

固定gateのFlush後とShell成功直後に子プロセスを止め、自動再送拒否・registry利用の継続・明示ack後の再評価を確認する。不正gateをackで削除しないこと、dry-runがgateを作らないことを区別する。registry namespace・snapshot・完全ACL・scope・非上書き復元の検証は別途維持する。

## レジストリの削除と復元

新しいexeのCLI・stdio MCP・hookを実プロセスで検証する。fixtureは利用可能なhiveの専用キー配下へ隔離して作成し、hive・view・実行権限をレポートへ記録する。HKCUでKTMを利用できない環境では、許可されたHKLMの専用fixtureで正系を検証し、HKCUの拒否・原データ保全と区別する。レポートと一時物は外部作業領域へ置き、親を事前作成する。終了コード・stdout JSON・`passed`/`failed`を読み、未実行の権限・view・KTMケースを合格扱いしない。

- CLIのview欠落・重複・不正・未知引数・複数キー、MCPの余剰property・型不正を拒否する。値名はliteralで、空の既定値名（CLIの`--value-name=`を含む）と値+再帰拒否を確認する。
- キー・値・既定値・未知の型を含むuint型番号と生バイト列・Unicode名を往復し、キーごとのOwner/Group/DACL/SACLとMandatory Labelを含む生のセキュリティ記述子を完全一致で比較する。値復元で親ACLが変わらないことを確認する。
- SACL実体がない子キーにも`SE_SACL_AUTO_INHERITED`だけがある階層を含め、ACLの不在・null・空を区別して制御フラグを完全一致で比較する。フラグ欠落を比較除外で回避しない。
- schema 5のpending・snapshot・metadata・ロックと操作ディレクトリが作成時から現在のユーザーSIDとSYSTEMだけのprotected DACL・現在ユーザーOwnerを持つこと、ACL改変時は読取り・復元・整理を拒否してデータを保持することを確認する。未知schemaの保全と、レジストリ専用namespace・保持制御を検証する。
- `SeSecurityPrivilege`不足・KTM非対応・レジストリリンク等はcommit前に停止する。未知のschema・metadataや検証できない復元記録は復元・整理を拒否して保全する。完全ACLを取得できる実行環境と、権限不足を期待する環境を分ける。自動昇格はしない。
- 既存キー・値・空の既定値への復元は競合となり、データを上書きしない。Owner/SACL・Mandatory Labelの適用失敗はrollbackして退避を保持する。commit後receipt未確定の不明状態は自動整理・復元を拒否してpayloadを保全する。
- 削除stage後に別の非トランザクションwriterが値やACLを更新する競合を確認し、受理された外部データがcommit失敗後も残ることを照合する。値復元もstage後の既存値検出・外部writer競合で上書きせず、snapshotを保全する。
- CLIの`restore`と`registry-restore`、MCPの`restore_registry`がレジストリ専用であること、ファイルIDの拒否、レジストリだけの7日・1 GiB予算と整理前後走査を確認する。
- hookはレジストリ対象の`Remove-Item`・alias、`Remove-ItemProperty`・`rp`、`reg[.exe] delete`とwrapper・escapeを拒否する。`reg query`とechoの無関係な文字列は通過し、拒否応答に配置済みCLI/config・view・registry-restore・operationId保持があることを確認する。

最終書込み時刻・volatile寿命等の全状態保持を検証済みと扱わない。Codex実ホストでのフック読込み・共通guide選択・承認は、プロセスE2Eと分けて確認する。

明示native sessionでは、Codex側の通常CLI・MCPを実際に起動して同じnative scopeの値を削除・復元する。通常clientと専用の管理者clientの結果を分け、セッションの実際の起動tokenも記録する。同じSIDでも別ログオン識別子からの接続は拒否する。管理者セッションでの検証を通常tokenで起動したセッションの検証に数えない。通常clientの完全ACL権限不足は正常往復の成功に数えない。RPC後の`kind`、`allowedRoots:null`とvolumeパスのslash・末尾区切りを含む設定照合、期限切れ・未接続・capability/peer/scope/config改変、scope欠落の旧記録、接続断後のoperationId照合、60秒超の共通ロック待機とMCP進捗を確認する。元のMSIX仮想viewをnativeの同名キーと同一視せず、清掃不能なprivate fixtureを新規作成しない。

再現用の`scripts/Verify-RegistrySession.ps1`は、`-Mode Prepare -ExecutablePath <今回のexe> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSONパス>`で固定したscopeと入力を準備する。同じexe・出力先・レポートを指定した`-Mode Start -AssertNativeWindows`でdesktop Explorer経由の通常用・管理者用helperを非表示起動する。UACが表示された場合だけ利用者が同意し、同意を代行しない。実token・ログオンID・exe・作成時刻・期限・scope・設定を照合してStartを確定し、入力hashとread handle・claim/permit・nonce・親の生存を確認してRunへ渡す。Run permit前にはfixtureを作成せず、二重Start/Run・改変・期限切れ・取消・親終了・遅延起動を拒否する。UACの実際の取消と記録による境界検証は区別する。

`-Mode Current`は同じ引数で、既存の仮想SoftwareへのCLI・MCPのdry-run拒否と原本・metadataの不変更、hook subprocessを確認する。新しいprivate fixtureは作成しない。Start後の`-Mode Run`で往復・競合・完全ACL・切断後照合を実行する。fixture作成前に実際のCodex clientと通常セッションのログオンIDも照合し、不一致ならキーを作成せず停止する。通常・管理者でログオンIDが異なる接続は拒否され、サーバーの権限を借りないことも確認する。汎用brokerやタスクは登録しない。

HKCUの修正を完了とするには、同じ対象exeによるcurrent側の6801拒否時の保全と、明示native側のCLI・MCP正常往復の両方を照合する。HKLMの成功、公開の成功、未検証一覧への記録でこの条件を代替しない。

## latestインストーラー

更新バックアップも`OutputDirectory\update-backups`へ隔離し、`-UpdateBackupRoot`で実体のパスを渡します。実ユーザーの更新バックアップを検証用の保存先に使いません。

```powershell
$latestRun = Join-Path 'D:\Codex\Prunlet' ('latest-verification-' + [guid]::NewGuid().ToString('N'))
$latestReport = Join-Path 'D:\Codex\TaskArtifacts\Prunlet' ('latest-verification-' + [guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path -Parent $latestReport) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-LatestInstall.ps1 -OutputDirectory $latestRun -ReportPath $latestReport -CheckPublicHead
```

GitHub応答を検証用アーカイブへ差し替え、実際のインストーラー・.NETビルド・配置・Codex登録を通すE2Eです。最新HEADの再解決、同一SHAからの導入、クローンに依存しない登録、旧設定の容量を一度だけ1 GiBへ移すこと、新規設定の移行印、移行後の明示容量と他設定・レジストリ復元データの保持、大小文字を変えた印・容量、設定だけ残る再導入、未知設定の拒否、設定ロック時の保全、制限DACLの保存と登録失敗時の設定バイト列・SDDL復旧、ZIPの不正経路・重複・リンク、取得とビルドの失敗、製品更新の失敗時の復元を検証します。Codex設定がロックされて登録が途中で失敗した場合の復旧と、旧`allowedRoots`内外にある作業場所での導入も確認します。実ユーザーの配置先・Codex設定は使いません。設定検証が`validate-config`で走査・変更せず、全登録・旧backend退役後に明示移行することを確認します。移行開始後の失敗は旧binaryへrollbackせず新exe・設定・登録を保全し、同じCLIで再開できることを確認します。

定期整理はTask Scheduler境界を隔離して、毎日03:00と現在のユーザーのログオンの両トリガー、有効状態、`StartWhenAvailable`、電池使用時の実行許可、既存タスク設定の保持をXMLで検証します。PCの電源断・スリープ・ログオフを伴う取り逃し回復の実動作は、この検証の対象外です。

非表示起動は`scripts/Verify-MaintenanceTask.ps1 -ExecutablePath <今回のCLI exe> -OutputDirectory <新しい外部D作業領域> -ReportPath <外部JSONレポート>`で、実Task Schedulerと保守専用exeを検証します。同じpublishフォルダーに`prunlet-maintenance.exe`が必要です。CLIのconsole subsystemと保守exeのGUI subsystem、旧タスクからの設定を保つ移行、保守以外のコマンドの拒否、期限切れ整理・保持対象の復元、失敗終了コード、所有者検証を確認します。`-PauseForWindowInspection`は旧・新タスクを専用lockで待機させ、別途ウィンドウを観測するための指定です。配置後も同じ登録タスクを手動起動して表示と終了コードを確認し、実際のWindows再起動と区別します。

`-CheckPublicHead`では実際のGitHubも参照します。リモートに必要な実装がまだない場合は、配置先を変更せず停止することを確認します。検証用アーカイブでの成功を、実GitHubからの導入成功として扱いません。公開後は実GitHubから導入し、`source-info.json`のリポジトリ・ブランチ・コミット、配置済みexeと登録先を照合してください。

共通指示の登録では、明示オプションなしの不変更、既存AGENTSの保持、配置済みexe・設定のbinding、既知の旧MCP優先ブロックとguideハッシュに一致する移行、冪等な登録と解除、利用者編集の保護、登録途中の失敗時の復旧を隔離したCodex homeで確認します。旧配置済みPowerShell backendの退役では、製品バックアップとCoreによるWindowsゴミ箱への削除を照合します。実ユーザーの共通AGENTS本文はこのE2Eで変更しません。実登録後は、専用guide・管理マーカー・bindingの保存内容、新しいチャットでの読込、最初からCMD CLIが選ばれた実動作を分けて確認してください。

## 一時的なロックとロード中DLL

60秒超の共通ロック待機と解放後の続行、待機中の元対象・レジストリsnapshot保全を確認する。CLIのstderr通知とstdout JSON、MCPのtoken付き進捗と最終応答後の通知抑止を確認する。固定ロックを削除して競合を回避しない。

使用中DLL・ファイルの拒否では、元対象の内容・ACL・属性を変えず、永久削除・コピーfallback・利用プロセス停止をしないことを確認する。`ambiguous`の同じ削除を再送せず、元対象とWindowsゴミ箱を照合する。

## 削除性能の比較

変更前exeと同じ対象・条件で複数回測定し、試行値・中央値と内容・IDの保持を確認する。旧コピー方式の性能を新経路の値として流用しない。大量対象も同じrecordless経路で検証し、復元操作はWindowsゴミ箱の今回fixtureへ限定する。

## 復元データの自動整理

レジストリschema 5だけの期限・容量・purge・maintain、事前容量走査・整理前後走査・単一超過時の予算・破損保全を確認する。Windowsゴミ箱の新ファイルと移行待ち旧ファイルは予算に含めず、通常保守で旧rootを探索しない。

起動時保守の性能は、旧ファイル数を増やしてもレジストリ専用namespaceの走査へ限定されることを計測する。明示移行時間と定常保守時間を分け、CLIの計測を実ログオン全体の改善と混同しない。通常容量走査と`--audit-records`による完全監査を区別する。

## 検証後の保持と清掃

結果と再現方法は会話内へ残し、再検証に必要なJSON・入力・ログだけを外部作業領域へ保持する。今回のfixtureだけを対象として、利用中プロセス・リンク・混在を確認してからPrunletで清掃する。ゴミ箱全体を空にせず、旧領域や不明な残存データを手動削除しない。保全対象・未清掃パス・理由・再開条件を報告する。
