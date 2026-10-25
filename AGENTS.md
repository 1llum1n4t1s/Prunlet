# Prunletの開発

現在の構造と設計判断は[DESIGN.md](DESIGN.md)を参照する。削除処理は`src/Prunlet/Core`に集約し、CLI・MCP・フックで別の削除方式を実装しない。

Windowsのファイル・フォルダー・レジストリ削除は、配置済み共通指示のexe・設定の絶対パスを使い、最初から`cmd.exe`・`login: false`でPrunlet CLIを呼ぶ。空白・Unicode・多数・長いファイル対象は絶対パスのUTF-8 JSON一覧を`delete [--dry-run] --paths-file <絶対パス>`で渡す。レジストリは`registry-delete --view <32|64> ... -- <single-key-path>`を使う。exe・設定自体をCMDで安全に表現できない場合は実行前に同じCoreのMCPを選ぶ。拒否された削除を別shell・Prunletへ付け替えて再試行しない。詳細は[連携手順](docs/integration.md)を参照する。

削除対象フォルダーの許可リストは設けず、`allowedRoots`は互換入力として扱う。新規ファイル・フォルダーはschema 6でWindowsのゴミ箱へ移し、操作intent・PIDL・File ID・全項目のOwner/Group/DACLを永続化してCLI・MCPの非上書き復元へ結び付ける。復元時は[設計](DESIGN.md#削除と復元のデータフロー)に従い、同一ボリュームstageのintent・完全照合・ready・非上書き公開の順序を維持する。readyのない既存stageや公開済み原本へACL・属性を再適用しない。永久削除・独自退避へのfallback、自動昇格、リンク先の走査は追加しない。中央metadata・復元stage・既存のボリューム別専用領域を保護する。schema 1/2/3のコピーとschema 4の専用renameは既存記録の復元・整理の互換経路に限定する。フックはネイティブexeによる検査・拒否とCLI案内だけを担当し、ホストの承認・管理ポリシーを維持する。

レジストリ変更では[レジストリの設計](DESIGN.md#レジストリの削除と復元)のstage・snapshot・永続化・commitの順序、完全なsecurity bytesの照合、schema 5の作成時からの非公開ACL、曖昧な状態の保全を維持する。非トランザクション削除へのfallbackは追加しない。native sessionはscopeの明示選択を必要とする。検証用の起動は固定したPrepare入力に対する`Start -AssertNativeWindows`で行い、UACの同意を代行せず、実token・期限・入力固定・Run permitを検査する。切断時は同じ削除を再送せず`registry-reconcile <operation-id>`で照合する。

並列削除・ハードリンク復元の変更では[削除と復元のデータフロー](DESIGN.md#削除と復元のデータフロー)のclaim取得順、全preflight完了後のmanifest公開、process共通worker上限、hardlink検出時の排他再実行を維持する。共有実体の復元はtransition chainと単一group-readyに従い、旧schema 6へ証拠を後付けしない。MCPの要求枠と削除worker枠を分け、レジストリのprivilege変更をfile workerと並行させない。

Prunletの[保持制御](DESIGN.md#復元データの自動整理)は旧schema 1〜4とレジストリschema 5を対象とし、既定7日・合計1 GiB、事前容量走査・整理前後の再走査・共通ロック・単一超過時だけの予算を維持する。新schema 6の実体はWindows管理で、Prunletの容量・期限・purge対象にしない。新規filedeleteは旧保持制御を起動せず、レジストリ削除前・明示maintain・非表示の定期保守で旧データを整理する。手動整理はCLI明示適用のみ、MCPへpurgeは追加しない。

対応するCodexの`exec_command`では、ファイル・フォルダーの実削除と復元を初回から`sandbox_permissions: "require_escalated"`で申請する。Windowsの管理者起動とは区別し、dry-runの成功をゴミ箱へのアクセス許可の証拠にしない。[sandboxとゴミ箱へのアクセス](docs/integration.md#sandboxとゴミ箱へのアクセス)に従い、不確かな結果は記録と実体を照合してから判断する。

## ビルドと検証

Windows、.NET 10 SDK、PowerShell 7を使う。ビルドは`scripts/Publish-Prunlet.ps1`に外部の絶対出力先を渡す。直接の`dotnet build` / `dotnet publish`でリポジトリへ出力しない。

```powershell
$buildRoot = Join-Path 'D:\Codex\Prunlet' ('build-' + [guid]::NewGuid().ToString('N'))
pwsh -NoProfile -File .\scripts\Publish-Prunlet.ps1 -OutputDirectory $buildRoot
```

出力は`$buildRoot\publish\prunlet.exe`。既定は`win-x64`、ARM64向けは`-Runtime win-arm64`を指定する。

実装変更後は[検証手順](docs/verification.md)のゴミ箱E2Eへ今回のexe、変更前1.0.9の`LegacyExecutablePath`、schema 4を生成する変更前1.0.11の`MoveExecutablePath`を渡す。同じ新版で旧fixtureを作らない。CLI・stdio MCP・フックの実プロセス、終了コード・passed/failed・外部JSONを読んで判定する。インストーラーや共通指示の登録・解除を変更した場合は`scripts/Verify-LatestInstall.ps1`も実行し、fixtureと実GitHubを区別する。実ホストのhook読込・承認・共通指示の遵守はスクリプトとは別に確認する。

検証のmetadata・TEMP/TMP・レポートは外部D絶対パスへ隔離する。schema 4 fixtureの`volumeRecoveryDirectories`は同Dに指定し本番領域を使わない。schema 1〜4は変更前exeで作った記録を新版でrestore・purge・maintainする。新schema 6は今回のfixture項目だけを扱い、ゴミ箱全体の空化・既存項目の清掃は行わない。

変更対象ごとの追加検証は[検証手順](docs/verification.md)に従う。

- ロック待機・通知: 60秒超の待機と解放後の続行、元対象・退避実体の保全、CLIのstderrとstdout JSON、MCPのtoken付き進捗と最終応答後の通知抑止を確認する。新規renameの拒否と旧コピーの削除保留待機を区別する。
- 並列削除・共有ハードリンク: `scripts/Verify-ConcurrentDeletion.ps1 -ExecutablePath <今回のexe> -LegacyHardlinkExecutablePath <変更前のschema 6対応exe> -OutputDirectory <新しい外部D絶対パス> -ReportPath <外部JSONパス>`で独立対象の並行完了、同一対象・親子の排他、preflight失敗時の全対象保全、入力順、MCPの進捗分離とEOF後の完了を確認する。共有実体の復元は`scripts/Verify-HardlinkBatch.ps1`へ`-ExecutablePath`、別の未使用出力・レポートと`-LegacyExecutablePath <変更前のschema 6対応exe>`を渡し、競合・改変・中断再開も確認する。この旧exeはschema 1〜4用の版と区別し、旧版専用設定から`capacityDefaultMigrationVersion`を除く既存runnerを使う。skipや選択ケースだけの成功を全件合格にしない。性能比較には`Verify-ConcurrentDeletion.ps1`へ別途`-BaselineExecutablePath`を渡す。
- 通常属性・case-sensitive・ACL・ADS・リンク: 同一オブジェクトとして保持されること、dry-runと拒否時の不変更、リンク先の保全、ハードリンク外部別名との共有関係、旧形式の属性復元と権限不足時のコピー保全を確認する。`Verify-VolumeMoves.ps1`の退避中rootのACL比較では、Inheritedフラグと標準APIによるAllow ACEの分割・統合だけを同値として扱い、所有者・グループ・主体・権利・継承範囲・伝播を保持する。Denyや未知のACEは順序も照合し、権利・伝播・Denyの改変を検出するケースを維持する。子項目と復元後はSDDLの完全一致を確認する。
- 大量操作: ゴミ箱方式は`Verify-RecycleBin.ps1 -Large`で再帰rootのFile ID・内容と非上書き往復を確認する。schema 4の専用領域と旧schema 1/2/3の大規模記録は互換検証へ分離する。
- 削除速度: 変更前exeと同条件で複数回比較し、安全性と内容・IDの保持、衝突時の非上書き、各試行・中央値を確認する。旧コピー方式の性能値を新方式へ流用しない。
- 保持制御: schema 6の項目が期限・容量・purgeから除外されること、旧1〜4とレジストリ5の合算容量・整理前後走査・超過時予算・破損保全を確認する。定期タスクは所有者・既存設定保持・登録失敗時復旧も確認する。
- 履歴圧縮: schema 4/5/6は理由付きretained、旧1/2/3は従来のNTFS圧縮、JSON内容一致・冪等性・ロック保全・容量集計分離を確認する。
- レジストリ: `scripts/Verify-RegistryRecovery.ps1 -ExecutablePath <今回のexe> -OutputDirectory <外部絶対パス> -ReportPath <外部JSONパス>`を実行し、[専用検証手順](docs/verification.md#レジストリの削除と復元)に従って完全ACL・raw bytes・競合・曖昧な記録・混在予算・CLI/MCP/hookを確認する。native sessionは同手順に従い`scripts/Verify-RegistrySession.ps1`のPrepare・Start（`-AssertNativeWindows`）・Current・Runを実行し、current側の6801拒否時の保全と明示native側のCLI・MCP正常往復を同じ対象exeで確認する。通常・管理者の実際の起動tokenを区別し、MSIX仮想viewと通常Windowsの同名キーを同一視しない。権限・KTM・viewの未検証範囲を成功に数えない。

リポジトリおよびCodex homeへ`bin`・`obj`・一時物・検証出力・バックアップを作らない。TEMP/TMP・ビルド・fixture・レポートには外部絶対パスを渡し、レポートの親を事前に作る。検証後の保持と清掃は[検証手順](docs/verification.md)に従う。移行前提が合わないスクリプトの失敗・未実行は合格扱いせず、未検証範囲を報告する。

## 導入と文書

Dependabotと依存検証・自動マージのworkflowを変更する場合は、[依存更新の境界](DESIGN.md#依存更新の境界)にある検証条件と権限分離を維持する。依存検証CIの成功は、変更内容に応じた上記の追加E2Eを代替しない。

対外表記ではREADME冒頭の副題を併記する。今後のX告知では本文と紹介画像に同じ副題を毎回含め、GitHubの説明欄も同じ表記に揃える。X告知本文には、README冒頭に沿った紹介文を毎回1文入れる。その紹介文には、`blocked by policy`による清掃の停止を減らす目的と、AIエージェントのファイル・フォルダー削除を専用CLI・MCPへ集約する使い方を含める。

利用者向け導入は`scripts/Install-Prunlet.ps1`でGitHubの既定ブランチ最新HEADを解決する。開発クローンやローカルビルドをlatest導入の代用にしない。インストール元のリポジトリ・取得ブランチ・コミットは`source-info.json`へ記録する。既存設定は[容量上限の一度だけの移行](DESIGN.md#復元データの自動整理)を除いて保持し、復元データを変更しない。設定読込・dry-runへ移行を持ち込まず、移行済み印と移行後の利用者変更を尊重する。導入検証では、旧容量からの移行、未知の設定とACLの保持、再更新時の冪等性、ロック・登録失敗時の原本保全と復旧も確認する。

依存追加、公開、バージョン変更、Gitのコミット・プッシュは今回の依頼に含まれる場合だけ行う。コードコメントは日本語。[README](README.md)は利用者向け、[DESIGN.md](DESIGN.md)は現在の設計、連携と検証の詳細は`docs/`、エージェントの作業規約は本ファイルに置き、同じ説明を複製せず参照する。
