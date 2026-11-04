# E2E検証

Windows・`rust-toolchain.toml`指定のRust（MSVC）・C++ビルドツールとWindows SDK・PowerShell 7で実行する。ビルドは`scripts/Publish-Prunlet.ps1`へ外部の絶対出力先を渡す。Cargoのtarget・TEMP/TMP・metadata・fixture・reportも未使用の外部D絶対パスへ隔離し、reportの親を先に作る。Macのnative検証は[macOSの手順](macos.md)を参照する。

各検証ではCLI・stdio MCP・hookの実プロセス、終了コード・stdout JSON・`passed`/`failed`を読む。skip・CaseFilter・準備だけの成功を全件合格にせず、権限・KTM・view・実offlineなど未検証の環境条件を明記する。今回の変更による結果と過去版の結果を混同しない。

Rust候補の内部境界は、`scripts/Publish-Prunlet.ps1 -OutputDirectory <外部絶対パス> -IncludeVerificationProbe`で製品と同じrelease設定から作るtest実行ファイルを使う。出力は`publish/prunlet.exe`・`verification/prunlet-libtest.exe`・`build-manifest.json`である。ファイル検証には`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`を渡し、全コンパイル入力とCargo設定、製品・probeの対応を固定する。`#[cfg(test)]`限定probeは出荷しない。旧C#候補用の`-AssemblyPath`と混在させず、probeの境界試験・通常tokenの6801拒否保全・明示native tokenでのCLI/MCP往復を別々に判定する。真正な旧版exeは既存データのproducerとして利用できるが、新しい候補の代用にはしない。

保存先を利用者が明示した場合は、通常のファイル削除fixtureだけを`-FixtureRoot <既存のNTFS絶対ディレクトリ>`へ分離できる。`Verify-RecordlessFiles.ps1`、`Verify-RegistryRecovery.ps1`、`Verify-LatestInstall.ps1`と、native sessionのPrepareが対応する。ビルド・TEMP/TMP・report・復元metadataは引き続き外部Dへ置く。共通helperは通常のdrive絶対パス、非reparse、リポジトリ/Codex home外、作成前後のvolume GUIDを確認し、一意な子ディレクトリだけを使う。

通常のゴミ箱往復にはゴミ箱が有効なボリュームを指定する。即時削除設定のDで`recycled`の期待値を永久削除へ緩和しない。Recordlessの即時削除とボリューム不一致の専用ケースはhost Dに維持する。巨大ファイルの並行検証は実Shell通知2回を要求し、Coreの既知baseline通知は対象境界を検証して区別する。

公開HEADを確認する`Verify-LatestInstall.ps1 -CheckPublicHead`は、必要なら`-UseGitHubCliAuthentication`を明示する。既存のログイン済み`gh`による同じGitHub APIの読取りを検証し、未認証経路の成功とは区別してreportへ記録する。gh欠如・非0終了・不正JSONは元データを変更せず停止する。トークン取得やCLIの自動導入・ログインは行わない。

## 通常E2Eの検証範囲

shell前のproducer手順は`tests/hook_remote_input.rs`で、`PRUNLET_HOOK_EXE`へ検証する配置済みCLIの絶対パスを固定して確認する。Cargo target・TEMP/TMPを外部Dへ分け、同じRust/MSVC/static CRT設定で`cargo test --test hook_remote_input --locked --release --target x86_64-pc-windows-msvc --target-dir <外部D> -- --ignored --nocapture --test-threads=1`を実行する。5テスト全件と終了コード0を確認する。歴史上拒否された原文はdenyを維持し、全文のUTF-16LE変換結果と原文のroundtrip、生成canonicalの通過、encoded本文内の直接削除拒否、明示shellとmetadataの従来動作を確認する。既存`hook-posix.json`のWindows期待値と必要なCMD/PowerShell期待値もJSONだけで再利用する。元コマンドは実行せず、実CLIのhook stdinへJSONとして渡す。旧PowerShell検証helperは実行しない。

Codex実ホストでは、shell前に生成した無害なliteral markerのcanonicalだけを実行し、実PowerShellのCommandLineが生成したEncodedCommandと一致することと終了コードを別途確認する。元のSSH清掃や危険な回帰fixtureは実行しない。配置済みCLIのhash、hook検査結果、実ホストの実行を区別し、hookによる入力更新には依存しない。

スパースfixtureのC#は`scripts/recordless-e2e/SparseFixture.cs`を共通入力とし、各runnerはこの実ファイルのpathとSHA-256を記録する。旧runnerのhere-stringやAST配置を検証入力として使わない。

新しいファイル経路は、操作記録を作らずWindowsゴミ箱へ移す経路と、予約名の通常ファイル、Windowsのサイズ超過判定後、または対象ボリュームの即時削除設定とゴミ箱利用不可を確認した後に対象名を固定して削除する経路として検証する。旧schema 1〜4/6の復元・圧縮・終了履歴runnerを、新版通常経路の必須成功条件として使わない。旧版exeで作ったデータは下記の明示移行検証だけに使用する。

