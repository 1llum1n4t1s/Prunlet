# E2E検証

Windows・Rustup/Cargo・MSVCビルドツール・PowerShell 7で実行する。ビルドは`scripts/Publish-Prunlet.ps1`へ外部の絶対出力先を渡す。CargoのtargetとTEMP/TMPをリポジトリ内へ出力しない。metadata・TEMP/TMP・fixture・reportも未使用の外部絶対パスへ隔離し、reportの親を先に作る。ここでの外部絶対パスは、リポジトリと`~/.codex`（`CODEX_HOME`）の外にある通常のドライブ絶対パスを指し、ドライブ文字は問わない。UNC・デバイスパスは使わない。ゴミ箱往復を確認するfixtureは、ごみ箱が有効（即時削除設定でない）ボリュームに置く。`-FixtureRoot`で指定できる。

検証用のCore境界は`Publish-Prunlet.ps1 -IncludeVerificationProbe`で生成するlibtest専用の`publish/prunlet-verification.exe`を使う。同時に作られる`prunlet_fixtures.dll`と`prunlet-support.exe`は検証専用で、製品ZIPには含めない。製品exeには障害注入の入口を含めない。`build-manifest.json`が同じRust入力・toolchain・環境設定・製品とプローブ・検証用ツールのhashを固定し、実行時にも入力と実物を照合する。CLI・MCPの実プロセス検証とCoreプローブの検証範囲は区別する。

各検証ではCLI・stdio MCP・hookの実プロセス、終了コード・stdout JSON・`passed`/`failed`を読む。skip・CaseFilter・準備だけの成功を全件合格にせず、権限・KTM・view・実offlineなど未検証の環境条件を明記する。今回の変更による結果と過去版の結果を混同しない。

保存先を利用者が明示した場合は、通常のファイル削除fixtureだけを`-FixtureRoot <既存のNTFS絶対ディレクトリ>`へ分離できる。`Verify-RecordlessFiles.ps1`、`Verify-RegistryRecovery.ps1`、`Verify-LatestInstall.ps1`と、native sessionのPrepareが対応する。ビルド・TEMP/TMP・report・復元metadataは引き続きリポジトリ外の外部絶対パスへ置く。共通helperは通常のdrive絶対パス、非reparse、リポジトリ/Codex home外、作成前後のvolume GUIDを確認し、一意な子ディレクトリだけを使う。

通常のゴミ箱往復にはゴミ箱が有効なボリュームを指定する。即時削除設定のボリュームで`recycled`の期待値を永久削除へ緩和しない。Recordlessの即時削除とボリューム不一致の専用ケースは、`-FixtureRoot`の指定にかかわらず出力先（`-OutputDirectory`）のボリュームで実行する。巨大ファイルの並行検証は実Shell通知2回を要求し、Coreの既知baseline通知は対象境界を検証して区別する。

`Verify-LargeOperations.ps1`の既定経路は、現行の`Verify-RecordlessFiles.ps1`の大規模ケースだけを呼ぶ。`-FixtureRoot`でゴミ箱が有効な検証先を渡せる。現行の`-FileCount`は32,769〜65,535件で、通常の全件検証とは区別する。`-ProcessTimeoutSeconds`は従来と同じく既定1,800秒・委譲時の上限3,600秒で、削除CLIの待機へ引き継ぐ。`-LegacyCopyVerification`は廃止され、指定すると拒否する。真正な旧版exeを使う検証は`Verify-FileRecordMigration.ps1`の明示移行に限定する。

公開HEADを確認する`Verify-LatestInstall.ps1 -CheckPublicHead`は、必要なら`-UseGitHubCliAuthentication`を明示する。既存のログイン済み`gh`による同じGitHub APIの読取りを検証し、未認証経路の成功とは区別してreportへ記録する。gh欠如・非0終了・不正JSONは元データを変更せず停止する。トークン取得やCLIの自動導入・ログインは行わない。

## 通常E2Eの検証範囲

Codexセッションの削除失敗を調べる場合は、`<検証ビルドのprunlet-support.exe> scan-failures --days 3 --details`で既定の`~/.codex/sessions`を読み取る。`--root`でログ元、`--until <ISO日時>`で集計終端を固定できる。保存日ではなくイベント時刻を使い、Prunlet呼出し文脈のある非dry-run DTOの`failed`/`ambiguous`を出力イベント内で重複排除する。件数は失敗の観測数であり、証拠の再表示を含み、固有の操作数・不具合数ではない。非DTOの失敗候補と帰属不明DTOは別集計とし、元イベントの照合と隔離fixtureで原因を確かめる。ログ中のコマンドは実行しない。parserの境界は`<検証ビルドのprunlet-support.exe> scan-failures --self-test <未使用の外部絶対ディレクトリ>`で確認する。

