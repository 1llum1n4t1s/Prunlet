# E2E検証

CLI・stdio MCP・フックを別プロセスで動かします。新規ファイル操作はWindowsゴミ箱のschema 6、レジストリはschema 5、既存schema 1〜4は復元・整理の互換経路です。終了コードと外部JSONの`passed`・`failed`・`skipped`を読んで判定し、スクリプトの存在や構文検査だけを成功に数えません。

## 通常E2Eの検証範囲

通常入口`scripts/Verify-Prunlet.ps1`は`scripts/Verify-RecycleBin.ps1`へ振り分けます。変更前1.0.9を`-LegacyExecutablePath`、変更前1.0.11を`-MoveExecutablePath`へ渡し、旧schema 1〜3と4のfixtureをそれぞれ生成します。ACL snapshot導入前のschema 6の互換検証では、`Verify-RecycleBin.ps1`へそのexeを`-RecycleLegacyExecutablePath`として渡します。未指定の互換ケースはskipとして残し、新版で旧fixtureを生成しません。

```powershell
$runRoot = Join-Path 'D:\Codex\Prunlet' ('verification-' + [guid]::NewGuid().ToString('N'))
$report = Join-Path 'D:\Codex\TaskArtifacts\Prunlet' ('verification-' + [guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-RecycleBin.ps1 -ExecutablePath <今回のexe絶対パス> -LegacyExecutablePath <変更前1.0.9exe絶対パス> -MoveExecutablePath <変更前1.0.11exe絶対パス> -OutputDirectory $runRoot -ReportPath $report
```

TEMP/TMP・runtime展開・metadata・レポートは外部D絶対パスへ隔離します。`volumeRecoveryDirectories`も同Dの専用baseへ指定し、旧schema 4とschema 6復元stageの両方で本番領域を使いません。中央metadataとbaseは相互に包含させません。Windowsゴミ箱については今回のfixture項目だけを扱い、既存項目を消したりゴミ箱全体を空にしたりしません。

- file・再帰folderを実ゴミ箱へ移し、PIDL・File ID・内容・ACL・ADS・属性を確認してCLIから復元する。ゴミ箱中のDACLはWindows管理とし、snapshot付きschema 6復元後はnative Owner/Group/DACL bytesと全control flagを厳密照合する。protected子・継承・明示Deny・外部hardlink・junctionも照合する。SACLはこの検証の保証範囲に含めない。新規削除は専用payload領域を作らず、復元中だけstageを使う。
- dry-runと不正入力・非recursive folder拒否で元対象・記録・ゴミ箱を変更しない。リンク先を保全し、Unicode・空白・長いパス・予約名の子を確認する。
- file・folderの同名衝突を上書き・マージせず、ゴミ箱項目を残す。復元後は項目を消費し、同一IDの再実行だけを`already_restored`とする。
- receipt・PIDL・SID・ID・未知memberの改変と完了記録欠損を拒否し、ゴミ箱実体を保持する。欠損・曖昧な状態をCLI成功やMCP成功へ変換しない。
- 新schema 6を古い時刻にしてもPrunletのmaintain・purgeが実体を消さず、旧保持予算から除外する。schema 1〜4のrestore・purge・maintainを実fixtureで確認する。
- stdio MCPのdelete・conflict・restoreと、hookによる直接削除拒否・CLI案内を確認する。環境制約・対応拒否・正常往復を区別し、未検証範囲をskipや成功で隠さない。
- 子ディレクトリだけが削除共有なしで開かれた状態で、CLI・MCPの共有違反案内と元データ保全を確認する。ハンドル解放後の明示削除、復元先の衝突拒否、正常復元まで実プロセスで照合する。
- ゴミ箱の実体を外部hardlinkからACL変更した場合は復元を拒否し、変更後のACLと実体を保全する。snapshotのない旧schema 6は警告付きの互換復元・非上書きを確認する。
- 別プロセスの復元をstage到着時・ready永続化時に中断し、readyなしの不変更拒否とreadyありの衝突保全・再開を確認する。公開済み原本で完了記録を欠落させた検証は実際の中断とは区別し、後発のACL変更を上書きしないことを確認する。

`Verify-RecycleBin.ps1 -Large`は32,769ファイルの再帰rootで全File ID・内容・ACL・非上書き・消費型復元を確認します。`Verify-LargeOperations.ps1`の通常入口もこの経路です。`Verify-Retention.ps1`の通常入口はゴミ箱除外と旧データ保持のケースを選択します。

