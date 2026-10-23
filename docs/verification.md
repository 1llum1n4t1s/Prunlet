# E2E検証

CLI・MCP・Codexフックを実際の別プロセスで起動して検証します。ユニットテストは使用しません。新規削除はschema 4の同一ボリュームrename、schema 1/2/3は既存コピーの復元・整理の互換経路として確認します。スクリプトの存在と実行成功は別であり、終了コード、`passed` / `failed`、外部JSONレポートを読んで判定してください。

## 通常E2Eの検証範囲

通常の入口`scripts/Verify-Prunlet.ps1`は、新方式を直接検証する`scripts/Verify-VolumeMoves.ps1`へ振り分けます。旧コピーを作るための変更前1.0.9 exeを`-LegacyExecutablePath`で指定し、新旧で同じexeを代用しません。省略時は旧形式互換ケースをskipし、未検証と明記します。

```powershell
$runRoot = Join-Path 'D:\Codex\Prunlet' ('verification-' + [guid]::NewGuid().ToString('N'))
$report = Join-Path 'D:\Codex\TaskArtifacts\Prunlet' ('verification-' + [guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path -Parent $report) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-VolumeMoves.ps1 -ExecutablePath <今回のexe絶対パス> -LegacyExecutablePath <変更前1.0.9exe絶対パス> -OutputDirectory $runRoot -ReportPath $report
```

`OutputDirectory`と`ReportPath`は新しい外部絶対パスにします。子プロセスのTEMP/TMPと設定、中央metadata、volume recovery baseも外部作業領域へ隔離します。Dドライブのfixtureには`volumeRecoveryDirectories`でD上の専用baseを指定し、本番の既定`.Prunlet-Recovery-<SID>`を使用しません。復元領域と中央metadataは相互に包含させません。レポートの親は事前に作成してください。

新方式では次の契約を確認します。各ケースの実行・skip・失敗はその回のレポートを正本とし、ここに列挙しただけで合格にしません。

- 通常ファイルと再帰フォルダーを同じFile IDのまま退避・復元し、空階層・内容・ACL・ADS・通常属性・case-sensitive属性を保持する。フォルダーの全子をコピーした形式を新規作成しない。
- dry-runで元対象、属性、中央記録、専用領域を変更しない。非再帰の非空フォルダー、重複・包含、専用領域とその祖先、不正パスを拒否する。
- ハードリンクの外部別名とリンク先を削除しない。別名からの書込みが保管実体へ反映される共有関係を確認する。リンクはリンク自体を移動する。
- 復元先の既存ファイル・フォルダーを上書き・マージしない。復元成功後はpayloadを消費し、整合する再実行は`already_restored`とする。元親・payload・領域のID、marker、ACL、volume、manifest・receiptの不一致を保全する。
- 容量の事前走査、整理前後の再走査、期限・容量順序、複数入力の合計、単一超過時の例外予算と次回の通常予算、計数不能・整理不能時の元対象の保全を確認する。
- 移動完了receipt不在、復元intent後などの中断形状から状態を照合し、矛盾・曖昧な欠損を成功扱いしない。
- 旧exeで作成したschema 1/2/3それぞれを新版でrestore・purge・maintainする。コピーのhash・サイズ検証、旧復元後のコピー保持、新方式の消費型復元を区別する。
- MCPの3ツール、CLIのJSON・終了コード、フックの直接削除拒否とCLI案内を実プロセスで確認する。purgeをMCPへ追加しない。

中断fixtureは永続記録と移動済み配置を再現するE2Eです。実プロセスをrenameの瞬間に強制終了する試験、`Flush(true)`障害注入、電源断による永続性は別途実施しない限り未検証です。ハードリンク外部別名など共通ロック外からの変更を不変snapshotとして保証しません。

`-CaseFilter`はケース名のwildcardで対象を絞り、対象外を`excludedCount`へ計上します。一致0件は失敗です。`Verify-Prunlet.ps1 -LegacyCopyVerification`は旧exeがコピーを生成した時代の再現専用で、新版の通常検証には使用しません。

別ボリュームの実機検証は`-SecondaryVolumeDirectory <別ドライブ上の新しい専用フォルダー>`を明示します。混在入力の退避先・volume ID・File ID、衝突時の非上書き、復元後の消費性を確認します。指定しない場合はこのケースをskipします。ローカルの出力先はDを維持し、GitHub Actionsでは共通検証ガードの範囲でrunnerの出力ドライブを使います。

検証完了後はJSONレポートと再現に必要な最小データを保持し、プロセスの終了・リンク・他作業との混在を確認して今回の作業領域だけを清掃します。配置済みexe、既存共有キャッシュ、利用者の設定・復元データは対象にしません。