フックのshell文字列解析は`scripts/Verify-HookParsing.ps1`に今回のexeと未使用の外部出力先・reportを渡して確認する。Mac向けSSH送信のヒアストリングを含む入力は実行せず、hookプロセスのstdinへJSONとして送り、許可・拒否、stdout/stderr、終了コードとfixture不変更を照合する。Codexの`Bash`とshell欠落、単独EncodedCommandの復号、認識した別名・不正値・外側wrapperの拒否、復号本文の直接削除と解析不能な展開、明示PowerShell、CMD、shell不明を区別する。SSH先での実削除を成功条件へ置き換えない。

スパースfixtureは同一ビルドのRust検証専用DLLを使用し、manifestと実ファイルのhashを照合する。fixtureのAPIは`scripts/SparseFixtures.Common.ps1`から呼び、製品Coreと独立して検証する。

新しいファイル経路は、操作記録を作らずWindowsゴミ箱へ移す経路と、予約名の通常ファイル、Windowsのサイズ超過判定後、または対象ボリュームの即時削除設定とゴミ箱利用不可を確認した後に対象名を固定して削除する経路として検証する。旧schema 1〜4/6のファイル復元・圧縮・終了履歴runnerは廃止した。旧版exeで作ったデータは下記の明示移行検証だけに使用する。

- 予約名の通常ファイルについてCLI・stdio MCPの永久削除、dry-runの`would_permanently_delete`と不変更、通常名との混合・生存ハードリンク保全を確認する。予約名のディレクトリ・リンク・祖先とdevice構文は拒否し、preflight失敗や実体差し替えで無関係な対象を削除しないことを確認する。予約名ディレクトリの拒否ケースでは、すべての不変更確認後に、検証自身が作った既知IDの空・非reparseディレクトリだけを同じ親の未使用通常名へ正規化する。親と元実体を保持した非上書きrenameを使い、ID不一致・移動先既存時の保全、旧名の消失と新名の同一性を確認する。検証用の後始末であり、製品Coreの予約名拒否や削除方式を変更しない。正規化失敗は元の検証エラーと併記して失敗として残す。
- CLIの単一・複数・Unicode・長いパス・`--paths-file`・空フォルダー・明示再帰とdry-run、MCPの入力型・余剰property・1〜256件上限を実プロセスで確認する。
  長いパスのShell短縮名を再現する場合は`Verify-LongPathFiles.ps1 -Phase Prepare -ExecutablePath <今回のexe> -BuildManifestPath <同じビルドのmanifest> -ExpectedBuildManifestSha256 <manifestのSHA-256> -OutputDirectory <未使用の外部絶対パス> -FixtureRoot <未使用の許可済み絶対パス>`を使う。生成された`paths.json`をCLIの`delete --paths-file`へ渡し、dry-runと実削除のstdoutをそれぞれ同出力先の`dry-run.json`・`delete.json`へ保存する。対応する`-Phase VerifyDryRun`・`VerifyDelete`にも同じexe・manifest・hash・出力先・fixture rootを渡し、実終了コードを`-CliExitCode`で渡す。元の完全名と解決後の完全名、既存の親・実体検査を維持し、File IDだけの一致へ緩和しない。検証は同ID・内容の新規ゴミ箱項目と対象外ファイルの保全を照合する。Windowsの`0x80270038`（ゴミ箱のパス深さ制限）は成功にせず、永久削除へ切り替えずに元対象とゴミ箱を確認する。
