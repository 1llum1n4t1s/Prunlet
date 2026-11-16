# Prunletの開発

現在の構造と設計判断は[DESIGN.md](DESIGN.md)を参照する。削除処理は`src/rust`のファイル・レジストリ・移行Coreに集約し、CLI・MCP・フックで別の削除方式を実装しない。Rustの版は[`rust-toolchain.toml`](rust-toolchain.toml)、依存の解決は`Cargo.lock`に従う。

## Windowsの実装と操作

Windowsのファイル・フォルダー・レジストリ削除は、配置済み共通指示のexe・設定の絶対パスを使い、最初から`cmd.exe`・`login: false`でPrunlet CLIを呼ぶ。空白・Unicode・多数・長いファイル対象は絶対パスのUTF-8 JSON一覧を`delete [--dry-run] --paths-file <絶対パス>`で渡す。レジストリは`registry-delete --view <32|64> ... -- <single-key-path>`を使う。exe・設定自体をCMDで安全に表現できない場合は実行前に同じCoreのMCPを選ぶ。拒否された削除を別shell・Prunletへ付け替えて再試行しない。詳細は[連携手順](docs/integration.md)を参照する。

ファイル・フォルダーは通常Windowsのゴミ箱へ移し、操作記録自体を作らない。末尾名がWindows予約名の実在する通常ファイルだけは、元実体と親・名前・属性を固定して照合し、追加確認やShell試行なしで永久削除する。予約名の祖先・ディレクトリ・reparse pointはこの例外に含めない。通常名の対象は、Windowsが対象をゴミ箱には大きすぎると明示した場合、またはゴミ箱利用不可を返し対象ボリュームの即時削除設定を確認できた場合で、保持した実体と再固定した名前・親・属性が一致した場合だけ、同じ要求内で元の名前を永久削除する。即時削除設定は実効ユーザーとボリュームを照合して各削除直前に再確認する（原子的固定はできない）。それ以外の失敗や不明な結果からは永久削除へ切り替えない。操作ID・PIDL・File ID・内容hash・size・ACL snapshotを復元用に永続化せず、manifest・monitor・index・retirement・復元stageを新規作成しない（処理中の実体照合に使う一時handle・File IDとは区別する）。ゴミ箱の復元と保持管理はWindowsへ任せ、CLI/MCPのファイル復元を追加しない。共通の固定`maintenance.lock`は排他用であり操作記録ではない。`allowedRoots`は互換入力で、削除対象フォルダーの許可リストを設けない。独自退避・コピーfallback・自動昇格・リンク先走査を追加しない。中央metadata・レジストリ専用namespace・未移行の旧領域とその祖先を保護する。