このE2EはCodex自身のフック読込・承認や共通指示の読込みを検証しません。登録変更後は、新しいチャットで配置済みguide・管理マーカー・exe/config binding、最初からCMD CLIが選ばれること、直接削除が拒否されることを実ホストで確認し、スクリプト結果と分けて報告してください。MSIX転送も実パッケージの新規fixtureで実体と往復結果を確認し、既存の拒否対象を別経路で再試行しません。

## 一時的なロックとロード中DLL

共通ロック待機は60秒超の保持、解放後の続行、CLIのstderr即時通知とstdout JSON、MCPのtoken付き進捗とtokenなし・最終応答後の通知抑止を確認します。

```powershell
pwsh -NoProfile -File .\scripts\Verify-TransientLocks.ps1 -ExecutablePath <今回のexe> -OutputDirectory <新しい外部作業領域> -ReportPath <外部JSONレポート>
```

ロード中DLLはrenameの成否を調べ、成功時は同一ID・内容・属性と消費型復元、拒否時は元対象と属性の保全を確認します。旧コピーの削除保留待機の期待値を新規renameへ当てはめません。Archiveを含まない読み取り専用ファイルも往復後の完全な属性一致を確認します。

## latestインストーラー

更新バックアップも`OutputDirectory\update-backups`へ隔離し、`-UpdateBackupRoot`で実体のパスを渡します。実ユーザーの更新バックアップを検証用の保存先に使いません。

```powershell
$latestRun = Join-Path 'D:\Codex\Prunlet' ('latest-verification-' + [guid]::NewGuid().ToString('N'))
$latestReport = Join-Path 'D:\Codex\TaskArtifacts\Prunlet' ('latest-verification-' + [guid]::NewGuid().ToString('N') + '.json')
New-Item -ItemType Directory -Path (Split-Path -Parent $latestReport) -Force | Out-Null
pwsh -NoProfile -File .\scripts\Verify-LatestInstall.ps1 -OutputDirectory $latestRun -ReportPath $latestReport -CheckPublicHead
```

GitHub応答を検証用アーカイブへ差し替え、実際のインストーラー・.NETビルド・配置・Codex登録を通すE2Eです。最新HEADの再解決、同一SHAからの導入、クローンに依存しない登録、既存設定と復元データの保持、ZIPの不正経路・重複・リンク、取得とビルドの失敗、製品更新の失敗時の復元を検証します。Codex設定がロックされて登録が途中で失敗した場合の復旧と、旧`allowedRoots`内外にある作業場所での導入も確認します。実ユーザーの配置先・Codex設定は使いません。

定期整理はTask Scheduler境界を隔離して、毎日03:00と現在のユーザーのログオンの両トリガー、有効状態、`StartWhenAvailable`、電池使用時の実行許可、既存タスク設定の保持をXMLで検証します。PCの電源断・スリープ・ログオフを伴う取り逃し回復の実動作は、この検証の対象外です。

`-CheckPublicHead`では実際のGitHubも参照します。リモートに必要な実装がまだない場合は、配置先を変更せず停止することを確認します。検証用アーカイブでの成功を、実GitHubからの導入成功として扱いません。公開後は実GitHubから導入し、`source-info.json`のリポジトリ・ブランチ・コミット、配置済みexeと登録先を照合してください。

共通指示の登録では、明示オプションなしの不変更、既存AGENTSの保持、配置済みexe・設定のbinding、既知の旧MCP優先ブロックとguideハッシュに一致する移行、冪等な登録と解除、利用者編集の保護、登録途中の失敗時の復旧を隔離したCodex homeで確認します。旧配置済みPowerShell backendの退役では、製品バックアップとCoreによるバックアップ付き削除を照合します。実ユーザーの共通AGENTS本文はこのE2Eで変更しません。実登録後は、専用guide・管理マーカー・bindingの保存内容、新しいチャットでの読込、最初からCMD CLIが選ばれた実動作を分けて確認してください。

## 大量操作と途中バックアップ

新しい移動形式の大量ツリーは通常E2Eに`-Large`を追加して確認します。出力先・レポートは通常実行と別の未使用絶対パスを指定してください。

```powershell
pwsh -NoProfile -File .\scripts\Verify-LargeOperations.ps1 -ExecutablePath <今回のexe> -LegacyExecutablePath <変更前1.0.9exe> -OutputDirectory <新しい外部作業領域> -ReportPath <外部JSONレポート>
```

rootごとのschema 4記録、事前容量走査、同一File IDの往復、消費型復元を確認します。旧形式の32,768項目・8 MiB超のschema 2/3記録と途中コピー整理は互換専用の対象です。`Verify-LargeOperations.ps1`のコピー前提ケースは、旧exeで生成した記録を新版で復元・整理する検証へ分離し、新版に旧コピーを新規作成させません。