- ファイル結果が`dryRun`・`items`・`warnings`で、項目が`path`・`kind`・`status`・任意`error`だけを返すことを確認する。`recycled`・`permanently_deleted`・`would_recycle`・`would_permanently_delete`・`already_absent`・`failed`・`ambiguous`と終了コード/MCP `isError`を照合し、operationId・backupPath・hash・sizeを返さないことを確認する。dry-runでは予約名の通常ファイルの永久削除予定と、それ以外のサイズ超過による永久削除を予測できない旨を確認する。
- 実際の容量超過を起こす専用sparse fixtureをCLI・MCPで検証し、ファイル・フォルダーの元名の消失と今回分のゴミ箱項目、混合batch・生存hardlink・部分失敗の扱いを確認する。確認済みの即時削除設定とサイズ超過以外の失敗では永久削除せず、旧既定と設定済みの退避先を保護する。即時削除設定のボリュームは設定を変更せずCLI・MCPで通常サイズのファイルと再帰削除を確認する。Shellの直前とサイズ超過・ゴミ箱利用不可の通知後での差し替え・ロックを別々に確認し、Shellが別実体を移した場合は`ambiguous`を返すこととWindows側の副作用を区別する。
- `Verify-OversizeRaces.ps1`・`Verify-BeforeRecycleRace.ps1`・`Verify-BeforeRecycleSmallRace.ps1`は、同じビルドのexe・Rustプローブ・manifestとそのSHA-256と未使用の外部出力先を受け取る。実ShellとCore内部の境界を再現し、CLI・MCPの実プロセス検証とは区別する。証拠が一致したfixtureだけを清掃候補として残し、指定された経路で清掃する。
- `Verify-AccessDeniedFiles.ps1`には同一候補の`-ExecutablePath`・`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`と新しい外部の`-OutputDirectory`・`-ReportPath`を渡す。実効ユーザーの即時削除設定を候補Coreで確認できる、`-OutputDirectory`が属するボリューム上の新規fixtureを使い、設定自体は変更しない。CLI・MCPの各経路で、共有handleを保持したroot・再帰中の子が削除待ちとなる条件と、ACLで削除前に拒否される条件を別々に確認する。前者は同じ実体・ACLのままWin32 5と削除待ちを観測し、handle解放後の名前消失と`ambiguous`・事後確認の診断を照合する。後者は全preflight失敗時の同一batchの他対象保全と、受理済みと誤表示しないことを確認する。想定外のゴミ箱移動では、照合できたfixtureの保持先を記録する。既存のBin照合はアクセス不能な項目を省略し得るため、一致0件だけで完全な不在を証明しない。不明・拒否のfixtureは自動再送しない。
- 共有ハードリンクのサイズ超過は`Verify-RecordlessFiles.ps1`のCLI・MCPとRustプローブ指定の競合ケースで確認する。`Verify-OversizeMixedHardlinks.ps1`・`Verify-OversizeHardlinkPermissions.ps1`は同一ビルドの`-ExecutablePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`、新しい外部の`-OutputDirectory`・`-ReportPath`と明示`-Execute`を渡し、通常Shellとの混合、単一・同一root・別rootのアクセス権不足を確認する。`-OutputDirectory`が属するボリュームが即時削除設定の場合は、許可済みの通常リサイクル可能なNTFSディレクトリを`-FixtureRoot`へ指定し、metadataとreportは外部に保持する。`Verify-OversizeParallelIndependence.ps1`・`Verify-OversizeRecycledHardlinkIndependence.ps1`は同一ビルドの`-ExecutablePath`・`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`、新しい外部の`-OutputDirectory`・`-ReportPath`と許可済みの通常リサイクル可能な既存NTFSディレクトリ`-FixtureRoot`を使う。実Shellのサイズ超過後、独立rootの同時pinと無関係な生存別名への書込みopenを同一sourceのtest-only Core境界で確認し、CLI・MCPの実プロセス検証とは区別する。権限不足で部分完了した結果の順序と状態を区別し、不明な削除を再送しない。
- 新規削除前後でPrunlet保存領域を比較し、操作manifest・PIDL・File ID・ACL snapshot・monitor・index・復元stageを作らないことを確認する。固定`maintenance.lock`と操作記録を区別する。通常削除・list・maintainが旧ファイル操作ディレクトリを走査しないことも確認する。
- 内容・File ID・ADS・通常属性・case-sensitiveな名前・ACLと、リンク先の保全・外部ハードリンク別名との共有を確認する。復元は今回fixtureのWindowsゴミ箱項目だけで行い、ゴミ箱全体の空化や既存項目の清掃は行わない。復元先に既存項目を作り、上書きせず競合を扱う。
- preflight失敗時の全対象保全、独立対象の並行完了、同一対象・親子の排他、共有ハードリンク検出時の排他、入力順を確認する。MCPの要求枠とworker枠・進捗分離・EOF後の完了を区別する。競合のないCLIのstderr静穏、MCP数値tokenの型と値・単調な進捗・total不在・stderrとの本文と件数の一致、token省略時の通知なしも確認する。ロード中DLLの拒否時は元の内容・ID・属性・treeを保全し、解放後はWindowsゴミ箱との往復を確認する。

並行要求の境界は`scripts/Verify-ConcurrentDeletion.ps1`に同一ビルドの`-ExecutablePath`・`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`と、新しい外部絶対パスの`-OutputDirectory`・`-ReportPath`を渡す。process共通claimの3ケース、MCP token分離、4件の検証エラー後の5件目、および4件のbackend失敗後の5件目を確認する。Coreプローブと実CLI・MCPの範囲を区別し、旧file復元や性能比較を含めない。
- `restore`/`registry-restore`がファイルを復元せず、MCPの一覧が5ツールで`restore_files`を持たないことを確認する。hookの直接削除拒否・非削除入力通過・配置済みCLI案内・既存ホスト権限を確認する。

`scripts/Verify-RecordlessFiles.ps1 -ExecutablePath <今回のexe> -OutputDirectory <未使用の外部絶対パス> -ReportPath <外部JSONパス>`を実行する。追加オプションは実装済みスクリプトのparamと照合し、未実行のケース数を成功実績として記載しない。

## 旧復元データの明示移行

`scripts/Verify-FileRecordMigration.ps1`へ今回のexeと真正な旧版exeを渡す。旧schemaを新版で捏造せず、旧ファイルの退避root・操作記録が直接Windowsゴミ箱へ移り、sourceが不在になることを確認する。旧形式の展開・bundle・sidecar・保全コピー・復元互換を成功条件へ残さない。schema 6の元ゴミ箱項目は管理をWindowsへ委ね、metadataだけを整理する。

