# Prunletの開発

現在の構造と設計判断は[DESIGN.md](DESIGN.md)を参照する。削除処理は`src/Prunlet/Core`に集約し、CLI・MCP・フックで別の削除方式を実装しない。

Windowsのファイル・フォルダー・レジストリ削除は、配置済み共通指示のexe・設定の絶対パスを使い、最初から`cmd.exe`・`login: false`でPrunlet CLIを呼ぶ。空白・Unicode・多数・長いファイル対象は絶対パスのUTF-8 JSON一覧を`delete [--dry-run] --paths-file <絶対パス>`で渡す。レジストリは`registry-delete --view <32|64> ... -- <single-key-path>`を使う。exe・設定自体をCMDで安全に表現できない場合は実行前に同じCoreのMCPを選ぶ。拒否された削除を別shell・Prunletへ付け替えて再試行しない。詳細は[連携手順](docs/integration.md)を参照する。

ファイル・フォルダーは通常Windowsのゴミ箱へ移し、操作記録自体を作らない。Windowsが対象をゴミ箱には大きすぎると明示し、保持した実体と再固定した名前・親・属性が一致した場合だけ、同じ要求内で元の名前を永久削除する。サイズ超過以外の失敗や不明な結果からは永久削除へ切り替えない。操作ID・PIDL・File ID・内容hash・size・ACL snapshotを復元用に永続化せず、manifest・monitor・index・retirement・復元stageを新規作成しない。処理中の実体照合に使う一時handle・File IDとは区別する。ゴミ箱に移った項目の復元と保持管理はWindowsへ任せ、CLI/MCPのファイル復元を追加しない。共通の固定`maintenance.lock`は排他用であり操作記録ではない。`allowedRoots`は互換入力で、削除対象フォルダーの許可リストを設けない。独自退避・コピーfallback・自動昇格・リンク先走査を追加しない。中央metadata・レジストリ専用namespace・未移行の旧領域とその祖先を保護する。

`FileDeleteResult`は`dryRun`・`items`・`warnings`、各項目は`path`・`kind`・`status`・任意`error`である。状態は`recycled`・`permanently_deleted`・`would_recycle`・`already_absent`・`failed`・`ambiguous`で、`failed`と`ambiguous`は非成功として返す。Shellが返した項目を一時的に開き、事前に保持した元のFile IDと照合できない場合は`ambiguous`とする。dry-runでは永久削除の要否を予測できないことを警告する。不明な削除を自動再送せず、元対象とWindowsゴミ箱を確認する。