`Verify-VolumeMoves.ps1`・`Verify-TransientLocks.ps1`は変更前schema 4専用、`Verify-HistoryCompaction.ps1`・`Verify-AutomaticHistory.ps1`と明示`-LegacyCopyVerification`は旧コピー形式の専用fixtureです。`Verify-DeletionPerformance.ps1`の計測定義もschema 4を前提とし、ゴミ箱方式の性能値に流用しません。これら旧生成スクリプトへ新版exeを渡して合格扱いにせず、現行互換性は上記の新版restore・purge・maintainで確認します。

## レジストリの削除と復元

新しいexeのCLI・stdio MCP・hookを実プロセスで検証する。fixtureは利用可能なhiveの専用キー配下へ隔離して作成し、hive・view・実行権限をレポートへ記録する。HKCUでKTMを利用できない環境では、許可されたHKLMの専用fixtureで正系を検証し、HKCUの拒否・原データ保全と区別する。レポートと一時物は外部作業領域へ置き、親を事前作成する。終了コード・stdout JSON・`passed`/`failed`を読み、未実行の権限・view・KTMケースを合格扱いしない。

- CLIのview欠落・重複・不正・未知引数・複数キー、MCPの余剰property・型不正を拒否する。値名はliteralで、空の既定値名（CLIの`--value-name=`を含む）と値+再帰拒否を確認する。
- キー・値・既定値・未知の型を含むuint型番号と生バイト列・Unicode名を往復し、キーごとのOwner/Group/DACL/SACLとMandatory Labelを含む生のセキュリティ記述子を完全一致で比較する。値復元で親ACLが変わらないことを確認する。
- SACL実体がない子キーにも`SE_SACL_AUTO_INHERITED`だけがある階層を含め、ACLの不在・null・空を区別して制御フラグを完全一致で比較する。フラグ欠落を比較除外で回避しない。
- schema 5のpending・snapshot・metadata・ロックと操作ディレクトリが作成時から現在のユーザーSIDとSYSTEMだけのprotected DACL・現在ユーザーOwnerを持つこと、ACL改変時は読取り・復元・整理を拒否してデータを保持することを確認する。未知schemaとファイル・レジストリ混在の保持制御も検証する。
- `SeSecurityPrivilege`不足・KTM非対応・レジストリリンク等はcommit前に停止する。未知のschema・metadataや検証できない復元記録は復元・整理を拒否して保全する。完全ACLを取得できる実行環境と、権限不足を期待する環境を分ける。自動昇格はしない。
- 既存キー・値・空の既定値への復元は競合となり、データを上書きしない。Owner/SACL・Mandatory Labelの適用失敗はrollbackして退避を保持する。commit後receipt未確定の不明状態は自動整理・復元を拒否してpayloadを保全する。
- 削除stage後に別の非トランザクションwriterが値やACLを更新する競合を確認し、受理された外部データがcommit失敗後も残ることを照合する。値復元もstage後の既存値検出・外部writer競合で上書きせず、snapshotを保全する。
- `restore`は共通、`restore_files`と`restore_registry`は型限定であること、既存ファイル・旧schema 1/2/3の互換、7日・1 GiBの合算予算と整理前後走査を確認する。
- hookはレジストリ対象の`Remove-Item`・alias、`Remove-ItemProperty`・`rp`、`reg[.exe] delete`とwrapper・escapeを拒否する。`reg query`とechoの無関係な文字列は通過し、拒否応答に配置済みCLI/config・view・共通restore・operationId保持があることを確認する。

最終書込み時刻・volatile寿命等の全状態保持を検証済みと扱わない。Codex実ホストでのフック読込み・共通guide選択・承認は、プロセスE2Eと分けて確認する。

明示native sessionでは、Codex側の通常CLI・MCPを実際に起動して同じnative scopeの値を削除・復元する。通常clientと専用の管理者clientの結果を分け、セッションの実際の起動tokenも記録する。同じSIDでも別ログオン識別子からの接続は拒否する。管理者セッションでの検証を通常tokenで起動したセッションの検証に数えない。通常clientの完全ACL権限不足は正常往復の成功に数えない。RPC後の`kind`、`allowedRoots:null`とvolumeパスのslash・末尾区切りを含む設定照合、期限切れ・未接続・capability/peer/scope/config改変、scope欠落の旧記録、接続断後のoperationId照合、60秒超の共通ロック待機とMCP進捗を確認する。元のMSIX仮想viewをnativeの同名キーと同一視せず、清掃不能なprivate fixtureを新規作成しない。

