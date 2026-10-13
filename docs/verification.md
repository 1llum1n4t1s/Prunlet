# E2E検証

CLI・MCP・Codexフックを実際の別プロセスで起動して検証します。ユニットテストは使用しません。

```powershell
$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('Codex\Prunlet\verification-' + [guid]::NewGuid().ToString('N'))
$report = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Codex\TaskArtifacts\Prunlet\verification-' + [guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-Prunlet.ps1 -ExecutablePath 'C:\path\to\prunlet.exe' -OutputDirectory $runRoot -ReportPath $report
```

`OutputDirectory`と`ReportPath`は新しい外部パスを指定します。レポートの親ディレクトリは事前に用意してください。検証用フォルダーには、この実行が作る使い捨てのファイル・設定・バックアップだけを置きます。標準出力の`passed`と`failed`、終了コード、JSONレポートを確認します。

検証範囲は、削除と復元の内容・時刻一致、欠損、dry-run、scope外・リンク・ADS・ロックの拒否、復元先の競合、復元データ改竄、MCPの実通信と不正引数、フック置換後の実削除、曖昧なコマンド拒否、登録の冪等性と解除時の既存設定保持です。各ケースの所要時間と実行exeのSHA-256を記録します。

検証完了後はレポートを保持し、リンクとプロセスの終了を確認して今回の`OutputDirectory`だけを清掃します。既存の共有キャッシュ、ほかの作業、一度インストールしたexe、利用者の復元用データは対象にしません。

このE2EはCodexがフックを実際に読み込み、入力置換や承認を行うことまでは確認しません。登録後はCodexで新しいチャットを開始し、使い捨てのファイルに対する単独削除を実行して、フックの読込・置換・CLI結果を照合してください。

## latestインストーラー

```powershell
$latestRun = Join-Path ([IO.Path]::GetTempPath()) ('Codex\Prunlet\latest-verification-' + [guid]::NewGuid().ToString('N'))
$latestReport = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Codex\TaskArtifacts\Prunlet\latest-verification-' + [guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path -Parent $latestReport) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-LatestInstall.ps1 -OutputDirectory $latestRun -ReportPath $latestReport -CheckPublicHead
```

GitHub応答を検証用アーカイブへ差し替え、実際のインストーラー・.NETビルド・配置・Codex登録を通すE2Eです。最新HEADの再解決、同一SHAからの導入、クローンに依存しない登録、既存設定と復元データの保持、ZIPの不正経路・重複・リンク、取得とビルドの失敗、製品更新の失敗時の復元を検証します。Codex設定がロックされて登録が途中で失敗した場合の復旧と、作業場所が許可ルート配下にある場合の導入も確認します。実ユーザーの配置先・Codex設定は使いません。

`-CheckPublicHead`では実際のGitHubも参照します。リモートに必要な実装がまだない場合は、配置先を変更せず停止することを確認します。検証用アーカイブでの成功を、実GitHubからの導入成功として扱いません。公開後は実GitHubから導入し、`source-info.json`のリポジトリ・ブランチ・コミット、配置済みexeと登録先を照合してください。

共通指示の登録では、明示オプションなしの不変更、既存AGENTSの保持、冪等な登録と解除、利用者編集の保護、登録途中の失敗時の復旧を隔離したCodex homeで確認します。実ユーザーの共通AGENTS本文はこのE2Eで変更しません。実登録後は、専用guideと管理マーカーの保存内容、新しいチャットでの読込、最初からMCPが選ばれた実動作を分けて確認してください。