ファイル結果のDTO・状態・dry-runの契約は[削除のデータフロー](DESIGN.md#削除と復元のデータフロー)を維持し、`failed`と`ambiguous`を非成功として返す。不明な削除を自動再送せず、元対象とWindowsゴミ箱を確認する。

レジストリは[専用設計](DESIGN.md#レジストリの削除と復元)のstage・snapshot・永続化・commit順、完全security bytes照合、schema 5の作成時からの非公開ACL、曖昧状態の保全を維持する。非トランザクション削除へのfallbackを追加しない。`restore`（`registry-restore`の別名）・`operations`・`purge`・`maintain`はレジストリ専用（`maintain`の末尾の自アプリ一時物の整理を除く）で、MCPは5ツールを維持する。レジストリ記録は`backupDirectory/.registry-records-v1/{id}`へ置き、manifestの`MetadataRoot`は共通基点を保持する。

保護アクセスは削除・dry-run・復元ごとに`--access-mode backupRestore`（MCPは`accessMode`）を明示し、64bit OS・64bitプロセス・view 64の制約と要求別token隔離を維持する。権限不足から自動選択せず、ACL・Ownerを書き換えない。実効ユーザーのClasses別名の例外は[専用設計](DESIGN.md#レジストリの削除と復元)の検証・競合検出に限り、任意リンクの追跡へ広げない。Windows管理情報の参照整合の修復に汎用削除を流用しない。

native sessionはscopeの明示選択を必要とする。検証起動は固定したPrepare入力に対する`Start -AssertNativeWindows`で行い、UAC同意を代行せず、実token・期限・入力固定・Run permitを検査する。切断後は同じ削除を再送せず`registry-reconcile <operation-id>`で照合する。

並列削除はclaim取得順・全preflight完了後の実行・process共通worker上限・ハードリンク検出時の排他再実行を維持する。MCP要求枠とfile worker枠を分け、registry privilege変更をfile workerと並行させない。

使用中の対象を待つ場合は、削除開始前にCLIの`delete-queue`またはMCPの`delete_files`の`action: "enqueue"`へ明示登録する。通常削除と同じshell・設定・権限境界を守り、拒否・失敗・不明結果の再試行先にしない。受付だけで完了とせず、`delete-queue-status <job-id>`またはMCPの`action: "status"`と`jobId`で最終結果を確認する。取消は`pending`の間だけで、結果不明なら元対象とWindowsゴミ箱を確認し、自動再送しない。設計は[明示的な削除待機キュー](DESIGN.md#明示的な削除待機キュー)を参照する。

保持制御はレジストリschema 5専用で、既定7日・合計1 GiB、事前容量走査・整理前後再走査・共通ロック・単一超過時だけの予算を維持する。Windowsゴミ箱のファイルと未移行旧ファイルは容量・期限・purgeに含めず、ファイル削除・通常一覧・通常保守は旧ファイル操作ディレクトリを走査しない。手動整理はCLI明示適用のみで、MCPへpurgeを追加しない。更新・導入が残した自アプリの一時物は`src/rust/housekeeping.rs`が`maintain`時にだけ整理し、名前・所有印の完全一致とCore削除への委譲を保つ（[設計](DESIGN.md#更新導入後の一時物の自動整理)）。

旧ファイルの復元互換を維持せず、明示`migrate`で所有確認済みの旧退避root・操作記録をWindowsゴミ箱へ破棄する。旧schemaのparser・decode・内容hash・ACL snapshot・コピー・bundle・sidecar・復元helperは追加しない。専用StoreKey rootと小marker、中央の正規file marker、typed root layoutで所有を確認し、registry signals・共通基点・他config/privateBase・未知の非所有領域を保護する。ファイル別の恒久一覧を作らず、固定private空gate `.legacy-file-discard-in-progress` だけで中断の自動再送を止める。正規gateの明示ackは`migrate --apply --retry-legacy-discard`のみで、installerは指定しない。fileの未完了はregistry利用を塞がない。policy 2評価済みの`--apply --if-needed`は中央旧GUID再走査を省き、更新時のonline owned store固定位置・小marker確認だけを続ける。

Codexの`exec_command`が正式なsandbox権限要求に対応し、実効設定で要求が必要かつ許可される場合は、ファイル・フォルダーの実削除を初回から`sandbox_permissions: "require_escalated"`で申請する。要求が不要・未対応・禁止の場合は実効設定と正式な承認経路に従う。dry-runをゴミ箱アクセス許可の証拠にしない。

Windowsの管理者起動はsandbox権限申請と区別する。許可済みの削除に管理者権限が必要なら、手動実行を依頼する前に、ホストの許可範囲でエージェントが管理者CMDを起動し、同じ配置済みCLI・設定を直接使い、実トークン・privilege・終了コード・JSON・対象状態を確認する。Prunlet自身の自動昇格禁止と区別し、UAC同意を代行せず、拒否・不明結果を迂回しない。再実行条件は[sandboxとゴミ箱へのアクセス](docs/integration.md#sandboxとゴミ箱へのアクセス)に従う。

## Apple Silicon版の実装

ファイル削除は`src/rust/platform/macos`の共通Trash経路に集約し、MCPは`delete_files`のみとする。対象と祖先の実体確認、リンク先の保全、Trashの返却実体と元名の照合を維持する。待機キューは協調的な`flock`だけを待ち、開始許可とMach監査トークンの照合を維持する。`ambiguous`は元のパスとゴミ箱を確認し、自動再送しない。配置済みCLI・MCP・workerは固定の更新ロックを共有する。導入は`scripts/Install-Prunlet.sh`に集約し、マニフェスト・Developer ID署名・公証・SHA-256の照合を緩めるオプションやMCPホスト設定の自動書換えを追加しない。詳しい境界は[macOSの削除設計](DESIGN.md#macosのファイル削除)と[更新の設計](DESIGN.md#macosの起動時自動更新)を参照する。

## Linux版の実装

同期削除は`src/rust/platform/linux`の共通経路に集約し、MCPは`delete_files`の同期削除だけを公開する。ホームTrashと同じマウントでの移動、事前検査、リンク先と保護領域の保全を維持する。`ambiguous`では元のパスとTrashを確認し、自動再送しない。管理済み配置の固定ロックと更新時の実行体照合は[Linuxの起動時自動更新](DESIGN.md#linuxの起動時自動更新)に従う。削除の境界は[Linuxのファイル削除](DESIGN.md#linuxのファイル削除)を参照する。

## ビルドと検証

### Windows

Windows・Rustup/Cargo・MSVCビルドツール・Windows SDK・PowerShell 7を使う。ビルドは`scripts/Publish-Prunlet.ps1`に外部の絶対出力先を渡し、Cargoの出力・TEMP/TMPをリポジトリへ置かない。

```powershell
$buildRoot = Join-Path '<外部の作業ディレクトリ>' ('build-' + [guid]::NewGuid().ToString('N'))
pwsh -NoProfile -File .\scripts\Publish-Prunlet.ps1 -OutputDirectory $buildRoot
```

製品exeは`$buildRoot\publish`へ出力する。既定は`win-x64`（`x86_64-pc-windows-msvc`）、ARM64向けは`-Runtime win-arm64`（`aarch64-pc-windows-msvc`）を指定する。Cargo target・metadata・TEMP/TMP・fixture・reportはリポジトリ外の外部絶対パス（`~/.codex`の外）へ隔離し、reportの親を事前作成する。ゴミ箱往復のfixtureは、ごみ箱が有効（即時削除設定でない）ボリュームに`-FixtureRoot`で置く。

検証時は`-IncludeVerificationProbe`で`publish/prunlet-verification.exe`・`publish/prunlet_fixtures.dll`・`publish/prunlet-support.exe`を同時に生成し、`build-manifest.json`で製品と検証用出力を照合する。Coreプローブを使う検証には`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`を一組で渡す。検証用出力は製品ZIPに含めない。

実装後は[検証手順](docs/verification.md)の記録なしファイルE2Eと、影響に応じたレジストリ・旧データ移行・導入検証を行う。CLI・stdio MCP・hookの実プロセスの終了コード・passed/failed・外部JSONで判定する。skip・CaseFilterだけの成功や未実行を全件合格にしない。

- ファイル: `scripts/Verify-RecordlessFiles.ps1`へ今回のexe、上記のプローブ・manifest・SHA-256、および新しい外部出力・reportを渡す。プローブを省略した場合は該当するCoreケースを未検証とする。結果DTO、操作記録不作成、dry-run不変更、Windowsゴミ箱往復、内容/ID/属性/ACL/ADS、リンク先保全・ハードリンク共有、再帰・拒否・不明状態を確認する。再帰固定削除の診断では、CLI・MCPのロード中DLLケースで要求rootの結果DTOと失敗entry・保持元の診断を区別する。Shell返却パスの照合を変更した場合は`Verify-LongPathFiles.ps1`のPrepare・VerifyDryRun・VerifyDeleteも行う。渡し方は[通常E2Eの検証範囲](docs/verification.md#通常e2eの検証範囲)に従う。
- フック解析: shell選択・文字列解析・拒否理由を変更した場合は`scripts/Verify-HookParsing.ps1 -ExecutablePath <今回のexe絶対パス> -OutputDirectory <未使用の外部絶対パス> -ReportPath <外部JSON絶対パス> -ConfigPath <設定絶対パス>`を実行する。検査用コマンド文字列を直接実行せず、hookへのJSON入力で許可・拒否とfixture不変更を確認し、拒否理由の`reasonValid`（検知命令・shell解釈または検査不能の原因、shell不明時の候補判定の説明）も検証する。範囲は同節に従う。
- 旧データ移行: `scripts/Verify-FileRecordMigration.ps1`へ今回のexe・同じビルドのプローブ照合用3引数と、真正な旧版exeを渡す。旧schema fixtureを新版で捏造せず、所有済み旧rootの直接Bin破棄、壊れたfile本文の非読取、registry混在/他config/未知非所有領域の保護、dry-run不変更・gate不作成、中断後の自動再送拒否・明示ack、policy 0→2と更新時の後online store回収を確認する。旧file復元・bundle・sidecar・copy・履歴圧縮は成功条件へ残さない。
- 並行・待機: `scripts/Verify-ConcurrentDeletion.ps1`へ今回のexe・同じビルドのプローブ照合用3引数・新しい外部出力とreportを渡し、Coreのclaimと実CLI/MCPのロック待機・MCP進捗の分離を確認する。全preflight失敗時の保全・共有ハードリンク・worker上限・入力順・60秒超の待機は、記録なしファイルE2Eの該当ケースも確認する。
- 削除待機キュー: キュー・実体照合・CLI/MCP入口を変更した場合は`scripts/Verify-DeferredDeleteQueue.ps1 -ExecutablePath <今回のexe絶対パス> -ConfigPath <設定絶対パス> -OutputDirectory <未使用の外部絶対パス> -ReportPath <外部JSON絶対パス>`を実行し、待機・取消・解放後の削除・stdio切断後の継続を[検証手順](docs/verification.md#一時的なロックとロード中dll)と照合する。同期削除の検証で代替しない。
- 再帰永久削除: 子の実体・時刻照合を変更した場合は`scripts/Verify-HardlinkEntryTimes.ps1`へ`-ExecutablePath`・`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`・外部の未使用`-OutputDirectory`・外部JSONの`-ReportPath`を渡す（プローブは今回のexeと同じビルド）。CLI/MCPのハードリンク削除と別名の保全、Core境界での変更検知と診断値を区別して確認する。
- レジストリ: `scripts/Verify-RegistryRecovery.ps1`と、native sessionの`Verify-RegistrySession.ps1`のPrepare・Start（`-AssertNativeWindows`）・Current・Runを使う。完全ACL/raw bytes・競合・transaction・snapshot保全・専用namespace/予算を確認し、current側6801拒否保全と明示native側の正常往復、実token・view/scopeを区別する。権限・KTM・viewの未検証を成功に数えない。
- 保護アクセス・診断: 保護レジストリのopen・privilege・viewの変更では`Verify-ProtectedRegistryAccess.ps1`と`Verify-ProtectedRegistryViews.ps1`、ファイルのアクセス拒否・削除後確認の診断の変更では`Verify-AccessDeniedFiles.ps1`も実行する。API適合性probeとCLI/MCP E2Eを区別する（[検証手順](docs/verification.md)）。
- snapshot公開: 容量予約・シリアライズ・公開処理の変更では`scripts/Verify-RegistrySnapshotPublication.ps1`も実行し、実レジストリの往復検証と区別する（[レジストリ検証](docs/verification.md#レジストリの削除と復元)）。
- 導入: installer・共通指示・登録解除変更では`scripts/Verify-LatestInstall.ps1`を実行する。fixtureと実R2、保存内容と実ホストhook読込・承認・guide遵守を区別する。移行開始後の失敗で旧binaryへrollbackせず新exe/設定/登録を保全し、同じCLIで再開できることを確認する。
- 起動時更新: `integration/start-prunlet-mcp.ps1`・`src/rust/update/`・公開ZIPの生成や登録を変更した場合は、[導入検証](docs/verification.md#latestインストーラー)の起動時更新の範囲も確認する。公開と同じZIPによる複数回更新、使用中の延期、独立hook、途中再開、登録改変の保全、ADSを含む容量上限を検証し、通常の導入検証だけで代替しない。署名付きマニフェストの照会・取得を変更した場合は、失敗時に何も適用せず現行版で起動すること、固定公開鍵以外の署名・非正規形・他runtime・キー不一致・導入済み以下の版・ZIPのサイズ/SHA-256不一致の拒否を確認する。Windowsの起動時更新のR2応答の置換とテスト鍵の受理は`all(windows, debug_assertions, prunlet_windows_update_tests)`のビルドに限定する。この検証用ビルドは`RUSTFLAGS='--cfg prunlet_windows_update_tests -C debug-assertions=on'`を付けて`Publish-Prunlet.ps1 -IncludeVerificationProbe`で作り、製品ZIP・公開には使わない。`Verify-LatestInstall.ps1`はこのビルドでだけ起動時更新のケースを実行し、通常ビルドは未検証として不合格にする。共通指示の照合を変更した場合は、CRLF/LF差だけなら登録済み`PRUNLET.md`のバイト列を保持して更新でき、本文が異なれば保留することを確認する。未適用stageの認定・再利用を変更した場合は同節の`Verify-UnappliedStartupStage.ps1`も実行し、完全更新との検証範囲の違いを明示する。
- 配信: 署名付きマニフェスト・R2への公開順序・鍵整合の関門・配信workflowを変更した場合は、[配信の検証](docs/verification.md#配信署名付きマニフェストr2の検証)の`scripts/Verify-ReleasePublication.ps1`と`cargo test --locked --lib`を実行する。偽のR2・テスト鍵での成功を、本番鍵・実R2の確認の代わりにしない。

ゴミ箱全体の空化・既存項目の清掃は行わず、今回fixtureだけを扱う。検証後の清掃は[検証手順](docs/verification.md#検証後の保持と清掃)に従う。

### Apple Silicon

Apple Silicon実機で`aarch64-apple-darwin`をビルドし、`CARGO_TARGET_DIR`と`TMPDIR`をリポジトリ外に置く。通常ビルドの`prunlet`で`Verify-MacRecordlessFiles.py`を実行し、Mach・パス境界は隔離した`PRUNLET_MACOS_UNIT_TEST_ROOT`で`cargo test --locked --lib -- --test-threads=1`を実行する。待機キュー・競合・起動時更新の変更では、影響に応じて`Verify-MacQueueIpc.py`・`Verify-MacRaceBoundaries.py`・`Verify-MacStartupUpdate.ts`を実行する。障害注入とR2応答の置換・テスト鍵の受理は`prunlet_macos_race_tests`を指定したデバッグビルドに限定する（Windowsは`prunlet_windows_update_tests`、Linuxは`prunlet_linux_update_tests`）。引数、署名済み更新候補、判定範囲は[Apple Siliconの検証](docs/verification.md#apple-siliconの検証)を参照する。

公開用ビルドはクリーンな対象コミットから`bash scripts/Publish-PrunletMac.sh <外部の新規出力先> <40桁SHA>`を実行する。

### Linux

x64・ARM64ともにGitHub ActionsのGitHub提供ランナー（x64は`ubuntu-24.04`、ARM64は`ubuntu-24.04-arm`）でビルドする。各CPUの通常配布実行体で`bun scripts/Verify-LinuxFiles.ts <実行体> <新規の外部出力先>`を実行する。ARM64環境でx64を検証する場合のQEMU・動的ローダーの引数と、隔離した`XDG_DATA_HOME`での検証範囲は[Linuxの検証](docs/verification.md#linuxの検証)に従う。

起動時更新の変更では、各CPUに対応するLinuxランナーで`bun scripts/Verify-UnixStartupUpdate.ts`を実行し、通常MCP起動で連続更新・延期・中断・拒否を確認する。R2応答の置換とテスト鍵の受理は`prunlet_linux_update_tests`を指定したデバッグビルドに限定し、候補は公開用と同じtar.gz形式を使う。Windowsの同じ役割のcfgは`prunlet_windows_update_tests`（上記の起動時更新の項）である。

## 導入と文書

配布物はCloudflare R2（`https://prunlet.kagayoi.com`）だけから配り、信頼の基点は専用鍵で署名したマニフェストだけとする（[署名付きマニフェスト](docs/distribution.md#署名付きマニフェスト)）。タグとGitHub Releaseは作らず、配布・更新の判定にGitHub API・ブランチ比較・GitHubの資格情報を使わない。クライアントは固定の公開鍵で署名を検証し、製品・repository・runtime・asset名・キーの完全一致、リダイレクト無効、上限、長さとSHA-256、導入済みより厳密に大きい版を確かめ、1つでも外れたら適用せずに延期する。これらの照合を緩めるスイッチ・環境変数・既定値を追加しない。マニフェストの秘密鍵はEnvironment `release`（`release/*`だけを許可）のSecret `PRUNLET_RELEASE_SIGNING_KEY`にだけ置き、鍵整合の関門（`scripts/Test-PrunletReleaseKeyGate.ps1`）とR2へ書くstepだけへ渡す。関門が通るまでR2へ何も書かない。公開鍵の定数`PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64`は、`src/rust/update/manifest.rs`・`scripts/Install-Prunlet.ps1`・`scripts/Install-Prunlet.sh`の各1か所だけ、識別子と同じ行のリテラルで定義する。鍵の交代ではRustの受理鍵に新旧を並べ、旧鍵は全クライアントの移行後に外す。

Prunletの `vava` で新しいリリースを公開するときは、`main`をpushしてから同じcommitで`release/<版>`ブランチを切ってpushする。配信workflowは`release/<版>`の版と`Cargo.toml`の一致・commitが`main`の祖先であることを検査してから署名するので、`main`に含まれないcommitから`release/<版>`を切らない。Windows版は`release/<版>`のpushで`.github/workflows/prunlet-release-package.yml`がビルド・Sigiluneでの署名・R2配置・マニフェスト発行を行う。jobは承認待ちなしで動くので、push後に結果を確認する。手順は[Windowsの公開の順序](docs/distribution.md#公開の順序)に従う。未署名のZIPや手元の物を手動でR2へ置いたり、マニフェストを手で署名したりしない。署名用Secrets・署名鍵・R2の資格情報をビルドstepや別のjobへ渡さない。署名の失敗を自動で再実行せず、原因を確認してから同じrefで再実行する。配信済みの版は作り直さず、やり直しはpatchを上げた新しい`release/<版>`で行う。再開時は完了済みの工程とR2の実物を照合する。

Apple Silicon版のビルド・署名・公証・ZIP生成は `ssh mac` の実機で行う。[Apple Silicon版の公開手順](docs/distribution.md#apple-silicon版の公開手順)に従い、検証済みZIPを`scripts/Send-PrunletMacPackage.ps1`でR2の不変キーへ送ってから、`release/<版>`のrefで`prunlet-mac-release.yml`を実行して署名付きマニフェストを発行する。Macのビルド・署名・公証をGitHub Actionsで行ったり、GitHubホストのrunnerへ切り替えたりしない。このworkflowは自分でビルドしていないZIPをR2上で照合して署名するだけで、Developer ID・公証の検証はクライアント側の責任である。

Linux版は`release/<版>`のpushで`.github/workflows/prunlet-linux-release.yml`が自動で動き、上記のランナーでビルド・検証・glibc 2.39以下の確認を行ってから、Environment `release`のpublish jobが検証済みtar.gzをR2へ置き、署名付きマニフェストを発行する。手作業での配置はしない。配信しない検証は`release/*`以外のrefでの`workflow_dispatch`で行う。手順は[Linux版の公開手順](docs/distribution.md#linux版の公開手順)に従う。

WindowsにはSetup（Velopack。packId `PrunletApp`、x64のみ）の配信も併存する。梱包・検証・配信は`scripts/velopack/`（vpk 1.2.161固定）で、署名のログインを1回に保つため既存のrelease workflowの`package` job内に足している。クライアントの信頼の基点は署名付きマニフェスト`manifests/<版>/velopack-win-x64.json`（nupkgより先に新規作成のみ）で、nupkgの`.sha256`は保存物の整合確認だけに使う。vpkの失敗はZIPの配布を止めず、jobは最後に失敗にする。実装は`src/rust/app_update/`に集約し、取得はVelopackの`download_updates`を使わず検査後にだけ`packages\`へ置く。配信だけをやり直すときは`prunlet-velopack-redo.yml`（再配信する`release/<版>`のrefでの`workflow_dispatch`、入力は保存した実行のrun_id）を使う。`src/rust/update/`・launcher・`Install-Prunlet.ps1`のZIP経路はSetup版の導入が完了するまで残す。手順は[Windowsの Setup（Velopack）](docs/distribution.md#windowsの-setupvelopack)、検証は[Setup（Velopack）の梱包・配信の検証](docs/verification.md#setupvelopackの梱包配信の検証)、設計は[DESIGN.md](DESIGN.md#windows-setupvelopack版の更新)に従い、実R2・実署名・Setupの実機導入は依頼に含まれる場合だけ行う。

Dependabotと依存検証のworkflowは[依存更新の境界](DESIGN.md#依存更新の境界)の検証条件と読取り権限を維持する。依存検証CIは上記の追加E2Eの代替にならない。

対外表記ではREADME冒頭の副題を併記し、X告知の本文・紹介画像とGitHubの説明欄も同じ表記に揃える。X告知本文にはREADME冒頭に沿った紹介文を毎回1文入れ、`blocked by policy`による清掃の停止を減らす目的と、AIエージェントの削除を専用CLI・MCPへ集約する使い方を含める。

Windowsのlatest導入の検証は`scripts/Install-Prunlet.ps1`の[導入契約](DESIGN.md#導入と検証の境界)に従い、開発クローンやローカルビルドで代用しない。インストーラーは署名付きマニフェストが指す最新版の署名済み更新ZIPだけを起動時更新と同じ条件で配置し、ソースをビルドしない。照合を緩めるスイッチ・環境変数やGitHubの資格情報の入口を追加せず、検証ではAuthenticode判定・HTTP取得・公開鍵定数のテスト鍵への置換を検証スクリプトとその写しの側に限る。更新タスク（`start-prunlet-mcp.ps1 -UpdateOnly`）は配布物の12ファイル構成を変えない。[容量上限の一度だけの移行](DESIGN.md#容量上限の一度だけの移行)、既存設定とACLの保持、再更新の冪等性、失敗時の原本保全と復旧も確認する。

WindowsのMCP起動時自動更新は手動導入とは別の経路である。[更新の設計](DESIGN.md#起動時自動更新)に従い、更新状態・製品排他・配布検証・容量検査を迂回しない。Windowsの配布物は`scripts/Package-PrunletUpdate.ps1`で生成し、`release/<版>`から生成・署名するrelease workflowとの形式の一致を維持する。署名は`scripts/Sign-PrunletBuild.ps1`（Sigilune）で行う。Windowsの公開ZIPは`scripts/Verify-ReleasePackage.ps1`へ`-PackagePath`・`-SourceRoot`・`-PublishDirectory`・`-CommitSha`・`-DefaultBranch`・`-Runtime <win-x64|win-arm64>`・`-Repository`・`-RequireSignature`を渡して生成元・署名と照合し、返されたZIP全体のSHA-256がR2への送信直前にも一致することを確認する。署名・ZIP生成・R2配置を変更した場合は、Sigiluneで実際に署名したビルドで`Sign-PrunletBuild.ps1`・梱包・`-RequireSignature`の検証を確認する。本番の署名は最小限にし、対象は外部の一時ビルドだけにする。

ローカライズは[DESIGN.md](DESIGN.md#ローカライズ)に従う。人が読む文言（CLIのヘルプ、インストーラーの案内・エラー・警告）を変えたら、英語の原文をキーにした9言語の辞書（`src/rust/locales/*.json`、`scripts/Install-Prunlet.ps1`・`.sh`の埋め込み表）と`tests/localization.rs`を同時に更新し、`cargo test --locked --test localization`を通す。AIが読む文言（MCPの説明・hookの拒否理由と案内）と機械可読の出力（CLIのJSON、hookの応答）は英語のまま変えない。共通指示（`integration/PRUNLET.md`と`install-agent-instructions.ps1`の参照行）は訳し分けず、言語の変更は登録済みの写しとの照合・起動時更新の保留に影響するため移行を含めて決める。英語の文言を照合する検証スクリプトはプロセス内で`PRUNLET_LANGUAGE=en`に固定する。

READMEは英語の`README.md`を正本とし、`README.ja.md`・`README.zh-CN.md`・`README.zh-TW.md`・`README.ko.md`・`README.es.md`・`README.fr.md`・`README.de.md`・`README.pt-BR.md`を置く。READMEを変えたら全言語版を同時に直し、先頭の9言語の切替行・見出しアンカー・コマンド・パス・設定キー・製品名・URLを揃える。日本語の`docs/`からREADMEの見出しへリンクする場合は`README.ja.md`のアンカーを使う。

コードコメントは日本語。[README](README.md)は利用者向け、[DESIGN.md](DESIGN.md)は現在の設計、連携と検証の詳細は`docs/`、エージェントの作業規約は本ファイルに置き、同じ説明を複製せず参照する。