再現用の`scripts/Verify-RegistrySession.ps1`は、`-Mode Prepare -ExecutablePath <今回のexe> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSONパス>`で隔離設定と起動入力を準備する。完全な`-Mode Run`では、Prepare時に真正な変更前1.0.11の`-MoveExecutablePath`も渡す。管理者側で既定のHKCU検証とschema 4/5混在の保持制御を実行するためで、Current単独では省略できる。同じexe・出力先・レポートを指定した`-Mode Start -AssertNativeWindows`をCodexから実行すると、desktop Explorer経由で固定した通常用・管理者用スクリプトを非表示起動する。UACが表示された場合だけ利用者が同意する。OSのUAC設定は変更せず、同意を代行しない。両helperとserverの実token・ログオンID・exe・作成時刻・期限・scope・設定を確認してStartを確定し、5分以内のRunへ引き渡す。入力のhashとread handle、原子的なclaim/permit、nonceと親プロセスの生存を検査し、Run permit前にはfixtureを作成しない。入力改変・二重Start/Run・期限切れ・取消・親の終了と遅延起動の拒否も確認する。UAC画面の実際の取消と、期限/取消記録を使う境界検証は区別する。手動desktop起動コマンドは診断互換である。

`-Mode Current`は同じ引数で、既存の仮想SoftwareへのCLI・MCPのdry-run拒否と原本・metadataの不変更、hook subprocessを確認する。新しいprivate fixtureは作成しない。Start後の`-Mode Run`で往復・競合・完全ACL・切断後照合を実行する。fixture作成前に実際のCodex clientと通常セッションのログオンIDも照合し、不一致ならキーを作成せず停止する。通常・管理者でログオンIDが異なる接続は拒否され、サーバーの権限を借りないことも確認する。汎用brokerやタスクは登録しない。

HKCUの修正を完了とするには、同じ対象exeによるcurrent側の6801拒否時の保全と、明示native側のCLI・MCP正常往復の両方を照合する。HKLMの成功、公開の成功、未検証一覧への記録でこの条件を代替しない。