所有markerとroot layout（rootはあるがmarkerが無い所有不明storeを警告付きで保持し完了扱いにしないこと）、他config/privateBaseの保護、registry signal混在（gate取得前の検出はdry-run・適用とも`retained`で保持）、未知の非所有領域、壊れたfile本文の非読取、dry-run不変更、policy未指定stateからversion 2、更新後の中央旧領域非走査と後から現れたowned store回収を検証する。通常delete/list/maintainが旧ファイルrootを探索しないことも確認する。

固定gateのFlush後とShell成功直後に子プロセスを止め、自動再送拒否・registry利用の継続・明示ack後の再評価を確認する。不正gateをackで削除しないこと、dry-runがgateを作らないことを区別する。registry namespace・snapshot・完全ACL・scope・非上書き復元の検証は別途維持する。

## レジストリの削除と復元

保護アクセスのAPI適合性は`Verify-ProtectedRegistryAccess.ps1 -ExpectedSid <実効SID> -OutputDirectory <新しい外部絶対パス> -ReportPath <新しい外部JSON絶対パス> -AssertNativeWindows`で別に確認できる。実token・privilege復元・固定入力hashを記録し、専用volatile GUIDキーだけでACL拒否、backup/restore open、同一実体のKTM接続、完全security/raw bytesのstage/rollback、外部更新とcommitの競合、missing不作成、リンク拒否を検証する。削除APIを使わない適合性probeであり、Prunlet CLI/MCPの削除・復元E2Eを代替しない。medium tokenで権限がない場合はfixture作成前に停止する。リンクfixtureは再送せず、reportのパスを保持してhive unloadまで残す。

`Verify-ProtectedRegistryViews.ps1`には`-ExecutablePath`・`-ExpectedExecutableSha256`・`-ExpectedSid`・新しい外部の`-OutputDirectory`/`-ReportPath`・`-AssertNativeWindows`を渡す。独立したHKLM SOFTWAREの32/64 viewへ異なる生データを置き、CLI/MCPのbackupRestore view 32拒否で両方不変更、view 64削除・復元で32側と対象外の値が不変更になることを確認する。バックアップ／復元オプションではaccess maskとWOW64指定が無視され得るため、単に両viewを同じHKLM SYSTEMキーで試すだけでは分離の証拠にしない。このモードの対応は64bit OS・プロセスのview 64だけである。専用volatile fixtureは両viewとも保持し、拒否後に別方式で清掃しない。

通常のRegistryRecoveryの保護ACLケースは、CLI/MCPの実キー・値往復、完全security/class/raw bytes、既存の空既定値の非上書き、通常方式への自動切替なし、dry-run不変更、要求前後のtoken属性を確認する。native session側の既存キー往復はnormal/backupRestoreを同じ検証本体で実行し、brokerの要求・復元option伝播も確認する。Prepareは新しいnative helperも固定入力へ含める。

新しいexeのCLI・stdio MCP・hookを実プロセスで検証する。fixtureは利用可能なhiveの専用キー配下へ隔離して作成し、hive・view・実行権限をレポートへ記録する。HKCUでKTMを利用できない環境では、許可されたHKLMの専用fixtureで正系を検証し、HKCUの拒否・原データ保全と区別する。レポートと一時物は外部作業領域へ置き、親を事前作成する。終了コード・stdout JSON・`passed`/`failed`を読み、未実行の権限・view・KTMケースを合格扱いしない。

snapshotの公開境界は`scripts/Verify-RegistrySnapshotPublication.ps1 -ExecutablePath <今回のexe絶対パス> -ExpectedExecutableSha256 <exeのSHA-256> -RustProbePath <今回のRustプローブ絶対パス> -ExpectedRustProbeSha256 <プローブのSHA-256> -BuildManifestPath <同一ビルドのmanifest絶対パス> -ExpectedBuildManifestSha256 <manifestのSHA-256> -OutputDirectory <未使用の外部絶対パス> -ReportPath <外部JSON絶対パス>`で確認する。容量予約に使ったbytesと公開本文・owner長/hashの一致、private ACL、中断後のprefix再開、改変prefixの拒否と保全を検証する。これはmetadata fixtureによる保存境界の検証であり、実レジストリのtransaction・完全ACL・native session往復を代替しない。

