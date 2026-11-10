# Prunletの開発

現在の構造と設計判断は[DESIGN.md](DESIGN.md)を参照する。削除処理は`src/rust`のファイル・レジストリ・移行Coreに集約し、CLI・MCP・フックで別の削除方式を実装しない。

Windowsのファイル・フォルダー・レジストリ削除は、配置済み共通指示のexe・設定の絶対パスを使い、最初から`cmd.exe`・`login: false`でPrunlet CLIを呼ぶ。空白・Unicode・多数・長いファイル対象は絶対パスのUTF-8 JSON一覧を`delete [--dry-run] --paths-file <絶対パス>`で渡す。レジストリは`registry-delete --view <32|64> ... -- <single-key-path>`を使う。exe・設定自体をCMDで安全に表現できない場合は実行前に同じCoreのMCPを選ぶ。拒否された削除を別shell・Prunletへ付け替えて再試行しない。詳細は[連携手順](docs/integration.md)を参照する。

ファイル・フォルダーは通常Windowsのゴミ箱へ移し、操作記録自体を作らない。末尾名がWindows予約名の実在する通常ファイルだけは、元実体と親・名前・属性を固定して照合し、追加確認やShell試行なしで永久削除する。予約名の祖先・ディレクトリ・reparse pointはこの例外に含めない。通常名の対象は、Windowsが対象をゴミ箱には大きすぎると明示した場合、またはゴミ箱利用不可を返し対象ボリュームの即時削除設定を確認できた場合で、保持した実体と再固定した名前・親・属性が一致した場合だけ、同じ要求内で元の名前を永久削除する。対象ボリュームの即時削除設定は実効ユーザーとボリュームを照合し、各削除直前に再確認する。設定の原子的固定はできない。サイズ超過と確認済み即時削除設定以外の失敗や不明な結果からは永久削除へ切り替えない。操作ID・PIDL・File ID・内容hash・size・ACL snapshotを復元用に永続化せず、manifest・monitor・index・retirement・復元stageを新規作成しない。処理中の実体照合に使う一時handle・File IDとは区別する。ゴミ箱に移った項目の復元と保持管理はWindowsへ任せ、CLI/MCPのファイル復元を追加しない。共通の固定`maintenance.lock`は排他用であり操作記録ではない。`allowedRoots`は互換入力で、削除対象フォルダーの許可リストを設けない。独自退避・コピーfallback・自動昇格・リンク先走査を追加しない。中央metadata・レジストリ専用namespace・未移行の旧領域とその祖先を保護する。

