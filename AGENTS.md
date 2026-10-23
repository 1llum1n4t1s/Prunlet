# Prunletの開発

現在の構造と設計判断は[DESIGN.md](DESIGN.md)を参照する。削除処理は`src/Prunlet/Core`に集約し、CLI・MCP・フックで別の削除方式を実装しない。

Windowsのファイル削除は、配置済み共通指示のexe・設定の絶対パスを使い、最初から`cmd.exe`・`login: false`でPrunlet CLIを呼ぶ。空白・Unicode・多数・長い対象は絶対パスのUTF-8 JSON一覧を`delete [--dry-run] --paths-file <絶対パス>`で渡す。exe・設定自体をCMDで安全に表現できない場合は実行前に同じCoreのMCPを選ぶ。拒否された削除を別shell・Prunletへ付け替えて再試行しない。詳細は[連携手順](docs/integration.md)を参照する。

削除対象フォルダーの許可リストは設けず、既存の`allowedRoots`は互換入力として扱う。中央metadataとボリューム別専用領域の保護、リンク先を辿らない処理、File IDと移動intentを永続化してから同一ボリューム内でrenameする順序、既存ファイル・フォルダーを上書き・マージしない消費型復元を維持する。新規削除のコピー経路と異ボリュームへのfallbackは設けず、schema 1/2/3のコピー処理は既存記録の復元・整理の互換経路に限定する。フックはネイティブexeによる入力検査・拒否とCLI案内を担当し、削除・自動置換・PowerShell backend起動を行わない。ホストの承認・管理ポリシーを無効化しない。

復元データの整理を変更する場合は、[整理の設計](DESIGN.md#復元データの自動整理)に従う。既定は7日・合計10 GiBとし、期限切れと容量超過時の古い復元データを自動整理する。元対象の事前容量走査、新旧合計の整理前後の再走査、共通ロック、単一超過時だけの有効予算を維持する。新方式のFile ID・marker・receiptと旧コピーのサイズ・hashを検証し、intentの先行永続化、記録とロックの保持を維持する。手動整理はCLIの明示適用とし、MCPへのpurge追加は行わない。

## ビルドと検証

Windows、.NET 10 SDK、PowerShell 7を使う。ビルドは`scripts/Publish-Prunlet.ps1`に外部の絶対出力先を渡す。直接の`dotnet build` / `dotnet publish`でリポジトリへ出力しない。

```powershell
$buildRoot = Join-Path 'D:\Codex\Prunlet' ('build-' + [guid]::NewGuid().ToString('N'))
pwsh -NoProfile -File .\scripts\Publish-Prunlet.ps1 -OutputDirectory $buildRoot
```

出力は`$buildRoot\publish\prunlet.exe`。既定は`win-x64`、ARM64向けは`-Runtime win-arm64`を指定する。

実装変更後は[検証手順](docs/verification.md)の新方式E2Eに今回のexeと変更前1.0.9の`LegacyExecutablePath`を渡す。通常入口の振分けと各専用スクリプトの移行状態は同文書で確認し、新規通常経路へ旧コピー生成を戻さない。CLI・stdio MCP・フックの実プロセス検証、終了コード、`passed` / `failed`、外部JSONレポートを読んで判定する。インストーラーや共通指示の登録・解除を変更した場合は`scripts/Verify-LatestInstall.ps1`も実行し、検証用アーカイブと実GitHubの結果を区別する。Codex自身のフック読込・承認、共通指示の読込・CLI選択はスクリプト範囲外のため、連携変更時は実ホストで確認する。

検証fixtureの`volumeRecoveryDirectories`は対象と同じDボリュームの外部作業領域へ隔離し、本番の既定専用領域を使わない。中央metadataと専用baseは相互に包含させない。旧schema 1/2/3は変更前exeで作った記録のrestore・purge・maintainを新版で確認し、新版で旧コピーを新規生成する検証と混同しない。

変更対象ごとの追加検証は[検証手順](docs/verification.md)に従う。

- ロック待機・通知: 60秒超の待機と解放後の続行、元対象・退避実体の保全、CLIのstderrとstdout JSON、MCPのtoken付き進捗と最終応答後の通知抑止を確認する。新規renameの拒否と旧コピーの削除保留待機を区別する。
- 通常属性・case-sensitive・ACL・ADS・リンク: 同一オブジェクトとして保持されること、dry-runと拒否時の不変更、リンク先の保全、ハードリンク外部別名との共有関係、旧形式の属性復元と権限不足時のコピー保全を確認する。`Verify-VolumeMoves.ps1`の退避中rootのACL比較では、Inheritedフラグと標準APIによるAllow ACEの分割・統合だけを同値として扱い、所有者・グループ・主体・権利・継承範囲・伝播を保持する。Denyや未知のACEは順序も照合し、権利・伝播・Denyの改変を検出するケースを維持する。子項目と復元後はSDDLの完全一致を確認する。
- 大量操作: 新方式は`Verify-VolumeMoves.ps1 -Large`でroot単位の記録と容量走査、往復・消費型復元を確認する。旧32,768件・8 MiB超のschema 2/3は既存記録の互換検証として分離する。
- 削除速度: 変更前exeと同条件で複数回比較し、安全性と内容・IDの保持、衝突時の非上書き、各試行・中央値を確認する。旧コピー方式の性能値を新方式へ流用しない。
- 保持制御: 新旧合計の容量、事前走査と整理前後再走査、通常予算、複数入力合計が上限を超える操作の例外予算、次回の通常上限、整理不能時の元対象と復元データ保全、並行操作を確認する。定期タスク変更時は所有者検証、既存タスクの保持、登録失敗時の復旧も確認する。
- 履歴圧縮: schema 4は理由付きretained、旧1/2/3は従来のNTFS圧縮、JSON内容一致・冪等性・ロック保全・容量集計分離を確認する。自動経路と隔離した一回限りの時刻トリガーも対象とする。

リポジトリおよびCodex homeへ`bin`・`obj`・一時物・検証出力・バックアップを作らない。TEMP/TMP・ビルド・fixture・レポートには外部絶対パスを渡し、レポートの親を事前に作る。検証後の保持と清掃は[検証手順](docs/verification.md)に従う。移行前提が合わないスクリプトの失敗・未実行は合格扱いせず、未検証範囲を報告する。

## 導入と文書

Dependabotと依存検証・自動マージのworkflowを変更する場合は、[依存更新の境界](DESIGN.md#依存更新の境界)にある検証条件と権限分離を維持する。依存検証CIの成功は、変更内容に応じた上記の追加E2Eを代替しない。

対外表記ではREADME冒頭の副題を併記する。今後のX告知では本文と紹介画像に同じ副題を毎回含め、GitHubの説明欄も同じ表記に揃える。X告知本文には、README冒頭に沿った紹介文を毎回1文入れる。その紹介文には、`blocked by policy`による清掃の停止を減らす目的と、AIエージェントのファイル・フォルダー削除を専用CLI・MCPへ集約する使い方を含める。

利用者向け導入は`scripts/Install-Prunlet.ps1`でGitHubの既定ブランチ最新HEADを解決する。開発クローンやローカルビルドをlatest導入の代用にしない。インストール元のリポジトリ・取得ブランチ・コミットは`source-info.json`へ記録し、既存設定と復元データを保持する。

依存追加、公開、バージョン変更、Gitのコミット・プッシュは今回の依頼に含まれる場合だけ行う。コードコメントは日本語。[README](README.md)は利用者向け、[DESIGN.md](DESIGN.md)は現在の設計、連携と検証の詳細は`docs/`、エージェントの作業規約は本ファイルに置き、同じ説明を複製せず参照する。
