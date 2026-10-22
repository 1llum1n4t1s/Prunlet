# E2E検証

CLI・MCP・Codexフックを実際の別プロセスで起動して検証します。ユニットテストは使用しません。

```powershell
$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('Codex\Prunlet\verification-' + [guid]::NewGuid().ToString('N'))
$report = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Codex\TaskArtifacts\Prunlet\verification-' + [guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-Prunlet.ps1 -ExecutablePath 'C:\path\to\prunlet.exe' -OutputDirectory $runRoot -ReportPath $report
```

`OutputDirectory`と`ReportPath`は新しい外部パスを指定します。レポートの親ディレクトリは事前に用意してください。検証用フォルダーには、この実行が作る使い捨てのファイル・設定・バックアップだけを置きます。標準出力の`passed`と`failed`、終了コード、JSONレポートを確認します。

検証範囲は、読み取り専用ファイルの削除と通常属性の復元、dry-runの属性不変更、ACL拒否時の元属性とコピーの保全、属性のないschema 1/2/3旧記録の互換性、不正な属性値の拒否、圧縮の有無が変わる両方向での属性なし・Normalの復元、削除と復元の内容・時刻一致、欠損、dry-run、旧ルート外・ルート未指定設定での成功、復元データ保存先・ロックの拒否、リンク・ADS・ハードリンク・case-sensitiveの削除と復元、復元先の競合、復元データ改竄、MCPの実通信と不正引数、ネイティブフックの直接削除拒否・通常入力の通過、登録の冪等性と解除時の既存設定保持です。各ケースの所要時間と実行exeのSHA-256を記録します。

CLIのJSON一覧では1〜256件・最大1 MiB・不正JSON・不正パス・重複を確認し、空白・Unicode・多数・長い対象をCMDから渡します。長い既存ファイルと本当の欠損を区別し、長いディレクトリ、ADS・リンク自体の削除と復元、slash・拡張長ローカル表記・8.3別名の削除と復元、同一実体の重複拒否、別名経由の復元領域保護、旧schema 1記録を変更しない復元・整理を確認します。MSIXのAppData転送は実パッケージのCodexホストで新規fixtureを使い、入力と実体の同一性、削除・復元のバイト一致、記録の実体パスを別途確認します。既存の拒否対象を再試行せず、新規fixtureだけを使います。purgeは既定dry-run・明示apply・コピーの内容検証・metadata保持・復元拒否・不正記録と複数リンク拒否・有効なintentからの再開を検証します。

