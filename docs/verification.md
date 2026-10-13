# E2E検証

CLI・MCP・Codexフックを実際の別プロセスで起動して検証します。ユニットテストは使用しません。

```powershell
$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('Codex\Prunlet\verification-' + [guid]::NewGuid().ToString('N'))
$report = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Codex\TaskArtifacts\Prunlet\verification-' + [guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-Prunlet.ps1 -ExecutablePath 'C:\path\to\prunlet.exe' -OutputDirectory $runRoot -ReportPath $report
```

`OutputDirectory`と`ReportPath`は新しい外部パスを指定します。レポートの親ディレクトリは事前に用意してください。検証用フォルダーには、この実行が作る使い捨てのファイル・設定・バックアップだけを置きます。標準出力の`passed`と`failed`、終了コード、JSONレポートを確認します。

検証範囲は、削除と復元の内容・時刻一致、欠損、dry-run、scope外・リンク・ADS・ロックの拒否、復元先の競合、復元データ改竄、MCPの実通信と不正引数、ネイティブフックの直接削除拒否・通常入力の通過、登録の冪等性と解除時の既存設定保持です。各ケースの所要時間と実行exeのSHA-256を記録します。

CLIのJSON一覧では1〜256件・最大1 MiB・不正JSON・不正パス・重複を確認し、空白・Unicode・多数・長い対象をCMDから渡します。長い既存ファイルと本当の欠損を区別し、長いディレクトリ、ADS・リンク・aliasの拒否、通常パスとの互換性を確認します。既存の拒否対象を再試行せず、新規fixtureだけを使います。purgeは既定dry-run・明示apply・コピーの内容検証・metadata保持・復元拒否・不正記録と複数リンク拒否・有効なintentからの再開を検証します。

purge記録の公開では、操作ディレクトリ外のバックアップルートに部分的な`purge-pending-*.json`を置くfixtureを使い、有効なintentからの再開を妨げず、未知draftも自動削除しないことを確認します。これは強制終了後の残存形状を用意したE2Eです。実プロセス強制終了、`Flush(true)`障害注入、電源断による永続化は未検証です。公開前draftと最終intent・結果を区別し、詳細な順序は[設計](../DESIGN.md#復元データの明示整理)を参照してください。

フック入力はPowerShell・CMDの引用符直前のbackslash、CMDの`@del`と静的条件の`IF`を含めて拒否・通過結果を確認します。インストーラー検証には、exe・設定の独自パスを登録した手動導入の解除を含めます。これらの入力・登録スクリプトE2Eと、実Codexホストの解釈は別の検証です。

検証完了後はレポートを保持し、リンクとプロセスの終了を確認して今回の`OutputDirectory`だけを清掃します。既存の共有キャッシュ、ほかの作業、一度インストールしたexe、利用者の復元用データは対象にしません。

このE2EはCodexがフックを実際に読み込み、拒否や承認を行うことまでは確認しません。登録後はCodexで新しいチャットを開始し、新規の使い捨てfixtureでフックの読込・直接削除の拒否、配置済み絶対exe・設定を使うCMD CLI結果を照合してください。実ホストの引用符処理、共通指示に従った初回CLI選択、PowerShellがホストに拒否される環境での動作は、それぞれ実測するまで未検証です。ホストの拒否を別shell・Prunletへ付け替えて再試行しません。

## latestインストーラー

更新バックアップも`OutputDirectory\update-backups`へ隔離し、`-UpdateBackupRoot`で実体のパスを渡します。実ユーザーの更新バックアップを検証用の保存先に使いません。

```powershell
$latestRun = Join-Path ([IO.Path]::GetTempPath()) ('Codex\Prunlet\latest-verification-' + [guid]::NewGuid().ToString('N'))
$latestReport = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Codex\TaskArtifacts\Prunlet\latest-verification-' + [guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path -Parent $latestReport) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-LatestInstall.ps1 -OutputDirectory $latestRun -ReportPath $latestReport -CheckPublicHead
```

GitHub応答を検証用アーカイブへ差し替え、実際のインストーラー・.NETビルド・配置・Codex登録を通すE2Eです。最新HEADの再解決、同一SHAからの導入、クローンに依存しない登録、既存設定と復元データの保持、ZIPの不正経路・重複・リンク、取得とビルドの失敗、製品更新の失敗時の復元を検証します。Codex設定がロックされて登録が途中で失敗した場合の復旧と、作業場所が許可ルート配下にある場合の導入も確認します。実ユーザーの配置先・Codex設定は使いません。

`-CheckPublicHead`では実際のGitHubも参照します。リモートに必要な実装がまだない場合は、配置先を変更せず停止することを確認します。検証用アーカイブでの成功を、実GitHubからの導入成功として扱いません。公開後は実GitHubから導入し、`source-info.json`のリポジトリ・ブランチ・コミット、配置済みexeと登録先を照合してください。

共通指示の登録では、明示オプションなしの不変更、既存AGENTSの保持、配置済みexe・設定のbinding、既知の旧MCP優先ブロックとguideハッシュに一致する移行、冪等な登録と解除、利用者編集の保護、登録途中の失敗時の復旧を隔離したCodex homeで確認します。旧配置済みPowerShell backendの退役では、製品バックアップとCoreによるバックアップ付き削除を照合します。実ユーザーの共通AGENTS本文はこのE2Eで変更しません。実登録後は、専用guide・管理マーカー・bindingの保存内容、新しいチャットでの読込、最初からCMD CLIが選ばれた実動作を分けて確認してください。