- 予約名の通常ファイルについてCLI・stdio MCPの永久削除、dry-runの`would_permanently_delete`と不変更、通常名との混合・生存ハードリンク保全を確認する。予約名のディレクトリ・リンク・祖先とdevice構文は拒否し、preflight失敗や実体差し替えで無関係な対象を削除しないことを確認する。
- CLIの単一・複数・Unicode・長いパス・`--paths-file`・空フォルダー・明示再帰とdry-run、MCPの入力型・余剰property・1〜256件上限を実プロセスで確認する。
- ファイル結果が`dryRun`・`items`・`warnings`で、項目が`path`・`kind`・`status`・任意`error`だけを返すことを確認する。`recycled`・`permanently_deleted`・`would_recycle`・`would_permanently_delete`・`already_absent`・`failed`・`ambiguous`と終了コード/MCP `isError`を照合し、operationId・backupPath・hash・sizeを返さないことを確認する。dry-runでは予約名の通常ファイルの永久削除予定と、それ以外のサイズ超過による永久削除を予測できない旨を確認する。
- 実際の容量超過を起こす専用sparse fixtureをCLI・MCPで検証し、ファイル・フォルダーの元名の消失と今回分のゴミ箱項目、混合batch・生存hardlink・部分失敗の扱いを確認する。確認済みの即時削除設定とサイズ超過以外の失敗では永久削除せず、旧既定と設定済みの退避先を保護する。即時削除設定のボリュームは設定を変更せずCLI・MCPで通常サイズのファイルと再帰削除を確認する。Shellの直前とサイズ超過・ゴミ箱利用不可の通知後での差し替え・ロックを別々に確認し、Shellが別実体を移した場合は`ambiguous`を返すこととWindows側の副作用を区別する。
- `Verify-OversizeRaces.ps1`・`Verify-BeforeRecycleRace.ps1`・`Verify-BeforeRecycleSmallRace.ps1`は `-ExecutablePath <候補exe>`・`-RustProbePath <同buildのRust libtest>`・`-BuildManifestPath <manifest.json>`・`-ExpectedBuildManifestSha256 <固定SHA-256>`・`-FixtureRoot <未使用の絶対fixture root>`・`-OutputDirectory <未使用の外部D出力先>`・`-ReportPath <外部JSON>`を渡す。manifestの製品/probe SHAと現在ソースのfingerprintを照合し、実Core/Shell境界を検証する。C# assemblyを候補runtimeへ代用せず、CLI・MCPの実プロセスE2Eとは区別する。差替え後の曖昧結果を成功へ置き換えず、証拠が一致したfixtureだけを所定の経路で清掃する。
- `Verify-LargeOperations.ps1`の通常経路は `Verify-RecordlessFiles.ps1 -Large -LargeFileCount <32769..65535> -CaseFilter '*large-*'`への互換入口で、大量treeのWindows Bin往復1ケースだけを選ぶ。`-ExecutablePath`・`-OutputDirectory`・`-ReportPath`は必須、`-FixtureRoot`と同build probe/manifestの3引数を渡せる。`-LegacyCopyVerification`は旧コピー方式専用の別経路であり、通常Rustの復元検証に使わない。旧producer引数はこの旧経路用で、現在のRecordlessには転送しない。`-ProcessTimeoutSeconds`（Large既定1800秒、60〜86400秒）はRecordlessの実CLI待機へ引き継ぐ。Recordless単独の既定は従来どおり240秒。大量ケースの成功を既定62ケース全体の成功と表記しない。
- `Verify-AccessDeniedFiles.ps1`には同一候補の`-ExecutablePath`・`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`と新しい外部Dの`-OutputDirectory`・`-ReportPath`を渡す。実効ユーザーの即時削除設定を候補Coreで確認できるDボリューム上の新規fixtureを使い、設定自体は変更しない。CLI・MCPの各経路で、共有handleを保持したroot・再帰中の子が削除待ちとなる条件と、ACLで削除前に拒否される条件を別々に確認する。前者は同じ実体・ACLのままWin32 5と削除待ちを観測し、handle解放後の名前消失と`ambiguous`・事後確認の診断を照合する。後者は全preflight失敗時の同一batchの他対象保全と、受理済みと誤表示しないことを確認する。想定外のゴミ箱移動では、照合できたfixtureの保持先を記録する。既存のBin照合はアクセス不能な項目を省略し得るため、一致0件だけで完全な不在を証明しない。不明・拒否のfixtureは自動再送しない。
- 共有ハードリンクのサイズ超過は`Verify-RecordlessFiles.ps1`のCLI・MCPとassembly指定の競合ケースで確認する。`Verify-OversizeMixedHardlinks.ps1`・`Verify-OversizeHardlinkPermissions.ps1`は通常Shellとの混合、単一・同一root・別rootのアクセス権不足を確認する。`Verify-OversizeParallelIndependence.ps1`・`Verify-OversizeRecycledHardlinkIndependence.ps1`は同じ候補のassemblyを使い、独立rootの同時pinと無関係な生存別名への書込みopenを実Shell後のCore境界で確認する。権限不足で部分完了した結果の順序と状態を区別し、不明な削除を再送しない。
- 新規削除前後でPrunlet保存領域を比較し、操作manifest・PIDL・File ID・ACL snapshot・monitor・index・復元stageを作らないことを確認する。固定`maintenance.lock`と操作記録を区別する。通常削除・list・maintainが旧ファイル操作ディレクトリを走査しないことも確認する。
- 内容・File ID・ADS・通常属性・case-sensitiveな名前・ACLと、リンク先の保全・外部ハードリンク別名との共有を確認する。復元は今回fixtureのWindowsゴミ箱項目だけで行い、ゴミ箱全体の空化や既存項目の清掃は行わない。復元先に既存項目を作り、上書きせず競合を扱う。
- preflight失敗時の全対象保全、独立対象の並行完了、同一対象・親子の排他、共有ハードリンク検出時の排他、入力順を確認する。MCPの要求枠とworker枠・進捗分離・EOF後の完了を区別する。競合のないCLIのstderr静穏、MCP数値tokenの型と値・単調な進捗・total不在・stderrとの本文と件数の一致、token省略時の通知なしも確認する。ロード中DLLの拒否時は元の内容・ID・属性・treeを保全し、解放後はWindowsゴミ箱との往復を確認する。
- `restore`/`registry-restore`がファイルを復元せず、MCPの一覧が5ツールで`restore_files`を持たないことを確認する。hookの直接削除拒否・非削除入力通過・配置済みCLI案内・既存ホスト権限を確認する。