## 削除性能の比較

新方式の速度を報告する場合は、内容・ACL・ADS・属性・File IDの往復、衝突時の非上書き、容量制御を同時に検証し、変更前exeと同条件で複数回比較します。

```powershell
pwsh -NoProfile -File .\scripts\Verify-DeletionPerformance.ps1 -ExecutablePath <今回のexe> -BaselineExecutablePath <変更前のexe> -OutputDirectory <新しい外部作業領域> -ReportPath <外部JSONレポート>
```

移動後のpayloadと旧コピーで構造・復元の消費性が異なるため、旧コピー形式のassertを流用していないことを確認してください。JSONレポートの各試行と中央値を読み、旧コピー方式で得た性能比を新方式の計測結果として引用しません。性能スクリプトの移行や実測が未了なら、その制限を明示します。

### 蓄積済み復元データでの比較

`Verify-DeletionPerformance.ps1 -ExistingRecoveryFileCount 1024 -CaseFilter buffer-boundaries`で、復元データが蓄積した状態の比較も行えます。変更前exeを`-BaselineExecutablePath`へ渡し、旧版ではschema 2を2操作、新版ではschema 2と4を1操作ずつ実生成します。新旧で保持するファイル数・論理容量を揃え、計測前後と復元後にseedの内容・記録が保たれていることを確認します。事前生成によってruntimeとファイルシステムのcacheが温まるため、空の復元領域での結果と区別します。走査・ロック・内容検証を省いた数値を削除全体の性能として扱いません。

## 操作履歴の圧縮

schema 4は当面圧縮対象外で、`compact-history`と自動経路から理由付き`retained`となることを確認します。旧schema 1/2/3の正常purge済みJSONは従来どおり圧縮対象です。次の専用スクリプトは`-LegacyExecutablePath`を必須とし、旧記録の生成だけを旧exe、圧縮・整理・復元を今回のexeで実行します。

- `Verify-HistoryCompaction.ps1`: dry-runの不変更、JSON内容・SHA-256一致、物理容量減少、冪等性、操作ID互換、ロック・リンク・不正metadataの保持。
- `Verify-AutomaticHistory.ps1`: maintainと実削除前の旧履歴圧縮、既圧縮の扱い、保護対象の保持、metadataとpayload容量の分離。
- `Verify-AutomaticHistorySchedule.ps1`: 隔離した一回限りの時刻トリガーによる発火と終了コード、旧履歴の内容一致と物理容量減少。

```powershell
pwsh -NoProfile -File .\scripts\Verify-HistoryCompaction.ps1 -ExecutablePath <今回のexe> -LegacyExecutablePath <変更前1.0.9exe> -OutputDirectory <新しい外部作業領域> -ReportPath <外部JSONレポート>
pwsh -NoProfile -File .\scripts\Verify-AutomaticHistory.ps1 -ExecutablePath <今回のexe> -LegacyExecutablePath <変更前1.0.9exe> -OutputDirectory <別の新しい外部作業領域> -ReportPath <別の外部JSONレポート>
pwsh -NoProfile -File .\scripts\Verify-AutomaticHistorySchedule.ps1 -ExecutablePath <今回のexe> -LegacyExecutablePath <変更前1.0.9exe> -OutputDirectory <さらに別の新しい外部作業領域> -ReportPath <さらに別の外部JSONレポート>
```

実運用タスクの登録・解除や利用者の復元データは検証に使用しません。検証用タスクも固有名・説明・アクションの所有情報を照合して解除します。

## 復元データの自動整理

通常E2Eで新旧合計の容量制御を確認し、保持制御を変更した場合は追加ケースも実行します。

```powershell
pwsh -NoProfile -File .\scripts\Verify-Retention.ps1 -ExecutablePath <今回のexe> -OutputDirectory <新しい外部作業領域> -ReportPath <外部JSONレポート>
```

既定7日・10 GiB、旧設定、期限切れ・容量確保順、単一ファイル・複数入力合計・再帰ツリー・ADSの容量、dry-runの不変更を確認します。通常予算と単一超過時の`max(maxRecoveryBytes, incomingBytes)`、次回削除・maintainの通常上限、既存データが安全に0まで整理できない場合の新規移動拒否を区別します。

schema 4と旧schema 1/2/3を混在させ、破損・未知項目・使用中・File IDやreceipt不一致を保全し、容量不明を成功扱いしないこと、整理前後の再走査と共通ロックによる並行削除の容量制御を確認します。`Verify-Retention.ps1`は新方式の保持関連ケースを選択します。`-LegacyCopyVerification`は旧exeの再現専用であり、新版の検証に使いません。定期登録・所有者検証・登録失敗時の復旧はlatestインストーラー検証で確認します。