- CLIのview欠落・重複・不正・未知引数・複数キー、MCPの余剰property・型不正を拒否する。値名はliteralで、空の既定値名（CLIの`--value-name=`を含む）と値+再帰拒否を確認する。
- キー・値・既定値・未知の型を含むuint型番号と生バイト列・Unicode名を往復し、キーごとのOwner/Group/DACL/SACLとMandatory Labelを含む生のセキュリティ記述子を完全一致で比較する。値復元で親ACLが変わらないことを確認する。
- 実在のMuiCacheを使わず、GUID fixtureへ6種類のパス形状の値名を作成する。CLI・MCPで名前をliteralのまま削除・復元し、型・生bytes・親の完全ACL・他の値の保持と、同名値が復元先にある場合の拒否・snapshot保全を確認する。コロン付きキー名は`C:#Program Files#Norton#Suite#NortonSvc.exe`と既存の`#`・`%5C`形状を往復する。
- 実効ユーザーの正規`Software\Classes`別名は、OSが解決する実体とREG_LINK bytesを照合したうえで、削除・復元と同じKTM transactionへ同一bytesの書込みをstageして保護する。`Software\Classes\PrunletE2E_<run GUID>`だけをfixtureにし、CLI・MCPの6種類の値名と直接のClasses子キーを32/64両viewで削除・復元する。型・生bytes・兄弟・完全ACLと直接`SID_Classes` backingを照合し、既存復元先の競合・snapshot保全を確認する。共有viewでの両view実行をview分離の証拠にしない。
- 実別名のREG_LINK bytes・完全ACLは正常往復の前後で一致させ、dry-runは最終書込み時刻と復元metadataも不変更とする。dry-runは書込み権限を検査するが同一bytes書込みをstageしない。実在のMuiCacheやその値は使わず、今回のCLIでGUID fixtureだけを清掃し、残存は`cleanup.remainingClassesPath`へ記録する。
- `-RustProbePath`と同一ビルドmanifest指定時は本番の`VerifyClassesAlias`・`GuardClassesAlias`を専用volatileリンクで検証する。通常キーの一致するREG_LINK bytesを拒否し、実リンクの解決、権限検査だけではbytes・時刻不変更、SetValue拒否時にstage前停止を確認する。同一bytesのstageと対象値の変更を同じtransactionへ入れ、最終`VerifyPinnedNames`後にfixtureリンクを外部writerで更新して、再確認を挟まない実KTM commitの拒否・対象値のrollback・受理済み外部bytesの保全を要求する。結果・native error・候補Rustプローブ SHAを`classes-guard-evidence.json`へ保存する。実OSのClasses別名の宛先差し替えは行わない。
- 同じCore境界ケースで、最終確認後に専用リンクを`NtRenameKey`し、受理時は元の名前へ別の実リンクを作る。renameのtransaction conflict拒否、またはcommit拒否と対象値rollbackを要求し、rename元・置換リンクのbytesを保全する。native errorと候補Rustプローブ SHAを`classes-rename-evidence.json`へ保存する。
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

再現用の`scripts/Verify-RegistrySession.ps1`は、`-Mode Prepare -ExecutablePath <今回のexe> -RustProbePath <今回のRustプローブ絶対パス> -BuildManifestPath <同一ビルドのmanifest絶対パス> -ExpectedBuildManifestSha256 <manifestのSHA-256> -MoveExecutablePath <真正なschema 4旧版exe> -LegacyRegistryExecutablePath <真正なschema 5旧版exe> -OutputDirectory <未使用の外部絶対パス> -ReportPath <外部JSONパス>`で固定したscopeと入力を準備する。完全なStart・Runにはこの3依存を必須とし、欠落はUACやnative起動前に拒否する。Currentだけを確認するPrepareでは任意指定を維持する。同じexe・出力先・レポートを指定した`-Mode Start -AssertNativeWindows`でdesktop Explorer経由の通常用・管理者用helperを非表示起動する。UACが表示された場合だけ利用者が同意し、同意を代行しない。実token・ログオンID・exe・作成時刻・期限・scope・設定を照合してStartを確定し、入力hashとread handle・claim/permit・nonce・親の生存を確認してRunへ渡す。Run permit前にはfixtureを作成せず、二重Start/Run・改変・期限切れ・取消・親終了・遅延起動を拒否する。UACの実際の取消と記録による境界検証は区別する。

`-Mode Current`は同じ引数で、既存の仮想SoftwareへのCLI・MCPのdry-run拒否と原本・metadataの不変更、hook subprocessを確認する。新しいprivate fixtureは作成しない。Start後の`-Mode Run`で往復・競合・完全ACL・切断後照合を実行する。fixture作成前に実際のCodex clientと通常セッションのログオンIDも照合し、不一致ならキーを作成せず停止する。通常・管理者でログオンIDが異なる接続は拒否され、サーバーの権限を借りないことも確認する。汎用brokerやタスクは登録しない。

HKCUの修正を完了とするには、同じ対象exeによるcurrent側の6801拒否時の保全と、明示native側のCLI・MCP正常往復の両方を照合する。HKLMの成功、公開の成功、未検証一覧への記録でこの条件を代替しない。

## latestインストーラー

更新バックアップも`OutputDirectory\update-backups`へ隔離し、`-UpdateBackupRoot`で実体のパスを渡します。実ユーザーの更新バックアップを検証用の保存先に使いません。
以下は`-IncludeVerificationProbe`で作成済みのビルド先を`$buildRoot`に指定して実行します。