`scripts/Verify-RecordlessFiles.ps1 -ExecutablePath <今回のexe> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSONパス>`を実行する。追加オプションは実装済みスクリプトのparamと照合し、未実行のケース数を成功実績として記載しない。

## 旧復元データの明示移行

`scripts/Verify-FileRecordMigration.ps1`へ `-ExecutablePath`・`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`・新しい外部Dの`-OutputDirectory`・`-ReportPath`、必要に応じて既存NTFS fixture親の`-FixtureRoot`（C payload用、新規run子を作る）と、対応する旧runtimeの`-LegacyExecutablePath`（1.0.9）・`-MoveExecutablePath`（1.0.11）・`-BaselineExecutablePath`（1.0.15）を渡す。typed所有markerモデルを含める場合だけ`-FixtureAssemblyPath`（旧互換名`-AssemblyPath`）に固定した.NET補助を渡し、候補runtimeや真正な旧schema producerとは区別して報告する。1.0.9/1.0.11を未改変の当時ソースから復元buildした場合は、それぞれ`-LegacyProducerBuildRecordPath`・`-MoveProducerBuildRecordPath`でsource commit・archive SHA・exe SHAの記録を渡し、配布済みbinaryとは区別する。任意の`-ProducerProvenancePath`では各producerのpath・version・SHAとcheckpointのpath/SHAを固定する。version一致だけで公開binary由来とは判定せず、未確認は`unverified-origin`、source-only公開時の保存buildは`retained-source-only-build`として、旧runtimeによるschema生成の成功と別欄に記録する。旧schemaを新版で捏造せず、旧ファイルの退避root・操作記録が直接Windowsゴミ箱へ移り、sourceが不在になることを確認する。旧形式の展開・bundle・sidecar・保全コピー・復元互換を成功条件へ残さない。schema 6の元ゴミ箱項目は管理をWindowsへ委ね、metadataだけを整理する。

旧central metadata自体が破棄対象になるため、そのボリュームでWindows Binが有効でなければ移行は保全停止する。検証のために既存の即時削除設定を変更しない。Dが即時削除設定の場合は、`-LegacyRecordFixtureRoot <既存Cの専用fixture親>`を明示し、新run子に旧central recordsとowned storeだけを作る。これは削除対象fixture用の`backupDirectory`であり、利用者の通常設定を変えるものではない。設定JSON・通知・TEMP・report・buildはDに残し、`legacyRecordFixtureRun`にC側の実対象境界を記録する。既に拒否・不明になったD側の記録を移動・再送してこの試験へ流用しない。

所有markerとroot layout、他config/privateBaseの保護、registry signal混在、未知の非所有領域、壊れたfile本文の非読取、dry-run不変更、policy未指定stateからversion 2、更新後の中央旧領域非走査と後から現れたowned store回収を検証する。通常delete/list/maintainが旧ファイルrootを探索しないことも確認する。

同じソースfingerprintとbuild manifestに結合したRust libtestの`legacy_discard`入口で、`gate.flushed`・`shell.ready`・`shell.returned`の実migration境界を通知し、所有childだけを止める。Shell直前の変更はnamed eventでそのchildへ継続を通知する。.NET補助で中断した結果をRustの中断証拠にしない。固定gateのFlush後とShell成功直後の停止から、自動再送拒否・registry利用の継続・明示ack後の再評価を確認する。不正gateをackで削除しないこと、dry-runがgateを作らないことを区別する。registry namespace・snapshot・完全ACL・scope・非上書き復元の検証は別途維持する。