レジストリは[専用設計](DESIGN.md#レジストリの削除と復元)のstage・snapshot・永続化・commit順、完全security bytes照合、schema 5の作成時からの非公開ACL、曖昧状態の保全を維持する。非トランザクション削除へのfallbackを追加しない。`restore`（`registry-restore`の別名）・`operations`・`purge`・`maintain`はレジストリ専用で、MCPは5ツールを維持する。レジストリ記録は`backupDirectory/.registry-records-v1/{id}`へ置き、manifestの`MetadataRoot`は共通基点を保持する。

native sessionはscopeの明示選択を必要とする。検証起動は固定したPrepare入力に対する`Start -AssertNativeWindows`で行い、UAC同意を代行せず、実token・期限・入力固定・Run permitを検査する。切断後は同じ削除を再送せず`registry-reconcile <operation-id>`で照合する。

並列削除はclaim取得順・全preflight完了後の実行・process共通worker上限・ハードリンク検出時の排他再実行を維持する。MCP要求枠とfile worker枠を分け、registry privilege変更をfile workerと並行させない。

保持制御はレジストリschema 5専用で、既定7日・合計1 GiB、事前容量走査・整理前後再走査・共通ロック・単一超過時だけの予算を維持する。Windowsゴミ箱のファイルと未移行旧ファイルは容量・期限・purgeに含めない。ファイル削除・通常一覧・通常保守は旧ファイル操作ディレクトリを走査しない。手動整理はCLI明示適用のみで、MCPへpurgeを追加しない。

旧ファイルの復元互換を維持せず、明示`migrate`で所有確認済みの旧退避root・操作記録をWindowsゴミ箱へ破棄する。旧schemaのparser・decode・内容hash・ACL snapshot・コピー・bundle・sidecar・復元helperは追加しない。store/restoreの専用StoreKey rootと小marker、中央の正規file marker、typed root layoutで所有を確認し、registry signals・共通基点・他config/privateBase・未知の非所有領域を保護する。ファイル別の恒久一覧を作らず、固定private空gate `.legacy-file-discard-in-progress` だけで中断の自動再送を止める。正規gateの明示ackは`migrate --apply --retry-legacy-discard`のみで、installerは指定しない。fileの未完了はregistry利用を塞がない。policy 2評価済みの`--apply --if-needed`は中央旧GUID再走査を省き、更新時のonline owned store固定位置・小marker確認だけを続ける。通常file/list/maintainは旧領域を走査しない。

対応するCodexの`exec_command`では、ファイル・フォルダーの実削除を初回から`sandbox_permissions: "require_escalated"`で申請する。Windowsの管理者起動とは区別し、dry-runをゴミ箱アクセス許可の証拠にしない。[sandboxとゴミ箱へのアクセス](docs/integration.md#sandboxとゴミ箱へのアクセス)に従う。

## ビルドと検証

Windows・.NET 10 SDK・PowerShell 7を使う。ビルドは`scripts/Publish-Prunlet.ps1`に外部の絶対出力先を渡す。直接の`dotnet build` / `dotnet publish`でリポジトリへ出力しない。

```powershell
$buildRoot = Join-Path 'D:\Codex\Prunlet' ('build-' + [guid]::NewGuid().ToString('N'))
pwsh -NoProfile -File .\scripts\Publish-Prunlet.ps1 -OutputDirectory $buildRoot
```

出力は`$buildRoot\publish\prunlet.exe`。既定は`win-x64`、ARM64向けは`-Runtime win-arm64`を指定する。metadata・TEMP/TMP・fixture・reportは外部D絶対パスへ隔離し、reportの親を事前作成する。リポジトリおよびCodex homeへ`bin`・`obj`・一時物・検証出力・バックアップを作らない。

実装後は[検証手順](docs/verification.md)の記録なしファイルE2Eと、影響に応じたレジストリ・旧データ移行・導入検証を行う。CLI・stdio MCP・hookの実プロセス、終了コード・passed/failed・外部JSONを読んで判定する。skip・CaseFilterだけの成功や未実行を全件合格にしない。

- ファイル: `scripts/Verify-RecordlessFiles.ps1`へ今回のexeと新しい外部出力・reportを渡す。結果DTO、操作記録不作成、dry-run不変更、Windowsゴミ箱往復、内容/ID/属性/ACL/ADS、リンク先保全・ハードリンク共有、再帰・拒否・不明状態を確認する。
- フック解析: shell選択・文字列解析を変更した場合は`scripts/Verify-HookParsing.ps1 -ExecutablePath <今回のexe絶対パス> -OutputDirectory <未使用の外部D絶対パス> -ReportPath <外部JSON絶対パス> -ConfigPath <設定絶対パス>`を実行する。検査用コマンド文字列を直接実行せず、hookへのJSON入力で許可・拒否とfixture不変更を確認する。範囲と判定は[検証手順](docs/verification.md#通常e2eの検証範囲)に従う。
- 旧データ移行: `scripts/Verify-FileRecordMigration.ps1`へ今回のexeと真正な旧版exeを渡す。旧schema fixtureを新版で捏造せず、所有済み旧rootの直接Bin破棄、壊れたfile本文の非読取、registry混在/他config/未知非所有領域の保護、dry-run不変更・gate不作成、中断後の自動再送拒否・明示ack、policy 0→2と更新時の後online store回収を確認する。旧file復元・bundle・sidecar・copy・履歴圧縮は成功条件へ残さない。
- 並行・待機: 同一対象・親子・共有ハードリンクの排他、全preflight失敗時保全、process worker上限、入力順を確認する。60秒超ロック待機と解放後続行、CLI stderr/stdout、MCP token付き進捗と最終応答後抑止、EOF後完了を確認する。
- レジストリ: `scripts/Verify-RegistryRecovery.ps1`と、native sessionの`Verify-RegistrySession.ps1`のPrepare・Start（`-AssertNativeWindows`）・Current・Runを使う。完全ACL/raw bytes・競合・transaction・snapshot保全・専用namespace/予算を確認する。同じexeのcurrent側6801拒否保全と明示native側CLI/MCP正常往復、実token・view/scopeを区別し、権限・KTM・viewの未検証を成功に数えない。
- 導入: installer・共通指示・登録解除変更では`scripts/Verify-LatestInstall.ps1`を実行する。fixtureと実GitHub、保存内容と実ホストhook読込・承認・guide遵守を区別する。移行開始後の失敗で旧binaryへrollbackせず新exe/設定/登録を保全し、同じCLIで再開できることを確認する。

ゴミ箱全体の空化・既存項目の清掃を行わず、今回fixtureだけを扱う。検証後の保持・清掃は[検証手順](docs/verification.md#検証後の保持と清掃)に従い、未清掃パス・理由・再開条件を返す。

## 導入と文書

Dependabotと依存検証・自動マージのworkflowを変更する場合は、[依存更新の境界](DESIGN.md#依存更新の境界)にある検証条件と権限分離を維持する。依存検証CIの成功は、変更内容に応じた上記の追加E2Eを代替しない。

対外表記ではREADME冒頭の副題を併記する。今後のX告知では本文と紹介画像に同じ副題を毎回含め、GitHubの説明欄も同じ表記に揃える。X告知本文には、README冒頭に沿った紹介文を毎回1文入れる。その紹介文には、`blocked by policy`による清掃の停止を減らす目的と、AIエージェントのファイル・フォルダー削除を専用CLI・MCPへ集約する使い方を含める。

利用者向け導入は`scripts/Install-Prunlet.ps1`でGitHubの既定ブランチ最新HEADを解決する。開発クローンやローカルビルドをlatest導入の代用にしない。インストール元のリポジトリ・取得ブランチ・コミットは`source-info.json`へ記録する。既存設定は[容量上限の一度だけの移行](DESIGN.md#容量上限の一度だけの移行)を除いて保持する。旧復元データはCoreの明示`migrate`で移行し、通常APIから変更しない。設定読込・dry-runへ暗黙の適用を持ち込まず、移行済み印と移行後の利用者変更を尊重する。導入検証では、旧容量からの移行、未知の設定とACLの保持、再更新時の冪等性、ロック・登録失敗時の原本保全と復旧も確認する。

依存追加、公開、バージョン変更、Gitのコミット・プッシュは今回の依頼に含まれる場合だけ行う。コードコメントは日本語。[README](README.md)は利用者向け、[DESIGN.md](DESIGN.md)は現在の設計、連携と検証の詳細は`docs/`、エージェントの作業規約は本ファイルに置き、同じ説明を複製せず参照する。