```powershell
$latestRun = Join-Path '<外部の作業ディレクトリ>' ('latest-verification-' + [guid]::NewGuid().ToString('N'))
$latestReport = Join-Path '<外部のreportディレクトリ>' ('latest-verification-' + [guid]::NewGuid().ToString('N') + '.json')
$exe = Join-Path $buildRoot 'publish\prunlet.exe'
New-Item -ItemType Directory -Path (Split-Path -Parent $latestReport) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-LatestInstall.ps1 -ExecutablePath $exe -OutputDirectory $latestRun -ReportPath $latestReport -CheckPublicHead
```

GitHub応答を検証用アーカイブへ差し替え、実際のインストーラー・Cargoビルド・配置・Codex登録を通すE2Eです。最新HEADの再解決、同一SHAからの導入、クローンに依存しない登録、旧設定の容量を一度だけ1 GiBへ移すこと、新規設定の移行印、移行後の明示容量と他設定・レジストリ復元データの保持、大小文字を変えた印・容量、設定だけ残る再導入、未知設定の拒否、設定ロック時の保全、制限DACLの保存と登録失敗時の設定バイト列・SDDL復旧、ZIPの不正経路・重複・リンク、取得とビルドの失敗、製品更新の失敗時の復元を検証します。Codex設定がロックされて登録が途中で失敗した場合の復旧と、旧`allowedRoots`内外にある作業場所での導入も確認します。実ユーザーの配置先・Codex設定は使いません。設定検証が`validate-config`で走査・変更せず、全登録・旧backend退役後に明示移行することを確認します。移行開始後の失敗は旧binaryへrollbackせず新exe・設定・登録を保全し、同じCLIで再開できることを確認します。

起動時更新では、旧MCPが応答中の延期と終了後の切替、独立hookの応答、標準入出力とEOF、複数起動の排他、取得失敗時の旧版利用、切替・登録・移行途中からの再開を確認します。 配布と同じZIPから複数回更新し、補助製品の変更・据置・再変更、旧slotの実体再利用、schema 5記録の不変更を確認します。容量検査はファイルとディレクトリのADS、stateの一時出力を含め、上限拒否時に元データを変えないことを確認します。改変した登録・不正state・互換性を確認できない候補は保持して停止し、不明な清掃を自動再送しないことを確認します。隔離fixtureでの成功と、公開後の実ホストでの読み込み・hook信頼は区別します。

未適用stageを残した手動導入後の更新準備は、`scripts/Verify-UnappliedStartupStage.ps1 -ExecutablePath <今回のCLI絶対パス> -PublishDirectory <同じビルドのpublish絶対パス> -OutputDirectory <未使用の外部絶対パス> -ReportPath <未使用の外部JSON絶対パス>`で隔離検証します。配布用スクリプトで生成・照合した実ZIPを使い、実CLIのbegin・prepareと、今回のビルドにhash一致する新candidateのCore apply・補助製品適用・統合確認・移行完了を通し、旧製品の既定保持による`cleanup_pending`から次候補の準備へ戻れることを確認します。次候補eは直前候補dとexeが同一で、補助guideだけを変更したZIPです。HTTP取得だけを検証済みZIPと取得完了stateの配置で代替し、実ユーザーのCodex登録・Task Schedulerは変更しません。未署名の旧3製品だけPE overlayを加えた非実行fixtureで変更hashを作り、新旧stageの主stream更新とFile ID保持、slot再利用、準備の反復、state保存後owner更新前からの再開を確認します。未知hashの途中主stream、ADS・リンク・所有marker・未知内容・不整合stateは保持停止し、拒否理由と不変更を確認します。総容量上限は実CLIの追加予約要求で拒否を確認し、実容量超過やHTTPの部分取得再開の検証とは区別します。Coreの統合確認は実ホストの登録済み内容の検証を代替しません。実登録と旧製品の物理清掃を含む複数回の完全更新・実ホスト検証は、この専用検証の対象外です。

定期整理はTask Scheduler境界を隔離して、毎日03:00と現在のユーザーのログオンの両トリガー、有効状態、`StartWhenAvailable`、電池使用時の実行許可、既存タスク設定の保持をXMLで検証します。PCの電源断・スリープ・ログオフを伴う取り逃し回復の実動作は、この検証の対象外です。

非表示起動は`scripts/Verify-MaintenanceTask.ps1 -ExecutablePath <今回のCLI exe> -BuildManifestPath <同じビルドのmanifest> -ExpectedBuildManifestSha256 <manifestのSHA-256> -OutputDirectory <新しい外部作業領域> -ReportPath <外部JSONレポート>`で、実Task Schedulerと保守専用exeを検証します。同じpublishフォルダーに`prunlet-maintenance.exe`が必要です。CLIのconsole subsystemと保守exeのGUI subsystem、旧タスクからの設定を保つ移行、保守以外のコマンドの拒否、期限切れ整理・保持対象の復元、失敗終了コード、所有者検証を確認します。`-PauseForWindowInspection`は旧・新タスクを専用lockで待機させ、別途ウィンドウを観測するための指定です。配置後も同じ登録タスクを手動起動して表示と終了コードを確認し、実際のWindows再起動と区別します。