macOSの通常artifact・専用cfgのqueue/race・libtest資源検証の入力と判定は[macOSの検証](macos.md#ネイティブ検証の4経路)を参照する。専用cfgの結果で通常releaseの成功を代替しない。

## レジストリの削除と復元

保護アクセスのAPI適合性は`Verify-ProtectedRegistryAccess.ps1 -ExpectedSid <実効SID> -OutputDirectory <新しい外部D絶対パス> -ReportPath <新しい外部DのJSON絶対パス> -AssertNativeWindows`で別に確認できる。実token・privilege復元・固定入力hashを記録し、専用volatile GUIDキーだけでACL拒否、backup/restore open、同一実体のKTM接続、完全security/raw bytesのstage/rollback、外部更新とcommitの競合、missing不作成、リンク拒否を検証する。削除APIを使わない適合性probeであり、Prunlet CLI/MCPの削除・復元E2Eを代替しない。medium tokenで権限がない場合はfixture作成前に停止する。リンクfixtureは再送せず、reportのパスを保持してhive unloadまで残す。

`Verify-ProtectedRegistryViews.ps1`には`-ExecutablePath`・`-ExpectedExecutableSha256`・`-ExpectedSid`・新しい外部Dの`-OutputDirectory`/`-ReportPath`・`-AssertNativeWindows`を渡す。独立したHKLM SOFTWAREの32/64 viewへ異なる生データを置き、CLI/MCPのbackupRestore view 32拒否で両方不変更、view 64削除・復元で32側と対象外の値が不変更になることを確認する。バックアップ／復元オプションではaccess maskとWOW64指定が無視され得るため、単に両viewを同じHKLM SYSTEMキーで試すだけでは分離の証拠にしない。このモードの対応は64bit OS・プロセスのview 64だけである。専用volatile fixtureは両viewとも保持し、拒否後に別方式で清掃しない。

通常のRegistryRecoveryの保護ACLケースは、CLI/MCPの実キー・値往復、完全security/class/raw bytes、既存の空既定値の非上書き、通常方式への自動切替なし、dry-run不変更、要求前後のtoken属性を確認する。native session側の既存キー往復はnormal/backupRestoreを同じ検証本体で実行し、brokerの要求・復元option伝播も確認する。Prepareは新しいnative helperも固定入力へ含める。

新しいexeのCLI・stdio MCP・hookを実プロセスで検証する。fixtureは利用可能なhiveの専用キー配下へ隔離して作成し、hive・view・実行権限をレポートへ記録する。HKCUでKTMを利用できない環境では、許可されたHKLMの専用fixtureで正系を検証し、HKCUの拒否・原データ保全と区別する。レポートと一時物は外部作業領域へ置き、親を事前作成する。終了コード・stdout JSON・`passed`/`failed`を読み、未実行の権限・view・KTMケースを合格扱いしない。

snapshotの公開境界は`scripts/Verify-RegistrySnapshotPublication.ps1 -ExecutablePath <今回のexe> -ExpectedExecutableSha256 <exeのSHA-256> -RustProbePath <同じソースのtest実行ファイル> -ExpectedRustProbeSha256 <probeのSHA-256> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSON絶対パス>`で確認する。容量予約に使ったbytesと公開本文・owner長/hashの一致、private ACL、中断後のprefix再開、改変prefixの拒否と保全を検証する。これはmetadata fixtureによる保存境界の検証であり、実レジストリのtransaction・完全ACL・native session往復を代替しない。

- CLIのview欠落・重複・不正・未知引数・複数キー、MCPの余剰property・型不正を拒否する。値名はliteralで、空の既定値名（CLIの`--value-name=`を含む）と値+再帰拒否を確認する。
- キー・値・既定値・未知の型を含むuint型番号と生バイト列・Unicode名を往復し、キーごとのOwner/Group/DACL/SACLとMandatory Labelを含む生のセキュリティ記述子を完全一致で比較する。値復元で親ACLが変わらないことを確認する。
- 実在のMuiCacheを使わず、GUID fixtureへ6種類のパス形状の値名を作成する。CLI・MCPで名前をliteralのまま削除・復元し、型・生bytes・親の完全ACL・他の値の保持と、同名値が復元先にある場合の拒否・snapshot保全を確認する。コロン付きキー名は`C:#Program Files#Norton#Suite#NortonSvc.exe`と既存の`#`・`%5C`形状を往復する。
- 実効ユーザーの正規`Software\Classes`別名は、OSが解決する実体とREG_LINK bytesを照合したうえで、削除・復元と同じKTM transactionへ同一bytesの書込みをstageして保護する。`Software\Classes\PrunletE2E_<run GUID>`だけをfixtureにし、CLI・MCPの6種類の値名と直接のClasses子キーを32/64両viewで削除・復元する。型・生bytes・兄弟・完全ACLと直接`SID_Classes` backingを照合し、既存復元先の競合・snapshot保全を確認する。共有viewでの両view実行をview分離の証拠にしない。
- 実別名のREG_LINK bytes・完全ACLは正常往復の前後で一致させ、dry-runは最終書込み時刻と復元metadataも不変更とする。dry-runは書込み権限を検査するが同一bytes書込みをstageしない。実在のMuiCacheやその値は使わず、今回のCLIでGUID fixtureだけを清掃し、残存は`cleanup.remainingClassesPath`へ記録する。
- `-RustProbePath`指定時は本番のClasses別名検証・guardを専用volatileリンクで検証する。通常キーの一致するREG_LINK bytesを拒否し、実リンクの解決、権限検査だけではbytes・時刻不変更、SetValue拒否時にstage前停止を確認する。同一bytesのstageと対象値の変更を同じtransactionへ入れ、最終`VerifyPinnedNames`後にfixtureリンクを外部writerで更新して、再確認を挟まない実KTM commitの拒否・対象値のrollback・受理済み外部bytesの保全を要求する。結果・native error・候補exe・probe SHAを`classes-guard-evidence.json`へ保存する。実OSのClasses別名の宛先差し替えは行わない。
- 同じCore境界ケースで、最終確認後に専用リンクを`NtRenameKey`し、受理時は元の名前へ別の実リンクを作る。renameのtransaction conflict拒否、またはcommit拒否と対象値rollbackを要求し、rename元・置換リンクのbytesを保全する。native errorと候補exe・probe SHAを`classes-rename-evidence.json`へ保存する。
- 通常リンクの拒否は通常fixtureとは別の`<run GUID>-link-probes` volatile rootで行う。fixture内だけを向く実リンクを対象とする要求・リンクを祖先に持つ要求、および通常キーの`SymbolicLinkValue`（REG_LINK）をdry-runで拒否し、リンク先を保持する。拒否されたリンクへ清掃APIを付け替えず、`cleanup.retainedVolatileLinkPath`へ残存を記録してログオフまたは再起動まで保持する。preflight後のリンク差し替えはこのケースで検証済みとしない。
- `core-incomplete-links-cannot-be-used-as-ordinary-keys`では、REG_LINK値をまだ持たない実リンクと、値を設定した後の同じリンクを、`OpenOrdinaryKey`で拒否する。未完成リンクのCLI応答は`already_absent`ではなく`failed`とする。保持rawリンクを親とする子のopenも`OBJ_DONT_REPARSE`により4395で停止し、通常キーの受理と対象の値・完全ACLの不変更を確認する。検証済みの通常handleを後続処理に使い、別handleの名前一致を古いraw実体へ転用しない。
- SACL実体がない子キーにも`SE_SACL_AUTO_INHERITED`だけがある階層を含め、ACLの不在・null・空を区別して制御フラグを完全一致で比較する。フラグ欠落を比較除外で回避しない。
- schema 5のpending・snapshot・metadata・ロックと操作ディレクトリが作成時から現在のユーザーSIDとSYSTEMだけのprotected DACL・現在ユーザーOwnerを持つこと、ACL改変時は読取り・復元・整理を拒否してデータを保持することを確認する。未知schemaの保全と、レジストリ専用namespace・保持制御を検証する。
- `SeSecurityPrivilege`不足・KTM非対応・レジストリリンク等はcommit前に停止する。未知のschema・metadataや検証できない復元記録は復元・整理を拒否して保全する。完全ACLを取得できる実行環境と、権限不足を期待する環境を分ける。自動昇格はしない。
- 既存キー・値・空の既定値への復元は競合となり、データを上書きしない。Owner/SACL・Mandatory Labelの適用失敗はrollbackして退避を保持する。commit後receipt未確定の不明状態は自動整理・復元を拒否してpayloadを保全する。
- 削除stage後に別の非トランザクションwriterが値やACLを更新する競合を確認し、受理された外部データがcommit失敗後も残ることを照合する。値復元もstage後の既存値検出・外部writer競合で上書きせず、snapshotを保全する。
- CLIの`restore`と`registry-restore`、MCPの`restore_registry`がレジストリ専用であること、ファイルIDの拒否、レジストリだけの7日・1 GiB予算と整理前後走査を確認する。
- hookはレジストリ対象の`Remove-Item`・alias、`Remove-ItemProperty`・`rp`、`reg[.exe] delete`とwrapper・escapeを拒否する。`reg query`とechoの無関係な文字列は通過し、拒否応答に配置済みCLI/config・view・registry-restore・operationId保持があることを確認する。

最終書込み時刻・volatile寿命等の全状態保持を検証済みと扱わない。Codex実ホストでのフック読込み・共通guide選択・承認は、プロセスE2Eと分けて確認する。

明示native sessionでは、Codex側の通常CLI・MCPを実際に起動して同じnative scopeの値を削除・復元する。通常clientと専用の管理者clientの結果を分け、セッションの実際の起動tokenも記録する。同じSIDでも別ログオン識別子からの接続は拒否する。管理者セッションでの検証を通常tokenで起動したセッションの検証に数えない。通常clientの完全ACL権限不足は正常往復の成功に数えない。RPC後の`kind`、`allowedRoots:null`とvolumeパスのslash・末尾区切りを含む設定照合、期限切れ・未接続・capability/peer/scope/config改変、scope欠落の旧記録、接続断後のoperationId照合、60秒超の共通ロック待機とMCP進捗を確認する。元のMSIX仮想viewをnativeの同名キーと同一視せず、清掃不能なprivate fixtureを新規作成しない。

再現用の`scripts/Verify-RegistrySession.ps1`は、`-Mode Prepare -ExecutablePath <今回のexe> -RustProbePath <同じソースのtest実行ファイル> -MoveExecutablePath <真正なschema 4旧版exe> -LegacyRegistryExecutablePath <真正なschema 5旧版exe> -LatestRegistryExecutablePath <真正なC# 1.0.29 exe> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSONパス>`で固定したscopeと入力を準備する。Rust候補のStart・Runにはprobeと真正なschema 4・schema 5・最新C#版の4依存を必須とし、欠落はUACやnative起動前に拒否する。Currentだけを確認するPrepareでは任意指定を維持する。同じexe・出力先・レポートを指定した`-Mode Start -AssertNativeWindows`でdesktop Explorer経由の通常用・管理者用helperを非表示起動する。UACが表示された場合だけ利用者が同意し、同意を代行しない。実token・ログオンID・exe・作成時刻・期限・scope・設定を照合してStartを確定し、入力hashとread handle・claim/permit・nonce・親の生存を確認してRunへ渡す。Run permit前にはfixtureを作成せず、二重Start/Run・改変・期限切れ・取消・親終了・遅延起動を拒否する。UACの実際の取消と記録による境界検証は区別する。

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

GitHub応答を検証用アーカイブへ差し替え、実際のインストーラー・Rustビルド・配置・Codex登録を通すE2Eです。最新HEADの再解決、同一SHAからの導入、クローンに依存しない登録、旧設定の容量を一度だけ1 GiBへ移すこと、新規設定の移行印、移行後の明示容量と他設定・レジストリ復元データの保持、大小文字を変えた印・容量、設定だけ残る再導入、未知設定の拒否、設定ロック時の保全、制限DACLの保存と登録失敗時の設定バイト列・SDDL復旧、ZIPの不正経路・重複・リンク、取得とビルドの失敗、製品更新の失敗時の復元を検証します。Codex設定がロックされて登録が途中で失敗した場合の復旧と、旧`allowedRoots`内外にある作業場所での導入も確認します。実ユーザーの配置先・Codex設定は使いません。設定検証が`validate-config`で走査・変更せず、全登録・旧backend退役後に明示移行することを確認します。移行開始後の失敗は旧binaryへrollbackせず新exe・設定・登録を保全し、同じCLIで再開できることを確認します。

起動時更新では、旧MCPが応答中の延期と終了後の切替、独立hookの応答、標準入出力とEOF、複数起動の排他、取得失敗時の旧版利用、切替・登録・移行途中からの再開を確認します。 配布と同じZIPから複数回更新し、補助製品の変更・据置・再変更、旧slotの実体再利用、schema 5記録の不変更を確認します。容量検査はファイルとディレクトリのADS、stateの一時出力を含め、上限拒否時に元データを変えないことを確認します。改変した登録・不正state・互換性を確認できない候補は保持して停止し、不明な清掃を自動再送しないことを確認します。隔離fixtureでの成功と、公開後の実ホストでの読み込み・hook信頼は区別します。

`Verify-RustStartupUpdate.ps1`は、既定のGitHub経路と`-DistributionSource r2`を別々の未使用出力先で実行します。GitHub経路では既存5/7引数と真正な旧CLIによるstage再開を維持します。R2経路では固定URL・明示runtime・選択先の記録と同じstageの再開を確認し、R2専用stageを旧CLIで再準備する操作は拒否・保全として区別します。事前配置したZIPのcache再利用による成功はR2への実通信成功に数えず、取得先選択・redirect拒否・長さ/hash不一致・通信失敗後の再送抑止を別の境界検証で確認します。

launcher世代をまたぐ再開は`Verify-PreparedDistributionResume.ps1`へcurrent・legacy両ZIPと旧launcherの絶対パス・期待SHA-256（`-CurrentPackagePath`・`-ExpectedCurrentPackageSha256`・`-LegacyPackagePath`・`-ExpectedLegacyPackageSha256`・`-LegacyLauncherPath`・`-ExpectedLegacyLauncherSha256`）、未使用の`-OutputDirectory`・`-ReportPath`を渡して確認します。旧launcherの検証済みコピーにタイミング用checkpointを一か所だけ加え、事前検査後に実MCPが起動して切替が延期される条件を再現します。元本と派生版のSHA・差分を記録し、新launcherが元の配布先とsource-infoのbytesを保って完了することを検査します。GitHubの回答と系譜はfixtureで、本番公開・実際のGit系譜・無変更の旧launcherだけによる再現と区別します。

R2 publisherの正本はRust製`prunlet-release`です。固定したソース・commit・runtime・build provenanceから`package`で作成した実物ZIPを、`verify`で全12 payload・PE/version・ソース・publish出力と照合します。公開用buildは`--release-source true`を明示し、その前後にGit HEADと全製品入力の一致を確認します。`package`・`verify`・`publish-r2`でも同梱scripts・integrationを含む製品入力のHEAD一致とdirty・untracked・ignoredの拒否を必須とし、GitHub添付の直前に`verify`を再実行します。製品3本のAuthenticodeは実物handleを固定したWinVerifyTrustで確認し、NotSignedまたはValidを許容して無効な署名を拒否します。公開工程では`publish-r2`が同じZIPを再検証し、非上書きPUTまたは既存objectの全bytes照合を経て、公開URLの全bytes・長さ・SHA-256を確認します。その成功後だけ同じZIPをGitHub Releaseへ添付し、GitHubのdigest・sizeを照合します。引数・資格情報・確認順序は[配布の設定](distribution.md#rust製リリースcli)、実行経路は[release workflow](../.github/workflows/prunlet-release-package.yml)を参照してください。旧.NET HttpClientの模擬handlerによるSigV4・通信失敗・秘密非出力のfixture結果は、新しいWinHTTP providerの検証結果に含めません。新WinHTTP provider向けの障害条件fixtureは未整備です。実公開時の成功は未実行の障害条件検証を代替しません。

定期整理はTask Scheduler境界を隔離して、毎日03:00と現在のユーザーのログオンの両トリガー、有効状態、`StartWhenAvailable`、電池使用時の実行許可、既存タスク設定の保持をXMLで検証します。PCの電源断・スリープ・ログオフを伴う取り逃し回復の実動作は、この検証の対象外です。

非表示起動は`scripts/Verify-MaintenanceTask.ps1 -ExecutablePath <今回のCLI exe> -OutputDirectory <新しい外部D作業領域> -ReportPath <外部JSONレポート>`で、実Task Schedulerと保守専用exeを検証します。同じpublishフォルダーに`prunlet-maintenance.exe`が必要です。CLIのconsole subsystemと保守exeのGUI subsystem、旧タスクからの設定を保つ移行、保守以外のコマンドの拒否、期限切れ整理・保持対象の復元、失敗終了コード、所有者検証を確認します。`-PauseForWindowInspection`は旧・新タスクを専用lockで待機させ、別途ウィンドウを観測するための指定です。配置後も同じ登録タスクを手動起動して表示と終了コードを確認し、実際のWindows再起動と区別します。

`-CheckPublicHead`では実際のGitHubも参照します。リモートに必要な実装がまだない場合は、配置先を変更せず停止することを確認します。検証用アーカイブでの成功を、実GitHubからの導入成功として扱いません。公開後は実GitHubから導入し、`source-info.json`のリポジトリ・ブランチ・コミット、配置済みexeと登録先を照合してください。

共通指示の登録では、明示オプションなしの不変更、既存AGENTSの保持、配置済みexe・設定のbinding、既知の旧MCP優先ブロックとguideハッシュに一致する移行、冪等な登録と解除、利用者編集の保護、登録途中の失敗時の復旧を隔離したCodex homeで確認します。旧配置済みPowerShell backendの退役では、製品バックアップとCoreによるWindowsゴミ箱への削除を照合します。実ユーザーの共通AGENTS本文はこのE2Eで変更しません。実登録後は、専用guide・管理マーカー・bindingの保存内容、新しいチャットでの読込、最初からCMD CLIが選ばれた実動作を分けて確認してください。

### Windows managed MCPの世代切替

世代cache回収の変更では`mcp-cache-maintain`のdry-run不変更と`--apply`を隔離fixtureで確認し、現在世代・使用中proxy/queue worker・未知項目の保持、pending/retiredの`retained`と非再送、同じCoreSnapshotの全ID照合と内部GenerationCleanupPermitの限定適用、通常CLI/MCPによるcache・他metadataの保護、Coreゴミ箱経路、2 GiB上限時の新規割当停止と既存の検証済み世代の通常要求継続を確認する。固定private空gate `.prunlet-mcp-cleanup-in-progress`の削除前create-new・flush、元の正確な1対象の`recycled`/`permanently_deleted`時だけのgate解除、Err・`failed`・`ambiguous`・中断でのgate保持と残候補停止も確認する。既存gateではapply全停止・`cleanupBlocked`非zero終了・dry-runの`retained`、同hash世代の非再送、過去pending/retired領域の保持を確認する。CLI専用`--ack-interrupted-cleanup`ではowned cacheとprivate・空・単一hard link・ADSなしのgate、同名同実体のpinと同handle解除、gate以外の不変更を確認する。`--apply`併用拒否、ack単独の世代不削除、別applyによる回収、MCP・installer・通常起動の暗黙ack不在、不正gateの保全も確認する。これらのgate caseとnative E2Eは実行結果を別途確認し、未実行を成功としない。世代切替driverの成功だけで代替しない。

`scripts/Verify-SeamlessMcp.ps1 -ExecutablePath <今回のexe絶対パス> -PriorPackagePath <新ABI互換の別ビルド世代ZIP絶対パス> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSON絶対パス>`を実行する。reportの親を事前作成する。`mcpProxy2`・`mcpBackendLease1`互換な2つの正規ビルド世代を用意し、同じsource・versionから別の`SourceCommit`を指定してPE出自を区別するfixtureとして使う。公開旧版との互換検証とは区別し、ZIPの生成元・hash・build manifestを呼出し側で確認する。同一stdio接続での世代変更、installer mutex中の応答延期、旧queue workerの保持と新世代からのstatus/cancel、shadow・所有markerの改ざんとjunctionの拒否・対象保全を確認する。終了コードと外部JSONのpassed/failed、保持fixtureを読む。

このdriverは新ABI互換の2世代で切替を検証する。installerや配布package全体の更新、公開旧版との互換検証を代替しない。proxy hard kill後のbackend read lease保持は新caseの実行結果で別途確認し、未実行を成功としない。mutex中の無応答は応答延期の観測であり、backend未実行を直接観測するものではない。送信済要求の子異常終了時の非再送、inflight drainには決定的な停止用seamでの追加検証が必要で、競合するkill試行で合格にしない。queue寿命・並列要求・保持・ACL攻撃競合は専用driverと区別する。Codex実ホストの初回再接続と継続接続は別途確認し、アプリ再起動不要をこのdriverだけで保証しない。

## 一時的なロックとロード中DLL

`scripts/Verify-HardlinkEntryTimes.ps1`で、ハードリンクの列挙時刻が古い場合のCLI/MCP削除と外部別名の保全、全兄弟の基準捕捉後に後続の子を更新した場合の停止を確認する。多数の入力rootが同じ少数の実体を共有するケースでは、CLI・MCPそれぞれ256入力と外部1400別名を使い、自己削除のinspection解放に伴う時刻更新を外部変更と誤判定しないこと、外部別名のID・ACL・属性・全streamを保持することも確認する。`-FixtureRoot`は通常検証と同じ外部fixture境界で検証し、ビルド・metadata・JSON・reportはDに置く。差し替え試行が共有違反で阻止された場合は元内容の保全と削除の正常完了を確認し、別IDの拒否と診断値はCore境界で別に検査する。エラー内の子の絶対パス、列挙値・基準値・実測値・期待変更時刻も検査する。Core境界には候補assemblyとSHA-256を明示し、CLI/MCPの実プロセス結果と区別する。

60秒超の共通ロック待機と解放後の続行、待機中の元対象・レジストリsnapshot保全を確認する。CLIのstderr通知とstdout JSON、MCPのtoken付き進捗と最終応答後の通知抑止を確認する。固定ロックを削除して競合を回避しない。

使用中DLL・ファイルの拒否では、元対象の内容・ACL・属性を変えず、永久削除・コピーfallback・利用プロセス停止をしないことを確認する。通常ファイルの保持元はRestart Manager、CLI/MCPのロード済みDLL保持元はモジュール照会により、`error`に保持元PIDとファイルパスが返ることも確認する。`ambiguous`の同じ削除を再送せず、元対象とWindowsゴミ箱を照合する。

明示キューはCLIの`delete-queue`・`delete-queue-status`・`delete-queue-cancel`と、stdio MCPの既存`delete_files`のenqueue・status・cancelを実プロセスで確認する。共有・ロック違反中の保全と解放後の一度だけの削除、`pending`の取消と開始後の取消拒否、完了結果の1時間保持と失効、worker上限8件（完了保持中を含む）・256パス・照合対象4096項目・IPC入力1 MiBの上限、親や対象の差し替え、再帰範囲の追加・削除での中止を確認する。待機期限は設けない。削除開始後の失敗・不明結果とworker消失・IPC切断を自動再送しないこと、受付後のstdio切断でも継続すること、操作記録を作らないこと、通常の同期削除とMCPの5ツールを維持することも確認する。取消要求の受理だけを削除の取消完了やrollbackと判定しない。

## 削除性能の比較

変更前exeと同じ対象・条件で複数回測定し、試行値・中央値と内容・IDの保持を確認する。旧コピー方式の性能を新経路の値として流用しない。大量対象も同じrecordless経路で検証し、復元操作はWindowsゴミ箱の今回fixtureへ限定する。

## 復元データの自動整理

レジストリschema 5だけの期限・容量・purge・maintain、事前容量走査・整理前後走査・単一超過時の予算・破損保全を確認する。Windowsゴミ箱の新ファイルと移行待ち旧ファイルは予算に含めず、通常保守で旧rootを探索しない。

起動時保守の性能は、旧ファイル数を増やしてもレジストリ専用namespaceの走査へ限定されることを計測する。明示移行時間と定常保守時間を分け、CLIの計測を実ログオン全体の改善と混同しない。通常容量走査と`--audit-records`による完全監査を区別する。

## 検証後の保持と清掃

予約名を含む木の明示モードを変更した場合は、Rustの`tests/permanent_reserved_trees.rs`を使う。環境変数`PRUNLET_E2E_EXE`に検証する配置済みCLI、`PRUNLET_E2E_PROBE`に同じ不変更ソースのprobe、`PRUNLET_E2E_MANIFEST`と`PRUNLET_E2E_MANIFEST_SHA256`にbuild manifestと固定SHA-256を指定する。`PRUNLET_E2E_OUTPUT`は未使用の外部D絶対パス、`PRUNLET_E2E_FIXTURE_ROOT`は既存の外部NTFSディレクトリーとし、後者の一意な子だけにfixtureを作る。TEMP/TMPとCargo targetも外部Dへ分ける。

`cargo test --test permanent_reserved_trees --no-run --locked --release --target x86_64-pc-windows-msvc --target-dir <外部DのCargo target>`でrunnerをコンパイルし、同じ引数から`--no-run`を除いて末尾へ`-- permanent_reserved_trees_e2e --exact --ignored --nocapture --test-threads=1`を加えて実行する。対象buildに合わせたCargo設定・静的CRT設定を維持する。runnerはexe・probe・manifest・全製品入力のhashと祖先を固定し、前後照合する。実CLIはRustの`Command`からCMDへ直接渡し、MCPも実プロセスを使う。製品Coreをrunnerから直接呼んで削除しない。`<PRUNLET_E2E_OUTPUT>/report.json`の8件実行・`passed: 8`・`failed: 0`・`completeVerified: true`とプロセス終了コード0を確認する。

8ケースでCLI/MCPの実行、nested予約名のfile/directory、外部junction・hardlinkとADS/ACL/属性の保全、dry-run不変更、通常名のみの木・root種別・保護領域・boolean・queueの拒否、全batch事前検査と4,095項目上限を確認する。同一ソースprobeのCore境界では、書込み・member変更・捕捉後属性変更・親差し替えの変更前停止、深さ65のroot/子・8,192固定handleを超える129 root・4,096 ADSによる全batch不変更を区別して確認する。runnerは失敗・不明を自動再送せずfixtureを保持する。reportの正確な所有パスと残状態を照合し、配置済みCLIで清掃する。通常の記録なしE2E、queue、共通指示の導入検証も必要範囲で実行し、既存の環境失敗や未実行を成功扱いにしない。

結果と再現方法は会話内へ残し、再検証に必要なJSON・入力・ログだけを外部作業領域へ保持する。今回のfixtureだけを対象として、利用中プロセス・リンク・混在を確認してからPrunletで清掃する。ゴミ箱全体を空にせず、旧領域や不明な残存データを手動削除しない。保全対象・未清掃パス・理由・再開条件を報告する。