purge記録の公開では、操作ディレクトリ外のバックアップルートに部分的な`purge-pending-*.json`を置くfixtureを使い、有効なintentからの再開を妨げず、未知draftも自動削除しないことを確認します。これは強制終了後の残存形状を用意したE2Eです。実プロセス強制終了、`Flush(true)`障害注入、電源断による永続化は未検証です。公開前draftと最終intent・結果を区別し、詳細な順序は[設計](../DESIGN.md#復元データの明示整理)を参照してください。

フック入力はPowerShell・CMDの引用符直前のbackslash、CMDの`@del`と静的条件の`IF`を含めて拒否・通過結果を確認します。インストーラー検証には、exe・設定の独自パスを登録した手動導入の解除を含めます。これらの入力・登録スクリプトE2Eと、実Codexホストの解釈は別の検証です。

検証完了後はレポートを保持し、リンクとプロセスの終了を確認して今回の`OutputDirectory`だけを清掃します。既存の共有キャッシュ、ほかの作業、一度インストールしたexe、利用者の復元用データは対象にしません。

このE2EはCodexがフックを実際に読み込み、拒否や承認を行うことまでは確認しません。登録後はCodexで新しいチャットを開始し、新規の使い捨てfixtureでフックの読込・直接削除の拒否、配置済み絶対exe・設定を使うCMD CLI結果を照合してください。実ホストの引用符処理、共通指示に従った初回CLI選択、PowerShellがホストに拒否される環境での動作は、それぞれ実測するまで未検証です。ホストの拒否を別shell・Prunletへ付け替えて再試行しません。

## 一時的なロックとロード中DLL

共有ロックや削除保留設定の待機を変更した場合は、通常E2Eに加えて次を実行します。新しい外部絶対パスを指定し、レポートの親を事前に作成してください。

```powershell
pwsh -NoProfile -File .\scripts\Verify-TransientLocks.ps1 -ExecutablePath <今回のexe> -OutputDirectory <新しい外部Temp> -ReportPath <外部JSONレポート>
```

専用の復元領域で、CLIの起動時間に余裕を持たせて共通ロックを保持してから解放したときの成功、65秒以上保持してもCLIが生存し解放後に成功すること、DLLを実際にロードして削除準備後に解放したときの成功、ロード継続時の10秒タイムアウト、読み取り専用ファイルの削除・属性を含む復元と、ロード中の読み取り専用DLLを削除できない場合の元属性・復元コピーの保持を確認します。CLIでは解放前にstderrへ複数の待機通知が届くこと、取得通知が最後に一度届くこと、無競合時は通知がないことも確認します。MCPでは文字列・整数のprogressTokenとtokenなしの要求を送り、解放前の進捗通知、tokenの一致、進捗値の単調増加、最終応答後とtokenなしでの通知抑止を確認します。ロック待機中の元対象のSHA-256と復元コピー未作成、解放後の復元コピーのSHA-256、親フォルダーの保持、待機時間・通知を外部JSONへ記録します。実ユーザーのコンパイラーや共有ビルドサーバーは終了しません。

必要な結果JSONを保持し、検証用プロセスとハンドルの終了後に今回のfixtureをPrunletで清掃してください。読み取り専用検証で付けた属性だけは元に戻してから清掃します。

## latestインストーラー

更新バックアップも`OutputDirectory\update-backups`へ隔離し、`-UpdateBackupRoot`で実体のパスを渡します。実ユーザーの更新バックアップを検証用の保存先に使いません。

```powershell
$latestRun = Join-Path ([IO.Path]::GetTempPath()) ('Codex\Prunlet\latest-verification-' + [guid]::NewGuid().ToString('N'))
$latestReport = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Codex\TaskArtifacts\Prunlet\latest-verification-' + [guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path -Parent $latestReport) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-LatestInstall.ps1 -OutputDirectory $latestRun -ReportPath $latestReport -CheckPublicHead
```

GitHub応答を検証用アーカイブへ差し替え、実際のインストーラー・.NETビルド・配置・Codex登録を通すE2Eです。最新HEADの再解決、同一SHAからの導入、クローンに依存しない登録、既存設定と復元データの保持、ZIPの不正経路・重複・リンク、取得とビルドの失敗、製品更新の失敗時の復元を検証します。Codex設定がロックされて登録が途中で失敗した場合の復旧と、旧`allowedRoots`内外にある作業場所での導入も確認します。実ユーザーの配置先・Codex設定は使いません。

定期整理はTask Scheduler境界を隔離して、毎日03:00と現在のユーザーのログオンの両トリガー、有効状態、`StartWhenAvailable`、電池使用時の実行許可、既存タスク設定の保持をXMLで検証します。PCの電源断・スリープ・ログオフを伴う取り逃し回復の実動作は、この検証の対象外です。

`-CheckPublicHead`では実際のGitHubも参照します。リモートに必要な実装がまだない場合は、配置先を変更せず停止することを確認します。検証用アーカイブでの成功を、実GitHubからの導入成功として扱いません。公開後は実GitHubから導入し、`source-info.json`のリポジトリ・ブランチ・コミット、配置済みexeと登録先を照合してください。

共通指示の登録では、明示オプションなしの不変更、既存AGENTSの保持、配置済みexe・設定のbinding、既知の旧MCP優先ブロックとguideハッシュに一致する移行、冪等な登録と解除、利用者編集の保護、登録途中の失敗時の復旧を隔離したCodex homeで確認します。旧配置済みPowerShell backendの退役では、製品バックアップとCoreによるバックアップ付き削除を照合します。実ユーザーの共通AGENTS本文はこのE2Eで変更しません。実登録後は、専用guide・管理マーカー・bindingの保存内容、新しいチャットでの読込、最初からCMD CLIが選ばれた実動作を分けて確認してください。

フォルダー対応では、空フォルダーと空の子階層の削除・復元、非空の明示recursive、CLIとMCP、dry-run、schema 2と旧schema 1、包含・重複・復元データ祖先の拒否、子のlockで削除しないこと、link先を辿らないこと、ADS/hardlink/case-sensitiveの復元、復元時の衝突を検証します。列挙後の追加ファイル競合は、実際にそのタイミングを再現できた場合だけ合格にします。

特殊対象ではschema 3のstream名・保存位置・hash・必須field・reparseタグと生offsetの改竄、case-sensitive保存先の拒否、Foo/fooの個別指定と往復を確認します。ファイル・フォルダーのADSは、通常名と末尾空白・ピリオド付きの名前を別々に保存・復元し、既存対象の非上書きとpurge後の内容維持、MCP経由の末尾空白名の往復も確認します。削除保留とADS共有のnative検証は、元対象を削除せず保留を取り消す方法でsingle-link、hard-link別名、directory、既知ADSを確認します。CLIの並行追加の瞬間にプロセスを強制終了する競合は未検証です。復元は保存時点のsnapshotであり、第三者の同時変更とプロセス終了を含む全変更の原子的保全を保証しません。

## 大量操作と途中バックアップ

大量操作に関係する変更では、通常E2Eに加えて次の独立したCLI E2Eを実行します。出力先は新しい外部絶対パス、レポートの親は事前作成済みにします。`-BaselineExecutablePath`は旧版の拒否を同じfixtureで比較する場合だけ指定します。

```powershell
pwsh -NoProfile -File .\scripts\Verify-LargeOperations.ps1 -ExecutablePath <今回のexe> -OutputDirectory <新しい外部Temp> -ReportPath <外部JSONレポート> [-BaselineExecutablePath <旧版exe>]
```

32,769ファイルをschema 3とschema 2の両方で削除・復元し、実manifestと結果が8 MiBを超えること、全ファイルの内容、既存ファイルの非上書き、purgeの検査・適用・再適用を確認します。CLI子プロセスの時間・メモリ・ハンドル数も記録します。通常E2Eでは旧schema 1/2/3の途中コピー、schema 2 purge intentの再開・改竄、正常コピーの破損、未知項目・link・ADS・hardlink、不正な巨大tokenや切断JSONを確認します。

## 操作履歴の圧縮

履歴圧縮を変更した場合は、通常E2Eに加えて次を実行します。出力先とレポートは新しい外部絶対パスを指定し、親ディレクトリを事前に用意します。Windowsローカルの作業規約に従い、TEMP/TMPもD上の今回の作業領域へ指定します。

```powershell
pwsh -NoProfile -File .\scripts\Verify-HistoryCompaction.ps1 -ExecutablePath <今回のexe> -OutputDirectory <新しい外部D作業領域> -ReportPath <外部DのJSONレポート>
pwsh -NoProfile -File .\scripts\Verify-AutomaticHistory.ps1 -ExecutablePath <今回のexe> -OutputDirectory <別の新しい外部D作業領域> -ReportPath <別の外部DのJSONレポート>
pwsh -NoProfile -File .\scripts\Verify-AutomaticHistorySchedule.ps1 -ExecutablePath <今回のexe> -OutputDirectory <さらに別の新しい外部D作業領域> -ReportPath <さらに別の外部DのJSONレポート>
```

正常にpurge済みの操作で、dry-runの全バイト・属性不変更、適用前後のJSONのSHA-256と長さ一致、物理容量の減少、繰り返し適用、操作一覧・復元拒否・再purgeの互換性を確認します。復元コピーと不明項目を持つ操作、不正なmanifest・intent・結果、ADS・hardlink・reparse・ReadOnly、共通ロックと操作ロックの競合は内容を保全することを確認します。実ユーザーの履歴には検証fixtureを混ぜません。削減量は実測した物理容量で判断し、論理容量やドライブ空き容量の差だけでは判定しません。

自動経路ではschema 1/2/3のmaintainによる検査・適用・再実行、CLI/MCP削除時に今回purgeした操作だけが圧縮されること、手動purgeの履歴が保持され次のmaintainで整理されることを確認します。既圧縮でもリンク・ADS・読み取り専用・未知memberは検査し、`skipped_compressed`は本文の妥当性を認定しない結果として扱います。保持理由はhistoryCompaction内で確認し、復元コピーの容量と履歴圧縮の物理削減量を混ぜません。

時刻トリガーの検証では、隔離した設定と一回限りのタスクを使い、手動起動せずに`maintain --apply`の発火・終了コード・SHA-256一致・物理容量減少を確認します。検証用タスクは固有名と説明・アクションの所有情報を照合して解除します。実運用のタスクの登録・解除は行いません。

## 復元データの自動整理

保持期限・容量制限を変更した場合は、通常E2Eに加えて次を実行します。出力先は新しい外部絶対パス、レポートの親は事前作成済みにします。

```powershell
pwsh -NoProfile -File .\scripts\Verify-Retention.ps1 -ExecutablePath <今回のexe> -OutputDirectory <新しい外部Temp> -ReportPath <外部JSONレポート>
```

既定の7日・10 GiBと旧設定の互換性、期限切れ・容量超過の古い操作からの整理、実削除前の自動整理、dry-runの不変更を確認します。上限を超える単一ファイル・複数ファイルの合計・再帰ツリー・ADSを持つ対象も、検証済みコピーを保持して削除・復元できること、次の削除やmaintainで通常の上限へ整理されることを確認します。容量境界には小さな設定値を使い、schema 2とADSを持つschema 3の実コピーを検証します。破損コピー・未検証の途中コピー・稼働中ロック・未知項目・reparse pointの保全と警告、整理後の復元拒否、途中のpurge intentからの再開、繰り返し実行時の記録増殖も確認します。2プロセスの実削除を競合させ、通常サイズは共通の設定上限、上限超過の操作は1操作の見積りサイズ以内に復元コピーの合計が収まることも確認します。検証fixtureではmanifestの日時を変更して期限を再現し、実ユーザーの復元データは使用しません。