`-CheckPublicHead`では実際のGitHubも参照します。リモートに必要な実装がまだない場合は、配置先を変更せず停止することを確認します。検証用アーカイブでの成功を、実GitHubからの導入成功として扱いません。公開後は実GitHubから導入し、`source-info.json`のリポジトリ・ブランチ・コミット、配置済みexeと登録先を照合してください。

共通指示の登録では、明示オプションなしの不変更、既存AGENTSの保持、配置済みexe・設定のbinding、既知の旧MCP優先ブロックとguideハッシュに一致する移行、冪等な登録と解除、利用者編集の保護、登録途中の失敗時の復旧を隔離したCodex homeで確認します。旧配置済みPowerShell backendの退役では、製品バックアップとCoreによるWindowsゴミ箱への削除を照合します。実ユーザーの共通AGENTS本文はこのE2Eで変更しません。実登録後は、専用guide・管理マーカー・bindingの保存内容、新しいチャットでの読込、最初からCMD CLIが選ばれた実動作を分けて確認してください。

## 一時的なロックとロード中DLL

`scripts/Verify-HardlinkEntryTimes.ps1`で、ハードリンクの列挙時刻が古い場合のCLI/MCP削除と外部別名の保全、全兄弟の基準捕捉後に後続の子を更新した場合の停止を確認する。多数の入力rootが同じ少数の実体を共有するケースでは、CLI・MCPそれぞれ256入力と外部1400別名を使い、自己削除のinspection解放に伴う時刻更新を外部変更と誤判定しないこと、外部別名のID・ACL・属性・全streamを保持することも確認する。`-FixtureRoot`は通常検証と同じ外部fixture境界で検証し、ビルド・metadata・JSON・reportはリポジトリ外の出力先（`-OutputDirectory`・`-ReportPath`）に置く。差し替え試行が共有違反で阻止された場合は元内容の保全と削除の正常完了を確認し、別IDの拒否と診断値はCore境界で別に検査する。エラー内の子の絶対パス、列挙値・基準値・実測値・期待変更時刻も検査する。Core境界には候補RustプローブとSHA-256を明示し、CLI/MCPの実プロセス結果と区別する。

60秒超の共通ロック待機と解放後の続行、待機中の元対象・レジストリsnapshot保全を確認する。CLIのstderr通知とstdout JSON、MCPのtoken付き進捗と最終応答後の通知抑止を確認する。固定ロックを削除して競合を回避しない。

使用中DLL・ファイルの拒否では、元対象の内容・ACL・属性を変えず、永久削除・コピーfallback・利用プロセス停止をしないことを確認する。通常ファイルの保持元はRestart Manager、CLI/MCPのロード済みDLL保持元はモジュール照会により、`error`に保持元PIDとファイルパスが返ることも確認する。`ambiguous`の同じ削除を再送せず、元対象とWindowsゴミ箱を照合する。

ロード中DLLの検証は、削除前にloaderのモジュール一覧へfixtureの完全パスが現れることを確認する。削除後は元対象・ゴミ箱・操作記録の保全を先に検査し、その後に保持元PID・パスの正の観測を判定する。通常属性のDLLを使う`cli-loaded-dll-held-writable`・`mcp-loaded-dll-held-writable`は、確認済み即時削除設定の出力先ボリュームで固定削除の拒否を再現し、native error 5と`Failure entry`の子ファイル絶対パス、rootのままの結果DTOを確認する。再帰中の失敗は要求rootの`Target`と失敗entryを区別し、保持元診断はそのentryを対象とする。時間上限による未特定を成功へ読み替えない。

case-sensitive属性の準備で通常tokenの`fsutil`が拒否された場合は、新しいfixtureに対して`Verify-RecordlessFiles.ps1 -CaseFilter cli-case-sensitive-directory-preserves-both-names -CaseSensitiveSetupHelperPath <scripts/Enable-VerificationCaseSensitive.ps1の絶対パス>`を明示できる。通常のexe・外部出力・report・許可済みfixture rootの引数も渡す。helperは同じユーザーの管理者tokenで、作成済みの空fixture1個のflagだけを設定し、実体ID・ACL・属性の不変を確認する。UAC表示の有無はOSポリシーに従い、設定は変えない。削除・ゴミ箱照合・復元は元のrunnerの通常tokenで行い、大小文字2名の別IDと内容に加え、Bin内・復元後のcase-sensitive flagも検査する。WSL機能やACLの変更、製品の自動昇格は行わない。

明示キューはCLIの`delete-queue`・`delete-queue-status`・`delete-queue-cancel`と、stdio MCPの既存`delete_files`のenqueue・status・cancelを実プロセスで確認する。共有・ロック違反中の保全と解放後の一度だけの削除、`pending`の取消と開始後の取消拒否、完了結果の1時間保持と失効、worker上限8件（完了保持中を含む）・256パス・照合対象4096項目・IPC入力1 MiBの上限、親や対象の差し替え、再帰範囲の追加・削除での中止を確認する。待機期限は設けない。削除開始後の失敗・不明結果とworker消失・IPC切断を自動再送しないこと、受付後のstdio切断でも継続すること、操作記録を作らないこと、通常の同期削除とMCPの5ツールを維持することも確認する。取消要求の受理だけを削除の取消完了やrollbackと判定しない。

