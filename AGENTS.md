# Prunletの開発

現在の構造と設計判断は[DESIGN.md](DESIGN.md)を参照する。Rust実装は`src/rust`へ集約し、CLI・MCPは`service::Runtime`を共有する。OS固有の実体・パス・ACLは`platform/windows`と`platform/macos`へ分け、CLI・MCP・フックで別の削除方式を実装しない。移行中に保持する`src/Prunlet`は互換性参照であり、Rust製品からC# backendを呼ばない。

Windowsのファイル・フォルダー・レジストリ削除は、配置済み共通指示のexe・設定の絶対パスを使い、最初から`cmd.exe`・`login: false`でPrunlet CLIを呼ぶ。空白・Unicode・多数・長いファイル対象は絶対パスのUTF-8 JSON一覧を`delete [--dry-run] --paths-file <絶対パス>`で渡す。レジストリは`registry-delete --view <32|64> ... -- <single-key-path>`を使う。exe・設定自体をCMDで安全に表現できない場合は実行前に同じCoreのMCPを選ぶ。拒否された削除を別shell・Prunletへ付け替えて再試行しない。WindowsからSSH経由でMac/Linuxへ削除要求を送る前には、[送信前変換の手順](docs/integration.md#hookの検査範囲)も読む。詳細は[連携手順](docs/integration.md)を参照する。

ファイル・フォルダーは通常Windowsのゴミ箱へ移し、操作記録自体を作らない。末尾名がWindows予約名の実在する通常ファイルだけは、元実体と親・名前・属性を固定して照合し、追加確認やShell試行なしで永久削除する。予約名の祖先・ディレクトリ・reparse pointはこの例外に含めない。通常名の対象は、Windowsが対象をゴミ箱には大きすぎると明示した場合、またはゴミ箱利用不可を返し対象ボリュームの即時削除設定を確認できた場合で、保持した実体と再固定した名前・親・属性が一致した場合だけ、同じ要求内で元の名前を永久削除する。対象ボリュームの即時削除設定は実効ユーザーとボリュームを照合し、各削除直前に再確認する。設定の原子的固定はできない。サイズ超過と確認済み即時削除設定以外の失敗や不明な結果からは永久削除へ切り替えない。操作ID・PIDL・File ID・内容hash・size・ACL snapshotを復元用に永続化せず、manifest・monitor・index・retirement・復元stageを新規作成しない。処理中の実体照合に使う一時handle・File IDとは区別する。ゴミ箱に移った項目の復元と保持管理はWindowsへ任せ、CLI/MCPのファイル復元を追加しない。共通の固定`maintenance.lock`は排他用であり操作記録ではない。`allowedRoots`は互換入力で、削除対象フォルダーの許可リストを設けない。独自退避・コピーfallback・自動昇格・リンク先走査を追加しない。中央metadata・レジストリ専用namespace・未移行の旧領域とその祖先を保護する。

`FileDeleteResult`は`dryRun`・`items`・`warnings`、各項目は`path`・`kind`・`status`・任意`error`である。状態は`recycled`・`permanently_deleted`・`would_recycle`・`would_permanently_delete`・`already_absent`・`failed`・`ambiguous`で、`failed`と`ambiguous`は非成功として返す。Shellが返した項目を一時的に開き、事前に保持した元のFile IDと照合できない場合は`ambiguous`とする。dry-runは予約名の通常ファイルをwould_permanently_deleteで示す。それ以外では永久削除の要否を予測できないことを警告する。不明な削除を自動再送せず、元対象とWindowsゴミ箱を確認する。

レジストリは[専用設計](DESIGN.md#レジストリの削除と復元)のstage・snapshot・永続化・commit順、完全security bytes照合、schema 5の作成時からの非公開ACL、曖昧状態の保全を維持する。非トランザクション削除へのfallbackを追加しない。`restore`（`registry-restore`の別名）・`operations`・`purge`・`maintain`はレジストリ専用で、MCPは5ツールを維持する。レジストリ記録は`backupDirectory/.registry-records-v1/{id}`へ置き、manifestの`MetadataRoot`は共通基点を保持する。

保護アクセスは削除・dry-run・復元ごとに`--access-mode backupRestore`（MCPは`accessMode`）を明示し、64bit OS・64bitプロセス・view 64の制約と要求別token隔離を維持する。権限不足から自動選択せず、ACL・Ownerを書き換えない。実効ユーザーのClasses別名の例外は[専用設計](DESIGN.md#レジストリの削除と復元)の検証・transaction競合検出に限定し、任意リンクの追跡へ広げない。Windows管理情報の参照整合を修復する用途へ汎用削除を流用しない。

native sessionはscopeの明示選択を必要とする。検証起動は固定したPrepare入力に対する`Start -AssertNativeWindows`で行い、UAC同意を代行せず、実token・期限・入力固定・Run permitを検査する。切断後は同じ削除を再送せず`registry-reconcile <operation-id>`で照合する。

並列削除はclaim取得順・全preflight完了後の実行・process共通worker上限・ハードリンク検出時の排他再実行を維持する。MCP要求枠とfile worker枠を分け、registry privilege変更をfile workerと並行させない。

使用中の対象を待つ場合は、削除開始前にCLIの`delete-queue`またはMCPの`delete_files`の`action: "enqueue"`へ明示登録する。通常削除と同じshell・設定・権限境界を守り、拒否・失敗・不明結果の再試行先にしない。受付だけで完了とせず、CLIの`delete-queue-status <job-id>`またはMCPの`action: "status"`と`jobId`で最終結果を確認する。取消は`pending`の間だけで、結果不明なら元対象とWindowsゴミ箱を確認し、自動再送しない。実体照合・worker寿命・保持の設計は[明示的な削除待機キュー](DESIGN.md#明示的な削除待機キュー)を参照する。

保持制御はレジストリschema 5専用で、既定7日・合計1 GiB、事前容量走査・整理前後再走査・共通ロック・単一超過時だけの予算を維持する。Windowsゴミ箱のファイルと未移行旧ファイルは容量・期限・purgeに含めない。ファイル削除・通常一覧・通常保守は旧ファイル操作ディレクトリを走査しない。手動整理はCLI明示適用のみで、MCPへpurgeを追加しない。

旧ファイルの復元互換を維持せず、明示`migrate`で所有確認済みの旧退避root・操作記録をWindowsゴミ箱へ破棄する。旧schemaのparser・decode・内容hash・ACL snapshot・コピー・bundle・sidecar・復元helperは追加しない。store/restoreの専用StoreKey rootと小marker、中央の正規file marker、typed root layoutで所有を確認し、registry signals・共通基点・他config/privateBase・未知の非所有領域を保護する。ファイル別の恒久一覧を作らず、固定private空gate `.legacy-file-discard-in-progress` だけで中断の自動再送を止める。正規gateの明示ackは`migrate --apply --retry-legacy-discard`のみで、installerは指定しない。fileの未完了はregistry利用を塞がない。policy 2評価済みの`--apply --if-needed`は中央旧GUID再走査を省き、更新時のonline owned store固定位置・小marker確認だけを続ける。通常file/list/maintainは旧領域を走査しない。

Codexの`exec_command`が正式なsandbox権限要求に対応し、実効設定で要求が必要かつ許可される場合は、ファイル・フォルダーの実削除を初回から`sandbox_permissions: "require_escalated"`で申請する。要求が不要・未対応・禁止の場合は実効設定と正式な承認経路に従う。dry-runをゴミ箱アクセス許可の証拠にしない。

Windowsの管理者起動はsandbox権限申請と区別する。許可済みの削除に管理者権限が必要なら、手動実行を依頼する前に、ホストの許可範囲でエージェントが管理者CMDを起動し、同じ配置済みCLI・設定を直接使う。起動先の実トークン・必要なprivilege・CLIの終了コード・JSON・対象状態を確認する。Prunlet自身の自動昇格禁止と区別し、本人のUAC同意を代行せず、拒否・結果不明を迂回しない。権限不足で停止した後の再実行条件も含め、[sandboxとゴミ箱へのアクセス](docs/integration.md#sandboxとゴミ箱へのアクセス)に従う。

## ビルドと検証

利用者が明示許可した場合だけ、Windowsの同期要求で`--recursive --permanent-reserved-tree`（MCPは`recursive: true, permanentReservedTree: true`）を使える。これは実在する予約名子孫を含む通常名の通常ディレクトリーに限定した事前選択であり、通常経路の「予約名の通常ファイル」例外や、失敗からの自動fallbackを広げない。全root合計4,095項目・ドライブルートを含むパス要素64個・保持するdirectory固定handle合計8,192本・共有hardlinkのADS guard合計4,095本の事前検証と既存の保護・実体照合を維持し、Shellは使わず、キュー・macOSでは拒否する。詳細は[連携手順](docs/integration.md#予約名を含む木の明示的な永久削除)を参照する。関連変更では`tests/permanent_reserved_trees.rs`の8ケースと通常の記録なしファイルE2Eを実行する。このblackbox統合テストは製品の`src/rust`とは分け、[検証手順](docs/verification.md)の固定入力で実CLI・MCPと同一ソースprobeを確認する。

macOSの変更では[macOSの手順](docs/macos.md#ソースからビルドする)で外部出力先へビルドし、[ネイティブ検証の4経路](docs/macos.md#ネイティブ検証の4経路)から影響する経路を実行する。通常release・専用cfgのdebug・libtestの結果を区別し、クロスビルドを対象CPUでの動作確認の代わりにしない。以下のビルド・検証コマンドはWindows向けである。

Windows・`rust-toolchain.toml`指定のRust（MSVC）・C++ビルドツールとWindows SDK・PowerShell 7を使う。ビルドは`scripts/Publish-Prunlet.ps1`に外部の絶対出力先を渡す。Cargoのtarget・TEMP/TMPも外部へ分離し、直接の`cargo build` / `cargo test`でリポジトリへ出力しない。製品runtimeに.NETを要求せず、真正な旧版exeや旧C#検証補助の利用は互換性検証と区別する。

```powershell
$buildRoot = Join-Path 'D:\Codex\Prunlet' ('build-' + [guid]::NewGuid().ToString('N'))
pwsh -NoProfile -File .\scripts\Publish-Prunlet.ps1 -OutputDirectory $buildRoot -IncludeVerificationProbe
```

出力は`$buildRoot\publish\prunlet.exe`。既定は`win-x64`、ARM64向けは`-Runtime win-arm64`を指定する。metadata・TEMP/TMP・fixture・reportは外部D絶対パスへ隔離し、reportの親を事前作成する。リポジトリおよびCodex homeへ`bin`・`obj`・一時物・検証出力・バックアップを作らない。

実装後は[検証手順](docs/verification.md)の記録なしファイルE2Eと、影響に応じたレジストリ・旧データ移行・導入検証を行う。CLI・stdio MCP・hookの実プロセス、終了コード・passed/failed・外部JSONを読んで判定する。skip・CaseFilterだけの成功や未実行を全件合格にしない。

- ファイル: `scripts/Verify-RecordlessFiles.ps1`へ今回のexeと新しい外部出力・reportを渡す。結果DTO、操作記録不作成、dry-run不変更、Windowsゴミ箱往復、内容/ID/属性/ACL/ADS、リンク先保全・ハードリンク共有、再帰・拒否・不明状態を確認する。
- フック解析: shell選択・文字列解析・拒否理由を変更した場合は`scripts/Verify-HookParsing.ps1 -ExecutablePath <今回のexe絶対パス> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSON絶対パス> -ConfigPath <設定絶対パス>`を実行する。検査用コマンド文字列を直接実行せず、hookへのJSON入力で許可・拒否とfixture不変更を確認する。拒否理由の`reasonValid`も確認し、検知命令・shell解釈または検査不能の原因、およびshell不明時の候補判定の説明を検証する。範囲と判定は[検証手順](docs/verification.md#通常e2eの検証範囲)に従う。
- 旧データ移行: `scripts/Verify-FileRecordMigration.ps1`へ今回のexe・同buildの`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`と真正な旧版exeを渡す。synthetic所有marker用`-FixtureAssemblyPath`は候補runtimeとは区別する。旧schema fixtureを新版で捏造せず、所有済み旧rootの直接Bin破棄、壊れたfile本文の非読取、registry混在/他config/未知非所有領域の保護、dry-run不変更・gate不作成、中断後の自動再送拒否・明示ack、policy 0→2と更新時の後online store回収を確認する。旧file復元・bundle・sidecar・copy・履歴圧縮は成功条件へ残さない。
- 並行・待機: 同一対象・親子・共有ハードリンクの排他、全preflight失敗時保全、process worker上限、入力順を確認する。60秒超ロック待機と解放後続行、CLI stderr/stdout、MCP token付き進捗と最終応答後抑止、EOF後完了を確認する。
- 削除待機キュー: キュー・実体照合・CLI/MCP入口を変更した場合は`scripts/Verify-DeferredDeleteQueue.ps1 -ExecutablePath <今回のexe絶対パス> -ConfigPath <設定絶対パス> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSON絶対パス>`を実行する。待機・取消・解放後の削除・stdio切断後の継続を確認し、保持期限や各上限などの追加検証範囲は[検証手順](docs/verification.md#一時的なロックとロード中dll)と照合する。通常の同期削除の検証だけで代替しない。
- 再帰永久削除: 子の実体・時刻照合を変更した場合は`scripts/Verify-HardlinkEntryTimes.ps1`へ`-ExecutablePath`・`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`・未使用の外部D絶対パスの`-OutputDirectory`・外部JSONの`-ReportPath`を渡す。CLI/MCPのハードリンク削除と別名の保全、Core境界での変更検知と診断値を区別して確認する。probeは今回のexeと同じ不変更ソースから作り、build manifestのSHA-256を固定する。
- レジストリ: `scripts/Verify-RegistryRecovery.ps1`と、native sessionの`Verify-RegistrySession.ps1`のPrepare・Start（`-AssertNativeWindows`）・Current・Runを使う。完全ACL/raw bytes・競合・transaction・snapshot保全・専用namespace/予算を確認する。同じexeのcurrent側6801拒否保全と明示native側CLI/MCP正常往復、実token・view/scopeを区別し、権限・KTM・viewの未検証を成功に数えない。
- 保護アクセス・診断: 保護レジストリのopen・privilege・viewを変更した場合は`Verify-ProtectedRegistryAccess.ps1`と`Verify-ProtectedRegistryViews.ps1`、ファイルのアクセス拒否・削除後確認の診断を変更した場合は`Verify-AccessDeniedFiles.ps1`も実行する。引数とfixture条件は[検証手順](docs/verification.md)に従い、API適合性probeとCLI/MCP E2Eの結果を区別する。
- snapshot公開: 容量予約・本文のシリアライズ・公開処理を変更した場合は`scripts/Verify-RegistrySnapshotPublication.ps1`も実行する。必須引数と保存境界の検証範囲は[レジストリ検証](docs/verification.md#レジストリの削除と復元)に従い、実レジストリの往復検証とは区別する。
- 導入: installer・共通指示・登録解除変更では`scripts/Verify-LatestInstall.ps1`を実行する。fixtureと実GitHub、保存内容と実ホストhook読込・承認・guide遵守を区別する。移行開始後の失敗で旧binaryへrollbackせず新exe/設定/登録を保全し、同じCLIで再開できることを確認する。
- 起動時更新: `integration/start-prunlet-mcp.ps1`・`src/rust/update`・公開ZIPの生成や登録を変更した場合は、[導入検証](docs/verification.md#latestインストーラー)の起動時更新の範囲も確認する。公開と同じZIPによる複数回更新、使用中の延期、独立hook、途中再開、登録改変の保全、ADSを含む容量上限を検証し、通常の導入検証だけで代替しない。

ゴミ箱全体の空化・既存項目の清掃を行わず、今回fixtureだけを扱う。検証後の保持・清掃は[検証手順](docs/verification.md#検証後の保持と清掃)に従い、未清掃パス・理由・再開条件を返す。

## 導入と文書

Dependabotと依存検証・自動マージのworkflowを変更する場合は、[依存更新の境界](DESIGN.md#依存更新の境界)にある検証条件と権限分離を維持する。依存検証CIの成功は、変更内容に応じた上記の追加E2Eを代替しない。

対外表記ではREADME冒頭の副題を併記する。今後のX告知では本文と紹介画像に同じ副題を毎回含め、GitHubの説明欄も同じ表記に揃える。X告知本文には、README冒頭に沿った紹介文を毎回1文入れる。その紹介文には、`blocked by policy`による清掃の停止を減らす目的と、AIエージェントのファイル・フォルダー削除を専用CLI・MCPへ集約する使い方を含める。

利用者向け導入は`scripts/Install-Prunlet.ps1`でGitHubの既定ブランチ最新HEADを解決する。開発クローンやローカルビルドをlatest導入の代用にしない。インストール元のリポジトリ・取得ブランチ・コミットは`source-info.json`へ記録する。既存設定は[容量上限の一度だけの移行](DESIGN.md#容量上限の一度だけの移行)を除いて保持する。旧復元データはCoreの明示`migrate`で移行し、通常APIから変更しない。設定読込・dry-runへ暗黙の適用を持ち込まず、移行済み印と移行後の利用者変更を尊重する。導入検証では、旧容量からの移行、未知の設定とACLの保持、再更新時の冪等性、ロック・登録失敗時の原本保全と復旧も確認する。

MCP起動時の自動更新は手動導入とは別の経路である。[更新の設計](DESIGN.md#起動時自動更新)に従い、更新状態・製品排他・配布検証・容量検査を迂回しない。Windows managed MCPのproxy・世代切替は[専用設計](DESIGN.md#windows-managed-mcpの世代切替)の未送信待機、応答までのcanonical read pin、旧子drain・正常終了、1接続1実処理世代、送信済結果不明の非再送を維持する。`mcpProxy2`・`mcpBackendLease1`のbackend自身のread leaseと親照合を保ち、managed proxyへ独自KILL_ON_JOB_CLOSEやqueue workerのnative breakawayを追加しない。cache回収の内部permitは当該要求のexact root・IDに限定し、通常CLI/MCPと他metadataの保護を解除しない。回収前の固定private空gateは元の正確な1対象の確認済み削除時だけ解除し、不明・失敗・中断では保持して残候補と後続applyを止める。gateを迂回する再送は行わず、元対象・ゴミ箱確認後のCLI専用`mcp-cache-maintain --ack-interrupted-cleanup`だけでgateを明示解除する。ackの厳密な所有・実体検証、apply併用拒否、gateだけの解除を維持し、MCP・installer・通常起動から暗黙ackしない。関連変更では[世代切替の検証](docs/verification.md#windows-managed-mcpの世代切替)も実行し、実ホストの再接続確認と区別する。リリースは固定toolchainから外部targetへbootstrapしたRust製`prunlet-release`の絶対パスを使う。`build --source <ソース絶対パス> --output <外部出力絶対パス> --commit <40桁SHA> --branch <既定ブランチ> --runtime <win-x64|win-arm64> --repository <owner/repo> --release-source true`で製品とbuild provenanceを生成し、`package`で従来と同形式のZIPを作る。公開ZIPは`verify --source <ソース絶対パス> --publish <publish絶対パス> --package <ZIP絶対パス> --commit <40桁SHA> --branch <既定ブランチ> --runtime <win-x64|win-arm64> --repository <owner/repo>`でGit HEAD・全製品入力・生成元・provenance・全payload・実物のAuthenticode（NotSignedまたはValid）へ照合し、返されたZIP全体のSHA-256がアップロード直前にも一致することを確認する。R2への配置・公開URL照合は同じ引数の`publish-r2`を使い、その成功後だけ同一ZIPを旧版互換用のGitHub Release assetへ添付してdigest・sizeを確認する。bootstrap・環境分離の詳細は[配布手順](docs/distribution.md#rust製リリースcli)に従う。公開は明示依頼時だけ行い、[配布の設定](docs/distribution.md)にあるR2資格情報をログへ出さない。R2への変更で旧CLIの内部コマンド・既存stageの意味やGitHub側の信頼検証を変えない。

依存追加、公開、バージョン変更、Gitのコミット・プッシュは今回の依頼に含まれる場合だけ行う。コードコメントは日本語。[README](README.md)は利用者向け、[DESIGN.md](DESIGN.md)は現在の設計、連携と検証の詳細は`docs/`、エージェントの作業規約は本ファイルに置き、同じ説明を複製せず参照する。