ファイル結果のDTO・状態・dry-runの契約は[削除のデータフロー](DESIGN.md#削除と復元のデータフロー)を維持し、`failed`と`ambiguous`を非成功として返す。不明な削除を自動再送せず、元対象とWindowsゴミ箱を確認する。

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

Windows・Rustup/Cargo・MSVCビルドツール・Windows SDK・PowerShell 7を使う。Rustの版は[`rust-toolchain.toml`](rust-toolchain.toml)、依存の解決は`Cargo.lock`に従う。ビルドは`scripts/Publish-Prunlet.ps1`に外部の絶対出力先を渡し、Cargoの出力・TEMP/TMPをリポジトリへ置かない。

```powershell
$buildRoot = Join-Path 'D:\Codex\Prunlet' ('build-' + [guid]::NewGuid().ToString('N'))
pwsh -NoProfile -File .\scripts\Publish-Prunlet.ps1 -OutputDirectory $buildRoot
```

製品exeは`$buildRoot\publish`へ出力する。既定は`win-x64`（`x86_64-pc-windows-msvc`）、ARM64向けは`-Runtime win-arm64`（`aarch64-pc-windows-msvc`）を指定する。Cargo target・metadata・TEMP/TMP・fixture・reportは外部D絶対パスへ隔離し、reportの親を事前作成する。

検証時は`-IncludeVerificationProbe`で`publish/prunlet-verification.exe`・`publish/prunlet_fixtures.dll`・`publish/prunlet-support.exe`を同時に生成し、`build-manifest.json`で製品と検証用出力を照合する。Coreプローブを使う検証には`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`を一組で渡す。検証用出力は製品ZIPに含めない。

実装後は[検証手順](docs/verification.md)の記録なしファイルE2Eと、影響に応じたレジストリ・旧データ移行・導入検証を行う。CLI・stdio MCP・hookの実プロセス、終了コード・passed/failed・外部JSONを読んで判定する。skip・CaseFilterだけの成功や未実行を全件合格にしない。

- ファイル: `scripts/Verify-RecordlessFiles.ps1`へ今回のexe、上記のプローブ・manifest・SHA-256、および新しい外部出力・reportを渡す。プローブを省略した場合は該当するCoreケースを未検証とする。結果DTO、操作記録不作成、dry-run不変更、Windowsゴミ箱往復、内容/ID/属性/ACL/ADS、リンク先保全・ハードリンク共有、再帰・拒否・不明状態を確認する。再帰固定削除の診断では、CLI・MCPのロード中DLLケースで要求rootの結果DTOと失敗entry・保持元の診断を区別して確認する。Shell返却パスの照合を変更した場合は`Verify-LongPathFiles.ps1`のPrepare・VerifyDryRun・VerifyDeleteも行う。外部TEMP/TMP・fixture・CLI出力と終了コードの渡し方は[通常E2Eの検証範囲](docs/verification.md#通常e2eの検証範囲)に従う。
- フック解析: shell選択・文字列解析・拒否理由を変更した場合は`scripts/Verify-HookParsing.ps1 -ExecutablePath <今回のexe絶対パス> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSON絶対パス> -ConfigPath <設定絶対パス>`を実行する。検査用コマンド文字列を直接実行せず、hookへのJSON入力で許可・拒否とfixture不変更を確認する。拒否理由の`reasonValid`も確認し、検知命令・shell解釈または検査不能の原因、およびshell不明時の候補判定の説明を検証する。範囲と判定は[検証手順](docs/verification.md#通常e2eの検証範囲)に従う。
- 旧データ移行: `scripts/Verify-FileRecordMigration.ps1`へ今回のexe・同じビルドのプローブ照合用3引数と、検証対象の真正な旧版exeを渡す。旧schema fixtureを新版で捏造せず、所有済み旧rootの直接Bin破棄、壊れたfile本文の非読取、registry混在/他config/未知非所有領域の保護、dry-run不変更・gate不作成、中断後の自動再送拒否・明示ack、policy 0→2と更新時の後online store回収を確認する。旧file復元・bundle・sidecar・copy・履歴圧縮は成功条件へ残さない。
- 並行・待機: `scripts/Verify-ConcurrentDeletion.ps1`へ今回のexe・同じビルドのプローブ照合用3引数・新しい外部出力とreportを渡し、Coreのclaimと実CLI/MCPのロック待機・MCP進捗の分離を確認する。全preflight失敗時の保全、共有ハードリンク、process worker上限、入力順、60秒超の待機と解放後続行・EOF後完了は、記録なしファイルE2Eの該当ケースも確認する。
- 削除待機キュー: キュー・実体照合・CLI/MCP入口を変更した場合は`scripts/Verify-DeferredDeleteQueue.ps1 -ExecutablePath <今回のexe絶対パス> -ConfigPath <設定絶対パス> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSON絶対パス>`を実行する。待機・取消・解放後の削除・stdio切断後の継続を確認し、保持期限や各上限などの追加検証範囲は[検証手順](docs/verification.md#一時的なロックとロード中dll)と照合する。通常の同期削除の検証だけで代替しない。
- 再帰永久削除: 子の実体・時刻照合を変更した場合は`scripts/Verify-HardlinkEntryTimes.ps1`へ`-ExecutablePath`・`-RustProbePath`・`-BuildManifestPath`・`-ExpectedBuildManifestSha256`・未使用の外部D絶対パスの`-OutputDirectory`・外部JSONの`-ReportPath`を渡す。CLI/MCPのハードリンク削除と別名の保全、Core境界での変更検知と診断値を区別して確認する。候補Rustプローブは今回のexeと同じビルドを使う。
- レジストリ: `scripts/Verify-RegistryRecovery.ps1`と、native sessionの`Verify-RegistrySession.ps1`のPrepare・Start（`-AssertNativeWindows`）・Current・Runを使う。完全ACL/raw bytes・競合・transaction・snapshot保全・専用namespace/予算を確認する。同じexeのcurrent側6801拒否保全と明示native側CLI/MCP正常往復、実token・view/scopeを区別し、権限・KTM・viewの未検証を成功に数えない。
- 保護アクセス・診断: 保護レジストリのopen・privilege・viewを変更した場合は`Verify-ProtectedRegistryAccess.ps1`と`Verify-ProtectedRegistryViews.ps1`、ファイルのアクセス拒否・削除後確認の診断を変更した場合は`Verify-AccessDeniedFiles.ps1`も実行する。引数とfixture条件は[検証手順](docs/verification.md)に従い、API適合性probeとCLI/MCP E2Eの結果を区別する。
- snapshot公開: 容量予約・本文のシリアライズ・公開処理を変更した場合は`scripts/Verify-RegistrySnapshotPublication.ps1`も実行する。必須引数と保存境界の検証範囲は[レジストリ検証](docs/verification.md#レジストリの削除と復元)に従い、実レジストリの往復検証とは区別する。
- 導入: installer・共通指示・登録解除変更では`scripts/Verify-LatestInstall.ps1`を実行する。fixtureと実GitHub、保存内容と実ホストhook読込・承認・guide遵守を区別する。移行開始後の失敗で旧binaryへrollbackせず新exe/設定/登録を保全し、同じCLIで再開できることを確認する。
- 起動時更新: `integration/start-prunlet-mcp.ps1`・`src/rust/update/`・公開ZIPの生成や登録を変更した場合は、[導入検証](docs/verification.md#latestインストーラー)の起動時更新の範囲も確認する。公開と同じZIPによる複数回更新、使用中の延期、独立hook、途中再開、登録改変の保全、ADSを含む容量上限を検証し、通常の導入検証だけで代替しない。未適用stageの認定・再利用を変更した場合は、同節の`Verify-UnappliedStartupStage.ps1`も実行し、実ホスト登録を含む完全更新との検証範囲の違いを明示する。

ゴミ箱全体の空化・既存項目の清掃を行わず、今回fixtureだけを扱う。検証後の保持・清掃は[検証手順](docs/verification.md#検証後の保持と清掃)に従い、未清掃パス・理由・再開条件を返す。

## 導入と文書

Dependabotと依存検証のworkflowを変更する場合は、[依存更新の境界](DESIGN.md#依存更新の境界)にある検証条件と読取り権限の境界を維持する。依存検証CIの成功は、変更内容に応じた上記の追加E2Eを代替しない。

対外表記ではREADME冒頭の副題を併記する。今後のX告知では本文と紹介画像に同じ副題を毎回含め、GitHubの説明欄も同じ表記に揃える。X告知本文には、README冒頭に沿った紹介文を毎回1文入れる。その紹介文には、`blocked by policy`による清掃の停止を減らす目的と、AIエージェントのファイル・フォルダー削除を専用CLI・MCPへ集約する使い方を含める。

latest導入の検証は`scripts/Install-Prunlet.ps1`の[導入契約](DESIGN.md#導入と検証の境界)に従い、開発クローンやローカルビルドで代用しない。[容量上限の一度だけの移行](DESIGN.md#容量上限の一度だけの移行)、既存設定とACLの保持、再更新時の冪等性、ロック・登録失敗時の原本保全と復旧も確認する。

MCP起動時の自動更新は手動導入とは別の経路である。[更新の設計](DESIGN.md#起動時自動更新)に従い、更新状態・製品排他・配布検証・容量検査を迂回しない。配布物は`scripts/Package-PrunletUpdate.ps1`で生成し、公開タグから生成するrelease workflowとの形式の一致を維持する。公開ZIPは`scripts/Verify-ReleasePackage.ps1 -PackagePath <ZIP絶対パス> -SourceRoot <ソース絶対パス> -PublishDirectory <publish絶対パス> -CommitSha <40桁SHA> -DefaultBranch <既定ブランチ> -Runtime <win-x64|win-arm64> -Repository <owner/repo>`で生成元と照合し、返されたZIP全体のSHA-256がアップロード直前にも一致することを確認する。

コードコメントは日本語。[README](README.md)は利用者向け、[DESIGN.md](DESIGN.md)は現在の設計、連携と検証の詳細は`docs/`、エージェントの作業規約は本ファイルに置き、同じ説明を複製せず参照する。