2026-10-24の同じSIDでの比較では、MSIX由来でないnative起動のHKCU専用fixtureはE2E 25成功・0失敗となった。一方、MSIX由来の起動コンテキストでは通常・管理者ともHKCU/Softwareのtransacted openが6801（`ERROR_RM_NOT_ACTIVE`）となり、そのコンテキストで見える既存の正確な8対象名はnative viewで全て不存在だった。この別viewでの不存在は清掃の証拠にしない。8対象はその後、利用者が明示承認した一回限りの例外清掃で、保護付きhive保存・独立再読・直前照合を経て削除し、元の仮想viewで残存0とバックアップ不変を確認した。この例外はCLI/MCPの通常削除の成功に数えず、製品への非transaction fallbackは追加していない。`PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY`の既定0と`ENABLE_PROCESS_TREE=1`は直接起動・brokerの子としての起動とも読取りprobeの84行が同一で、6801は解消しなかった。この仮想view内でtransactionが使えない制約は引き続き拒否し、通常Windowsの操作は利用者が明示選択したnative sessionへ分ける。識別・読取り比較・停止条件は[6801の切分け手順](integration.md#レジストリの6801と起動コンテキスト)に従い、起動コンテキストを混ぜて合格や清掃成功を判定しない。

2026-10-24の明示native session追加後は、Codex通常CLI・MCPの値往復、明示した管理者CLI・MCPのキー往復、class・raw bytes・全階層の完全security bytes一致、権限不足・復元競合・新旧scope不一致・payload改変の拒否、各65秒超のロック待機とMCP進捗を含む27件が成功した。client切断後もserverが1操作だけ安全に完了し、再削除せず記録を照合して復元できた。通常native起動の既存レジストリE2Eは25成功、ファイルE2Eは64成功・3skipとなった。正規長の誤nonceによるHMAC拒否の単独注入とprivate/native同名異値の厳密比較、実タイミングのserver強制終了・電源断、distinct WOW64 viewの分離は未検証であり、これらの成功を主張しない。

## 一時的なロックとロード中DLL

`scripts/Verify-ConcurrentDeletion.ps1`では、共有lockを保持した削除中にも独立したCLI/MCP削除が先に完了すること、同一対象・親子の排他、preflight失敗時の全対象保全、入力順、EOF後の応答完了、token別進捗と最終応答後の通知抑止を確認します。全batchのpreflight完了前にShellを呼ばず、公開済みmanifestを各workerが変更しないことを維持します。通常のゴミ箱E2EでID・内容・ACL・非上書き復元も照合します。

`hardlink-two-aliases-same-batch`は、同じ実体の別名を同一batchで削除し、外部別名とのFile ID共有・内容・ADS・属性・Owner/Group/DACLのnative bytesを維持して復元するケースです。変更前の1件削除・後続ACL拒否は旧exeで反証し、新形式の`hardlinkProtocol:1`とtransition chain・group-readyによる成功と区別します。旧schema 6へ新しい証拠を後付けせず、旧記録の従来経路も別途検証します。選択ケースの成功を既定全件実行の成功としては扱いません。

共有IDの検証は2/3別名、別rootの子を共有するdirectoryと連結成分、同じtree内の別名、CLI/MCPを含めます。全stage移動後・全OGD検証後・単一group-ready後・公開途中の各境界、初期と公開直前の競合、外部別名からのACL改変、transitionの欠落・前hash・原因proofの改変を確認します。group-readyのない既存stageには再開時にACLを再適用せず、group-ready後の公開途中だけが非上書きで再開することを確認します。

低レベルのbyte-lockは専用E2Eに含まれず、別途native APIのprobeで確認します。2026-10-25は外部作業領域の`lock-probe.ps1`で、`GENERIC_READ`・`FILE_SHARE_READ`の別handle・別processから空のfixtureファイルを開き、EOF以降の1 byteへ`LockFileEx`を適用しました。共有同士の取得成功、共有対排他・排他同士の拒否（error 33）、明示`UnlockFileEx`およびprocess強制終了後の取得成功、ファイル長0の維持をprobeで確認済みです。通常終了時の解放はCLI/MCP E2Eで間接確認しています。再現時も本番`maintenance.lock`を使わず、専用の空ファイルで同じaccess・share・lock条件を検査します。

共通ロック待機は60秒超の保持、解放後の続行、CLIのstderr即時通知とstdout JSON、MCPのtoken付き進捗とtokenなし・最終応答後の通知抑止を確認します。

```powershell
pwsh -NoProfile -File .\scripts\Verify-TransientLocks.ps1 -ExecutablePath <今回のexe> -OutputDirectory <新しい外部作業領域> -ReportPath <外部JSONレポート>
```

ロード中DLLはrenameの成否を調べ、成功時は同一ID・内容・属性と消費型復元、拒否時は元対象と属性の保全を確認します。旧コピーの削除保留待機の期待値を新規renameへ当てはめません。Archiveを含まない読み取り専用ファイルも往復後の完全な属性一致を確認します。

## latestインストーラー

更新バックアップも`OutputDirectory\update-backups`へ隔離し、`-UpdateBackupRoot`で実体のパスを渡します。実ユーザーの更新バックアップを検証用の保存先に使いません。

```powershell
$latestRun = Join-Path 'D:\Codex\Prunlet' ('latest-verification-' + [guid]::NewGuid().ToString('N'))
$latestReport = Join-Path 'D:\Codex\TaskArtifacts\Prunlet' ('latest-verification-' + [guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path -Parent $latestReport) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-LatestInstall.ps1 -OutputDirectory $latestRun -ReportPath $latestReport -CheckPublicHead
```

GitHub応答を検証用アーカイブへ差し替え、実際のインストーラー・.NETビルド・配置・Codex登録を通すE2Eです。最新HEADの再解決、同一SHAからの導入、クローンに依存しない登録、旧設定の容量を一度だけ1 GiBへ移すこと、新規設定の移行印、移行後の明示容量と他設定・復元データの保持、大小文字を変えた印・容量、設定だけ残る再導入、未知設定の拒否、設定ロック時の保全、制限DACLの保存と登録失敗時の設定バイト列・SDDL復旧、ZIPの不正経路・重複・リンク、取得とビルドの失敗、製品更新の失敗時の復元を検証します。Codex設定がロックされて登録が途中で失敗した場合の復旧と、旧`allowedRoots`内外にある作業場所での導入も確認します。実ユーザーの配置先・Codex設定は使いません。

定期整理はTask Scheduler境界を隔離して、毎日03:00と現在のユーザーのログオンの両トリガー、有効状態、`StartWhenAvailable`、電池使用時の実行許可、既存タスク設定の保持をXMLで検証します。PCの電源断・スリープ・ログオフを伴う取り逃し回復の実動作は、この検証の対象外です。

非表示起動は`scripts/Verify-MaintenanceTask.ps1 -ExecutablePath <今回のCLI exe> -MoveExecutablePath <変更前1.0.11のexe> -OutputDirectory <新しい外部D作業領域> -ReportPath <外部JSONレポート>`で、実Task Schedulerと保守専用exeを検証します。同じpublishフォルダーに`prunlet-maintenance.exe`が必要です。CLIのconsole subsystemと保守exeのGUI subsystem、旧タスクからの設定を保つ移行、保守以外のコマンドの拒否、期限切れ整理・保持対象の復元、失敗終了コード、所有者検証を確認します。`-PauseForWindowInspection`は旧・新タスクを専用lockで待機させ、別途ウィンドウを観測するための指定です。配置後も同じ登録タスクを手動起動して表示と終了コードを確認し、実際のWindows再起動と区別します。

`-CheckPublicHead`では実際のGitHubも参照します。リモートに必要な実装がまだない場合は、配置先を変更せず停止することを確認します。検証用アーカイブでの成功を、実GitHubからの導入成功として扱いません。公開後は実GitHubから導入し、`source-info.json`のリポジトリ・ブランチ・コミット、配置済みexeと登録先を照合してください。

共通指示の登録では、明示オプションなしの不変更、既存AGENTSの保持、配置済みexe・設定のbinding、既知の旧MCP優先ブロックとguideハッシュに一致する移行、冪等な登録と解除、利用者編集の保護、登録途中の失敗時の復旧を隔離したCodex homeで確認します。旧配置済みPowerShell backendの退役では、製品バックアップとCoreによるバックアップ付き削除を照合します。実ユーザーの共通AGENTS本文はこのE2Eで変更しません。実登録後は、専用guide・管理マーカー・bindingの保存内容、新しいチャットでの読込、最初からCMD CLIが選ばれた実動作を分けて確認してください。

## 大量操作と途中バックアップ

新しい移動形式の大量ツリーは通常E2Eに`-Large`を追加して確認します。出力先・レポートは通常実行と別の未使用絶対パスを指定してください。

```powershell
pwsh -NoProfile -File .\scripts\Verify-LargeOperations.ps1 -ExecutablePath <今回のexe> -LegacyExecutablePath <変更前1.0.9exe> -OutputDirectory <新しい外部作業領域> -ReportPath <外部JSONレポート>
```

rootごとのschema 4記録、事前容量走査、同一File IDの往復、消費型復元を確認します。旧形式の32,768項目・8 MiB超のschema 2/3記録と途中コピー整理は互換専用の対象です。`Verify-LargeOperations.ps1`のコピー前提ケースは、旧exeで生成した記録を新版で復元・整理する検証へ分離し、新版に旧コピーを新規作成させません。

## 削除性能の比較

新方式の速度を報告する場合は、内容・ACL・ADS・属性・File IDの往復、衝突時の非上書き、容量制御を同時に検証し、変更前exeと同条件で複数回比較します。

```powershell
pwsh -NoProfile -File .\scripts\Verify-DeletionPerformance.ps1 -ExecutablePath <今回のexe> -BaselineExecutablePath <変更前のexe> -OutputDirectory <新しい外部作業領域> -ReportPath <外部JSONレポート>
```

移動後のpayloadと旧コピーで構造・復元の消費性が異なるため、旧コピー形式のassertを流用していないことを確認してください。JSONレポートの各試行と中央値を読み、旧コピー方式で得た性能比を新方式の計測結果として引用しません。性能スクリプトの移行や実測が未了なら、その制限を明示します。

### 蓄積済み復元データでの比較

`Verify-DeletionPerformance.ps1 -ExistingRecoveryFileCount 1024 -CaseFilter buffer-boundaries`で、復元データが蓄積した状態の比較も行えます。変更前exeを`-BaselineExecutablePath`へ渡し、旧版ではschema 2を2操作、新版ではschema 2と4を1操作ずつ実生成します。新旧で保持するファイル数・論理容量を揃え、計測前後と復元後にseedの内容・記録が保たれていることを確認します。事前生成によってruntimeとファイルシステムのcacheが温まるため、空の復元領域での結果と区別します。走査・ロック・内容検証を省いた数値を削除全体の性能として扱いません。

## 操作履歴の圧縮

schema 4は当面圧縮対象外で、`compact-history`と自動経路から理由付き`retained`となることを確認します。旧schema 1/2/3の正常purge済みJSONは従来どおり圧縮対象です。次の専用スクリプトは`-LegacyExecutablePath`を必須とし、旧記録の生成だけを旧exe、圧縮・整理・復元を今回のexeで実行します。

- `Verify-HistoryCompaction.ps1`: dry-runの不変更、JSON内容・SHA-256一致、物理容量減少、冪等性、操作ID互換、ロック・リンク・不正metadataの保持。
- `Verify-AutomaticHistory.ps1`: maintainと実削除前の旧履歴圧縮、既圧縮の扱い、保護対象の保持、metadataとpayload容量の分離。
- `Verify-AutomaticHistorySchedule.ps1`: 隔離した一回限りの時刻トリガーによる発火と終了コード、旧履歴の内容一致と物理容量減少。

```powershell
pwsh -NoProfile -File .\scripts\Verify-HistoryCompaction.ps1 -ExecutablePath <今回のexe> -LegacyExecutablePath <変更前1.0.9exe> -OutputDirectory <新しい外部作業領域> -ReportPath <外部JSONレポート>
pwsh -NoProfile -File .\scripts\Verify-AutomaticHistory.ps1 -ExecutablePath <今回のexe> -LegacyExecutablePath <変更前1.0.9exe> -OutputDirectory <別の新しい外部作業領域> -ReportPath <別の外部JSONレポート>
pwsh -NoProfile -File .\scripts\Verify-AutomaticHistorySchedule.ps1 -ExecutablePath <今回のexe> -LegacyExecutablePath <変更前1.0.9exe> -OutputDirectory <さらに別の新しい外部作業領域> -ReportPath <さらに別の外部JSONレポート>
```

実運用タスクの登録・解除や利用者の復元データは検証に使用しません。検証用タスクも固有名・説明・アクションの所有情報を照合して解除します。

## 復元データの自動整理

通常E2Eで新旧合計の容量制御を確認し、保持制御を変更した場合は追加ケースも実行します。

```powershell
pwsh -NoProfile -File .\scripts\Verify-Retention.ps1 -ExecutablePath <今回のexe> -OutputDirectory <新しい外部作業領域> -ReportPath <外部JSONレポート>
```

既定7日・1 GiB、旧設定、期限切れ・容量確保順、単一ファイル・複数入力合計・再帰ツリー・ADSの容量、dry-runの不変更を確認します。通常予算と単一超過時の`max(maxRecoveryBytes, incomingBytes)`、次回削除・maintainの通常上限、既存データが安全に0まで整理できない場合の新規移動拒否を区別します。

既存schema 4と旧schema 1/2/3を混在させ、破損・未知項目・使用中・File IDやreceipt不一致を保全し、容量不明を成功扱いしないこと、整理前後の再走査と共通ロックによる並行削除の容量制御を確認します。`Verify-Retention.ps1`は新方式の保持関連ケースを選択します。`-LegacyCopyVerification`は旧exeの再現専用であり、新版の検証に使いません。定期登録・所有者検証・登録失敗時の復旧はlatestインストーラー検証で確認します。

## 起動時保守の性能

`scripts/Verify-MaintenancePerformance.ps1 -ExecutablePath <今回のexe> -BaselineExecutablePath <変更前1.0.14のexe> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSONレポート>`で、既定8,192ファイルのschema 6記録を作り、同一記録に対する旧版・新版の`maintain --dry-run`を交互に3回計測します。各試行・中央値と、CMDを含むprocess jobのCPU時間を保存します。dry-run時のmetadataと設定の不変更、applyを2回行ってもゴミ箱実体を保つこと、競合時の非上書きと全ファイルの内容・File ID・属性・Owner/Group/DACLの一致を確認します。

性能確認のために安全性検査を省略したり、期限・容量整理を無効にしたりしません。履歴JSONの境界単体の計測、保守CLI全体の計測、配置版の実ログオン負荷は別の結果として扱います。ゴミ箱を空にしても、操作記録・未完了stageや旧方式の退避データが消えたとは扱いません。保持済みの証拠を削除して性能改善に見せず、既存の保全と照合を維持します。
