# Prunletの開発

現在の構造と設計判断は[DESIGN.md](DESIGN.md)を参照する。削除処理は`src/Prunlet/Core`に集約し、CLI・MCP・フックで別の削除方式を実装しない。

許可範囲、リンク拒否、検証済みバックアップを永続化してから削除する順序、既存ファイルを上書きしない復元を維持する。フックは入力の検査・置換を担当し、削除を実行しない。ホストの承認・管理ポリシーを無効化しない。

## ビルドと検証

Windows、.NET 10 SDK、PowerShell 7を使う。ビルドは`scripts/Publish-Prunlet.ps1`に外部の絶対出力先を渡す。直接の`dotnet build` / `dotnet publish`でリポジトリへ出力しない。

```powershell
$buildRoot = Join-Path ([IO.Path]::GetTempPath()) ('Codex\Prunlet\build-' + [guid]::NewGuid().ToString('N'))
pwsh -NoProfile -File .\scripts\Publish-Prunlet.ps1 -OutputDirectory $buildRoot
```

出力は`$buildRoot\publish\prunlet.exe`。既定は`win-x64`、ARM64向けは`-Runtime win-arm64`を指定する。

実装変更後は[検証手順](docs/verification.md)のコマンドで`scripts/Verify-Prunlet.ps1`に今回のexeを渡し、CLI・stdio MCP・フックのE2Eを実行する。インストーラーや共通指示の登録・解除を変更した場合は`scripts/Verify-LatestInstall.ps1`も実行し、検証用アーカイブの結果と実GitHubの結果を区別する。終了コード、`passed` / `failed`、外部JSONレポートを読んで判定する。Codex自身のフック読込・承認と共通指示の読込・MCP選択はスクリプトの検証範囲外なので、連携変更時は同文書の実ホスト確認も行う。

リポジトリおよびCodex homeへ`bin`・`obj`・一時物・検証出力・バックアップを作らない。検証用出力とレポートには新しい外部絶対パスを渡し、レポートの親を事前に作る。検証後の保持と清掃は[検証手順](docs/verification.md)に従う。

## 導入と文書

利用者向け導入は`scripts/Install-Prunlet.ps1`でGitHubの既定ブランチ最新HEADを解決する。開発クローンやローカルビルドをlatest導入の代用にしない。インストール元のリポジトリ・取得ブランチ・コミットは`source-info.json`へ記録し、既存設定と復元データを保持する。

依存追加、公開、バージョン変更、Gitのコミット・プッシュは今回の依頼に含まれる場合だけ行う。コードコメントは日本語。[README](README.md)は利用者向け、[DESIGN.md](DESIGN.md)は現在の設計、連携と検証の詳細は`docs/`、エージェントの作業規約は本ファイルに置き、同じ説明を複製せず参照する。