## 削除性能の比較

変更前exeと同じ対象・条件で複数回測定し、試行値・中央値と内容・IDの保持を確認する。旧コピー方式の性能を新経路の値として流用しない。大量対象も同じrecordless経路で検証し、復元操作はWindowsゴミ箱の今回fixtureへ限定する。

## 復元データの自動整理

レジストリschema 5だけの期限・容量・purge・maintain、事前容量走査・整理前後走査・単一超過時の予算・破損保全を確認する。Windowsゴミ箱の新ファイルと移行待ち旧ファイルは予算に含めず、通常保守で旧rootを探索しない。

本人の明示依頼・承認がある場合だけ`scripts/Verify-MaintenancePerformance.ps1`に同一ビルドの`-ExecutablePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`、真正旧版の`-BaselineExecutablePath`、新しい外部の`-OutputDirectory`・`-ReportPath`を渡す。起動時保守の性能は、旧ファイル数を増やしてもレジストリ専用namespaceの走査へ限定されることを計測する。明示移行時間と定常保守時間を分け、CLIの計測を実ログオン全体の改善と混同しない。通常容量走査と`--audit-records`による完全監査を区別する。

## 検証後の保持と清掃

結果と再現方法は会話内へ残し、再検証に必要なJSON・入力・ログだけを外部作業領域へ保持する。今回のfixtureだけを対象として、利用中プロセス・リンク・混在を確認してからPrunletで清掃する。ゴミ箱全体を空にせず、旧領域や不明な残存データを手動削除しない。保全対象・未清掃パス・理由・再開条件を報告する。
## Apple Siliconの検証

macOSの通常ビルドで `Verify-MacRecordlessFiles.py` を実行し、Trash往復、CLI・stdio MCP・hookの終了コード、リンク先、切断後の待機キューを照合する。隔離の `PRUNLET_MACOS_UNIT_TEST_ROOT` を指定し、`cargo test --locked --lib -- --test-threads=1` でMach資源・ディレクトリ境界も確認する。Mach IPCと競合を注入する `Verify-MacQueueIpc.py`・`Verify-MacRaceBoundaries.py` は `RUSTFLAGS='--cfg prunlet_macos_race_tests'` のデバッグビルド専用で、配布用ビルドと分ける。

起動時更新は、上記のデバッグcfgで作成した別バージョン・別コミットのA/B/Cを同じDeveloper IDで署名・公証する。Aの実行ファイルとB/Cの公開形式ZIPを `bun scripts/Verify-MacStartupUpdate.ts <新規の外部ディレクトリ> <Aのexe> <BのZIP> <CのZIP>` に渡す。GitHub応答だけをローカルに置換し、署名・ZIP・stdio・排他・置換は製品の経路で確認する。配布用ビルドにはこの応答置換を含めない。
## Linuxの検証

GitHub ActionsのGitHub提供ランナー（x64は `ubuntu-latest`、ARM64は `ubuntu-24.04-arm`）で両アーキテクチャをビルドする。配布tar.gzをそれぞれ外部へ展開し、各CPUのランナーで `bun scripts/Verify-LinuxFiles.ts <prunletの絶対パス> <新規の外部出力先>` を実行する。ARM64環境でx64を検証する場合は、末尾に次を追加する。

```text
<検証済みqemu-x86_64の絶対パス> /usr/x86_64-linux-gnu/lib/ld-linux-x86-64.so.2 --library-path /usr/x86_64-linux-gnu/lib
```

動的ローダーを直接指定し、`-L` でルートディレクトリの解決をsysrootへ変えない。専用の `XDG_DATA_HOME` で、元名・Trash内のinode・復元後の内容を照合する。CLIとstdio MCPの終了コード、フックの拒否、別マウント・リンク・設定の保全も確認する。

起動時自動更新は、各CPUでバージョンとコミットが異なる3世代を、`RUSTFLAGS='--cfg prunlet_linux_update_tests'` を指定したデバッグビルドとして用意する。CPUをエミュレーションする環境向けのfixtureは `CARGO_PROFILE_DEV_OPT_LEVEL=2` を指定する。後の2世代は公開物と同じustar形式のtar.gzにする。 `bun scripts/Verify-UnixStartupUpdate.ts <新規の外部出力先> <初期実行体> <2世代目のtar.gz> <3世代目のtar.gz>` をCPUが一致するLinuxランナーで実行する。これはGitHub応答だけを隔離fixtureに置き換え、通常MCPのstdio・実行体の交換と引継ぎ・設定と復元領域の保全を確認する。x64のビルドと、実行体の再起動を含む更新の検証は `ubuntu-latest` で行う。
