# Prunletの開発

現在の構造と設計判断は[DESIGN.md](DESIGN.md)を参照する。削除処理は`src/Prunlet/Core`に集約し、CLI・MCP・フックで別の削除方式を実装しない。

Windowsのファイル削除は、配置済み共通指示のexe・設定の絶対パスを使い、最初から`cmd.exe`・`login: false`でPrunlet CLIを呼ぶ。空白・Unicode・多数・長い対象は絶対パスのUTF-8 JSON一覧を`delete [--dry-run] --paths-file <絶対パス>`で渡す。exe・設定自体をCMDで安全に表現できない場合は実行前に同じCoreのMCPを選ぶ。拒否された削除を別shell・Prunletへ付け替えて再試行しない。詳細は[連携手順](docs/integration.md)を参照する。

削除対象フォルダーの許可リストは設けず、既存の`allowedRoots`は互換入力として扱う。復元データ保存先の保護、リンク先を辿らない処理、検証済みバックアップを永続化してから削除する順序、既存ファイルを上書きしない復元を維持する。フックはネイティブexeによる入力検査・拒否とCLI案内を担当し、削除・自動置換・PowerShell backend起動を行わない。ホストの承認・管理ポリシーを無効化しない。

復元データの整理を変更する場合は、[整理の設計](DESIGN.md#復元データの自動整理)に従う。既定は7日・合計10 GiBとし、期限切れと容量超過時の古いコピーを自動整理する。intentの永続化、検証済みコピーだけの削除、記録とロックの保持を維持する。手動整理はCLIの明示適用とし、MCPへのpurge追加は行わない。

## ビルドと検証

Windows、.NET 10 SDK、PowerShell 7を使う。ビルドは`scripts/Publish-Prunlet.ps1`に外部の絶対出力先を渡す。直接の`dotnet build` / `dotnet publish`でリポジトリへ出力しない。

```powershell
$buildRoot = Join-Path ([IO.Path]::GetTempPath()) ('Codex\Prunlet\build-' + [guid]::NewGuid().ToString('N'))
pwsh -NoProfile -File .\scripts\Publish-Prunlet.ps1 -OutputDirectory $buildRoot
```

出力は`$buildRoot\publish\prunlet.exe`。既定は`win-x64`、ARM64向けは`-Runtime win-arm64`を指定する。

実装変更後は[検証手順](docs/verification.md)のコマンドで`scripts/Verify-Prunlet.ps1`に今回のexeを渡し、CLI・stdio MCP・フックのE2Eを実行する。インストーラーや共通指示の登録・解除を変更した場合は`scripts/Verify-LatestInstall.ps1`も実行し、検証用アーカイブの結果と実GitHubの結果を区別する。終了コード、`passed` / `failed`、外部JSONレポートを読んで判定する。Codex自身のフック読込・承認と共通指示の読込・MCP選択はスクリプトの検証範囲外なので、連携変更時は同文書の実ホスト確認も行う。

case-sensitive属性の復元を変更した場合は、通常E2Eの権限別ケースで、必要権限を付与した復元の成功、属性変更権限不足時の失敗と復元コピーの保全、同じ属性への不要な書込みをせずModify権限で復元できることを確認する。成功ケースだけで権限不足時の安全性を判断しない。

大量操作に関係する変更では、通常E2Eに加えて`scripts/Verify-LargeOperations.ps1`へ今回のexeを渡す。[大量操作と途中バックアップの検証手順](docs/verification.md#大量操作と途中バックアップ)に従い、件数・記録サイズが旧上限を超えるschema 2/3の削除・復元・整理を確認する。

保持期限・容量制限を変更した場合は、通常E2Eに加えて`scripts/Verify-Retention.ps1`へ今回のexeを渡す。[自動整理の検証手順](docs/verification.md#復元データの自動整理)に従い、旧設定の互換性、整理できないコピーの保全、並行削除時の容量上限を確認する。定期タスクの登録・解除を変更した場合は`scripts/Verify-LatestInstall.ps1`で所有者検証、既存タスクの保持、登録失敗時の復旧も確認する。

リポジトリおよびCodex homeへ`bin`・`obj`・一時物・検証出力・バックアップを作らない。検証用出力とレポートには新しい外部絶対パスを渡し、レポートの親を事前に作る。検証後の保持と清掃は[検証手順](docs/verification.md)に従う。

履歴圧縮を変更した場合は、通常E2Eに加えて`scripts/Verify-HistoryCompaction.ps1`でdry-runの不変更、物理容量の減少とJSON内容一致、冪等性、既存操作IDの互換性、ロック・リンク・不正metadataの保持を確認する。自動経路は`scripts/Verify-AutomaticHistory.ps1`でmaintain・CLI/MCP削除からの発火、保護対象の保持、既圧縮の再実行と容量集計の分離を確認し、`scripts/Verify-AutomaticHistorySchedule.ps1`で隔離した一回限りの時刻トリガーによる実行を確認する。手順は[履歴圧縮の検証](docs/verification.md#操作履歴の圧縮)を参照する。

## 導入と文書

対外表記ではREADME冒頭の副題を併記する。今後のX告知では本文と紹介画像に同じ副題を毎回含め、GitHubの説明欄も同じ表記に揃える。X告知本文には、README冒頭に沿った紹介文を毎回1文入れる。その紹介文には、`blocked by policy`による清掃の停止を減らす目的と、AIエージェントのファイル・フォルダー削除を専用CLI・MCPへ集約する使い方を含める。

利用者向け導入は`scripts/Install-Prunlet.ps1`でGitHubの既定ブランチ最新HEADを解決する。開発クローンやローカルビルドをlatest導入の代用にしない。インストール元のリポジトリ・取得ブランチ・コミットは`source-info.json`へ記録し、既存設定と復元データを保持する。

依存追加、公開、バージョン変更、Gitのコミット・プッシュは今回の依頼に含まれる場合だけ行う。コードコメントは日本語。[README](README.md)は利用者向け、[DESIGN.md](DESIGN.md)は現在の設計、連携と検証の詳細は`docs/`、エージェントの作業規約は本ファイルに置き、同じ説明を複製せず参照する。
