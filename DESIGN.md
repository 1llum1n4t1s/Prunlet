# Prunletの設計

現在の通常経路は、記録を残さないファイル削除と、snapshot・トランザクションを使うレジストリ削除・復元である。ファイルはWindowsゴミ箱へ移し、明示的なサイズ超過時だけ実体を再照合して元名の永久削除を試みる。利用手順は[README](README.md)、連携は[docs/integration.md](docs/integration.md)、検証は[docs/verification.md](docs/verification.md)を参照する。

## 構成と責務

- `Core/DeletionService`がファイル削除・レジストリ削除と復元・保守・明示移行を担当する。CLI・MCP・hookに別の削除方式を実装しない。
- `Program`はCLIの入力検証とJSON出力、`Protocol/McpServer`はstdio JSON-RPCを担当する。MCPは`delete_files`・`delete_registry`・`restore_registry`・`reconcile_registry`・`list_operations`の5ツールである。`--config <path> mcp`として起動した場合は、起動前・引数検証の例外もstderrへ出してプロトコルstdoutを保つ。他のCLIでは例外をstdoutのJSONで返し、値名などの引数に`mcp`が含まれるだけでは出力先を変えない。
- hookは認識した直接削除を検査・拒否し、配置済みCLIを案内する。ホストの承認・管理ポリシーを維持し、削除の自動代行や自動昇格を行わない。
- Windows Shellがゴミ箱への移動とファイル復元を担当する。Prunletのファイル復元API・通常の履歴圧縮入口は提供しない。

### フックのshell解析境界

`Protocol/HookRouter`は`Bash`・`exec_command`・`functions.exec_command`のコマンド文字列を検査する。`exec_command`系の明示的な`tool_input.shell`がPowerShellまたはCMDなら、その文字列規則を選択する。shell未指定・未知・Posix系の指定、および`Bash`ではCMD・PowerShell・Posixの複数規則で検査する。未知shellをCMDで実行するWindowsホストがあるため、tool名やshell名だけからPosix実行とは推測しない。静的なshell wrapperのコマンド本文も再帰検査し、認識したPowerShell・CMDのwrapperには対応する規則を使う。

CMD規則では`#`をコメントとして扱わず、後続のコマンド区切り以降も検査する。静的な`IF`は`/i`・`not`、`exist`・`defined`・`errorlevel`・`cmdextversion`、`==`と`EQU/NEQ/LSS/LEQ/GTR/GEQ`の条件直後のコマンドを検査する。条件の真偽は評価せず、比較値や`echo`の引数を削除コマンドとは扱わない。wrapper本文の再構成では、引用内の`==`と引用外の比較演算子、空の引用文字列を区別して保つ。

PowerShellのヒアストリングは行頭の終端までを文字列として読み、終端前後のローカルコマンドを検査する。Codexの実ホストは`exec_command`を`Bash`として渡し、実行shellをフック入力に含めない。同じ文字列がshellによって実行コードにもデータにもなるため、shell不明のままPowerShellとは決め打ちしない。単独の静的な`pwsh -NoProfile -EncodedCommand <canonical UTF-16LE Base64>`は復号してPowerShellとして限定検査し、未対応の動的呼出し・展開・別shell等は拒否する。認識した省略形やwrapperは限定形式として扱わず、不正・未終端のヒアストリングも拒否する。SSHの存在や接続先による素通し例外は設けない。未認識の外部wrapper、外部scriptの内容・動的なコマンド名・他言語のAPIまで検査する保証はない。利用時の書き方は[連携手順](docs/integration.md)、解析の実プロセス検証は[検証手順](docs/verification.md#通常e2eの検証範囲)を参照する。

## 削除と復元のデータフロー

ファイル・フォルダーは入力パスを正規化し、対象・祖先・保護領域・リンクを検証する。全対象のpreflightを終えてからWindowsゴミ箱へ移す。Windowsが対象を大きすぎると明示し、生成先や別原因の失敗がなく、保持した元実体と再固定した名前・親・属性が一致した場合だけ、同じ要求内で対象名を永久削除する。フォルダーの進捗通知は失敗と扱わない。その他の失敗・不明状態からは永久削除へ切り替えない。再帰指定のない非空フォルダーは拒否し、リンク先を走査しない。独自退避・別ボリュームへのコピー・自動昇格は行わない。

新規ファイル削除では、操作ID・PIDL・File ID・内容hash・size・ACL snapshotを復元用に永続化しない。manifest・monitor・index・retirement・復元stageも作成しない。処理中の安全確認に使う情報と永続的な操作記録を区別する。共通の`maintenance.lock`は排他制御用の固定ファイルであり、操作記録ではない。

サイズ超過時の固定削除は、共有inspectionで元実体を保持し、DELETE非共有のhandleで親・名前・ID・属性を再照合して、そのhandleへ削除を設定する。フォルダーは固定した親から子を列挙し、各実体を検証してから再帰的に削除する。Shellの全結果を受けてから固定削除を開始し、同じbatch内の同じFile IDをopen前からclose・確認まで排他する。独立した実体はworker上限内で並列に処理し、限られた排他枠が重なる場合は一時待機する。途中失敗・一致不能・削除後の名前消失を確認できない場合は`ambiguous`で止める。

同じ実体の別名を複数扱う場合は、確認した変更時刻と一時handleを保持し、可能な場合は通常ストリームと既存のADSへの書込みを抑止する。guardには実行または読取のアクセス権が必要で、取得できない場合は同じroot内の従来処理を維持し、別rootへの引継ぎは停止する。Shellでゴミ箱へ移った無関係な実体には固定削除用guardを取得しない。guardや時刻の確認は外部プロセスによる属性・ACL・ストリームのあらゆる変更を排除する保証ではなく、確認できない状態からは推測して再送しない。

Shellがゴミ箱への移動を成功と返した場合は、返却項目だけを一時的に開き、保持した元実体のFile IDと照合する。識別できない場合や不一致は`ambiguous`とし、記録やゴミ箱全体の走査は行わない。この照合は事後の検出であり、Shell直前の名前差し替えによって別実体がゴミ箱へ移ること自体は防げない。

`Delete`は`FileDeleteResult`を返し、`dryRun`・`items`・`warnings`を持つ。項目は`path`・`kind`・`status`・任意の`error`だけであり、状態は`recycled`・`permanently_deleted`・`would_recycle`・`already_absent`・`failed`・`ambiguous`である。`permanently_deleted`は対象の元名をゴミ箱へ移さず削除したことを示し、別ハードリンクやバックアップの消去は保証しない。dry-runはWindowsの最終判定を予測できないことを警告する。`failed`・`ambiguous`はCLIの非ゼロ終了とMCPの`isError`へ反映する。結果不明時は同じ削除を再送せず、元対象とWindowsのゴミ箱を確認する。

復元と保持期間の管理はWindowsのゴミ箱で行う。Windowsが完全削除した実体をPrunletが復元できるとは扱わない。ハードリンクの別名は実体を共有し、生存する外部別名からの書込みがゴミ箱内にも反映される。通常属性・ADS・case-sensitiveな名前とACLはWindowsが移す同じオブジェクトの状態であり、Prunletが保存時点の不変コピーやACL再適用を提供するものではない。

対象のclaim取得順・process共通worker上限・重複/親子の排他・全preflight完了後の実行を維持する。ハードリンクの共有を検出した場合は排他的な実行へ切り替える。MCP要求枠とfile worker枠を分け、registry privilege変更をfile workerと並行させない。

## 保存領域と保護

`backupDirectory`は保護されたmetadataの基点である。manifestの`MetadataRoot`は従来の共通基点を維持する。レジストリの通常記録は`<backupDirectory>/.registry-records-v1/<operationId>`へ分離し、通常の一覧・保守・復元はそのnamespaceを対象にする。

旧flat記録・旧schema 4のボリューム専用領域・旧schema 6の制御領域は、移行が終わるまで保護する。通常のファイル削除・一覧・保守が、旧ファイルの操作ディレクトリを探索・監視・再評価する経路は持たない。新しいファイル削除のためにボリューム専用領域を作らない。

手動`init`は設定だけを作り、明示`migrate --apply`が専用namespaceと全体のレジストリ準備を確定する。準備前の通常レジストリ削除・一覧・保守は`migration_required`で軽量拒否する。既知IDのrestore/reconcileによる個別旧記録の移行は、全体の準備完了とは扱わない。ファイル削除はレジストリ準備を要求しない。

## レジストリの削除と復元

レジストリ操作も`Core`へ集約する。CLIは`registry-delete --view <32|64> [--value-name <literal-name> | --value-name=] [--recursive] [--dry-run] -- <single-key-path>`、MCPは`delete_registry`と`restore_registry`を提供する。CLIの`restore`と`registry-restore`、MCPの`restore_registry`はレジストリ専用である。削除要求はview必須、値名省略はキー、空文字は既定値であり、値削除の再帰指定を拒否する。

schema 5の`registry-manifest`・snapshot・intent・receiptで、未知の値型も含め型のuint値と生バイト列、キーごとのOwner・Group・DACL・SACL（Mandatory Labelを含む）を保持する。実削除は非トランザクションの対象または親HKEYを保持し、その同じオブジェクトをRootDirectory・空の相対名で`NtOpenKeyTransactedEx`に渡す。まず削除をトランザクション内へstageし、外部には元データが見える状態で、保持した非トランザクションHKEYからsnapshotを取得する。snapshot・manifest・intentのflushとハッシュ検証を済ませてからcommitし、完了receiptを永続化する。したがって外部に削除が確定する前に保全データが永続化される。

dry-runは`SnapshotForDeletionPreflight`で実削除と同じ原本オブジェクト・アクセス権・再帰範囲を使い、各対象のtransaction接続を確認してsnapshotを読み、保持した名前の一致も確認する。削除のstage・書込み・commitは行わない。transaction非対応のviewを読取りだけで通過させて`would_delete`とすることを防ぐが、その後の外部変更や実削除の成功までは保証しない。

snapshotを先に読んでから削除をstageすると、その間の外部書込みが成功したまま失われるおそれがあるため、この順序へ戻さない。先行stage後も非トランザクションの外部書込みが受理される場合はあるが、競合したcommitは失敗し、外部の新データを含む元対象を保全する。KTM非対応時の非トランザクション削除は行わない。完全なキーACL取得には`SeSecurityPrivilege`が必要であり、現在のトークンに存在する場合のみ一時有効化し、自動昇格しない。権限不足やsnapshot失敗ではcommitせずロールバックする。値には独立ACLがなく、親ACLを変更しない。

schema 5の原文bytesはpendingファイルの最初の書込み時点から、Ownerを現在のユーザーSID、アクセス主体を現在のユーザーSIDとSYSTEMだけとするprotected DACLを指定してatomicに作成する。操作ディレクトリ・metadata・ロックも同じ非公開ACLで作成し、後からACLを締める公開期間を設けない。読取り・復元・整理でもACLを検証し、改変を検出した記録は処理せず保持する。

manifest・snapshot・intent・receiptの公開は`RegistryPublication`が担当する。空のpendingを作成し、親と本文のidentity・公開先名・長さ・hashを結び付けた所有予約をflushしてから本文を書き、flush・検証後に同じhandleで正式名へrenameする。未公開本文を正式receiptへ昇格してcommit結果を推測しない。正式callerが原本とACLを再検証し、予約した完全bytesと既存prefixが一致した場合だけ書込みを再開できる。公開済み本文のidentity・長さ・hashを確認できれば所有予約を清掃できるが、pendingと正式名の共存、所有不明、改変は保全する。

キーの生セキュリティ記述子は`BACKUP_SECURITY_INFORMATION`（0x10000）で取得し、Owner・Group・DACL・SACLとMandatory Labelを含めて保持する。Owner/Group/DACL/SACLだけの取得フラグ（0xF）ではMandatory Label ACEが欠落するため使用しない。復元時は完全な記述子を指定して全キーを作成してから、必要なauto-inherited bitだけを要求するsetterを適用し、同じ完全取得方法で再読して生bytesを完全一致で比較する。親のsetterを子の作成前に適用すると、SACL実体がない子のauto-inherited bitが失われるため、この順序を維持する。比較を緩和せず、保持できない場合はロールバックしてsnapshotを保全する。

復元はトランザクション内で新規作成だけを許し、既存キー・値・空の既定値を上書きもマージもしない。値復元は先に書込みをstageしてから、保持した非トランザクション親HKEYで同名値の不存在を確認する。既存値ならロールバックし、競合する外部書込みがあればcommitを失敗させて外部値を保全する。Owner/SACLの適用権限不足もロールバックしsnapshotを保全する。commitとreceipt永続化の間の中断は`ambiguous`としてpayloadを保持し、推測した復元・自動整理を拒否する。キーのclassも保存するが、最終書込み時刻は復元せず、volatileキーも非volatileキーとして復元する。

対象はローカルHKCU/HKLM/HKUの絶対キーで、`Registry::`およびmodule prefixを許容する。ルート自体、mergedなHKCR/HKCC、remote、relative、レジストリリンク、未知のschema・metadataや検証できない復元記録は拒否する。保持条件と整理の責務は[復元データの自動整理](#復元データの自動整理)にまとめる。

MSIX由来の仮想viewでtransactionが利用できない場合も、非transaction操作へ切り替えない。通常Windows側の操作には、通常デスクトップの期限付きnative sessionを用意し、`registryScope=nativeWindows`と専用接続情報を明示選択したCLI・MCPから同じCoreへ委任する。検証では`Verify-RegistrySession.ps1`のPrepareで固定したscopeと入力に限り、`Start -AssertNativeWindows`からdesktop Explorerの通常起動とWindowsの`runas`で起動できる。管理者起動の同意はOSのUACポリシーに従い、エージェントは同意を代行しない。入力のread handle・hash、nonce、原子的な開始claim、親の生存・期限、通常/管理者の実token、両者のreadyとRun permitを照合し、遅延起動や曖昧な開始を拒否する。手動のdesktop起動は診断互換として残す。job・silo制約を転送する方式ではなく、通常Windows scopeへの明示委任であり、汎用コマンドbroker・サービス・タスク登録・仮想viewからのfallbackは追加しない。要求ごとのeffective tokenを使用し、session固有の権限を呼出元へ貸さない。sessionはlocal・同じログオン・同じexeに限定し、期限後は新規受付を停止するが進行中のCoreを強制終了しない。

native scopeの識別はmanifestとsnapshotのhash内に保存し、machine・SID・viewの一致を復元前に確認する。scope欠落の旧記録をnativeと推定せず、異なるscopeからの復元を拒否する。restoreのIPC分岐は共通ロックの取得前に行い、server側だけでCoreの共通ロックを取得する。deleteのoperationIdはclientで先に決め、応答喪失時は同じ削除を再送せず、read-onlyの`registry-reconcile`で記録を確認する。接続・scope・認証の不一致は元対象と復元データを保持して停止する。起動・設定の手順は[連携手順](docs/integration.md#通常windowsのレジストリを明示して操作する)を参照する。

## 旧ファイル復元データの明示移行

旧ファイルの復元互換を維持せず、Coreの明示`migrate`で所有確認済みの旧退避データ・操作記録をWindowsのゴミ箱へ破棄する。旧schema 1〜4/6のdecode・内容hash・ACL snapshot・コピー・bundle・sidecar・file restoreは実装しない。既存のWindowsゴミ箱項目を走査・再移動しない。

volume側は8 KiB以内のstore markerでSID・metadata root・StoreKey・volume・root identityとprivate ACLを検証した専用StoreKey/restore rootだけを扱う。privateBase・custom設定dir・他StoreKeyを丸ごと処分しない。中央GUID操作は直下の正規file marker名で分類し、本文が破損・未完了でも処分できる。registry manifest・pending・publication・namespace/controlのsignalは先に保護する。typed file rootは正規layout、既存bundle/journalは予約prefixとprivate metadata所有範囲で限定し、本文の任意Pathへ削除範囲を広げない。

所有inventoryのpinを解放してからdispatchし、直前にpath・root identity・marker・非reparseを再確認する。元実体の共有handleをShell処理中も保持し、返却項目が同じ実体と確認できなければ`ambiguous`で止めてgateを残す。通常削除と同じ`NativeRecycleBin.RecycleUnrecorded`を使い、永久削除・copy fallback・任意対象の保護解除フラグを追加しない。結果はPathと`recycled`・`would_recycle`・`already_absent`・`retained`・`failed`・`ambiguous`であり、file操作ID・復元記録を新設しない。

移行全体で固定のprivate空ファイル`.legacy-file-discard-in-progress`を1個だけ使う。これは対象Path・ID・hash・ACL本文を持たない実行gateであり、CreateNew・Flush・検証後にdispatchし、確認済み成功時だけ除去する。存在または不正形はfile discardだけを停止し、registry処理は続ける。installerは解除せず、元フォルダーとWindowsゴミ箱の確認後の`migrate --apply --retry-legacy-discard`だけが、正規の空private gateを解除して再評価する。dry-runとif-neededにackを組み合わせない。

registryの旧記録は専用namespaceへ移し、ID・snapshot・完全ACL・scope・共通MetadataRootを保持する。file処理の未完了はRegistryReadyから分離する。policy version 2は未指定0の旧stateを読める形で保存し、installerの`--apply --if-needed`では中央旧GUID走査を省略する。オンラインvolumeの所有済みstore/restore rootの少数存在・小marker検査は更新時に続け、後から接続された領域を回収する。通常file delete/list/maintainへ旧領域走査を加えない。移行開始後は旧binaryへrollbackせず、新exe・設定・登録を保持する。

## 復元データの自動整理

保持制御はレジストリschema 5専用で、既定7日・合計1 GiBである。事前容量走査・整理前後の再走査・共通ロック・単一超過時だけの予算を維持する。Windowsゴミ箱のファイル実体と移行待ちの旧ファイルは容量・期限・purgeの対象に含めない。

レジストリ削除前・明示`maintain`・非表示の定期保守でレジストリ復元データを整理する。ファイル削除はレジストリの容量保守や旧root走査を起動しない。`operations`とMCPの`list_operations`はレジストリ一覧、`purge`と`maintain`もレジストリ専用である。手動整理はCLIの明示適用だけとし、MCPへpurgeを追加しない。

検証できないACL・snapshot・未確定commitは保全し、自動整理で捨てない。`maintain --audit-records`の完全監査と通常容量走査を区別する。旧ファイルの型別index・終了履歴・外部不在判定を、新しいファイル通常経路の管理機構として復活させない。

レジストリの復元・purge完了後は、snapshotが消費済みで正式完了receiptがある記録から、残存memberのidentity・security bytes・長さ・hashを束縛する`<id>.terminal.json`を作る。完了時点から保持期間を過ぎた記録だけを整理し、先にterminalのhashに結び付けた`<id>.terminal-cleanup.json`を永続化する。途中でmanifestが消えても保存済みinventoryで残存memberを検証して再開し、未知memberや差替えは保全する。これらはレジストリ専用であり、ファイルの終了履歴を作る機構ではない。

移行・terminal・terminal-cleanupの制御記録は`RegistryControlPublication`が扱う。中断したpendingの再公開には、呼出元が同じ記録の証拠から本文を再構成し、既存prefixとの一致を検証する必要がある。pending本文だけを権威にせず、正式名との共存や不一致は保全する。この再構成方式はsnapshot・receiptの公開には一般化しない。

### 容量上限の一度だけの移行

latest導入時に`capacityDefaultMigrationVersion`が欠落または1未満の既存設定だけを対象に、`maxRecoveryBytes`を1 GiB、移行印を1へ一度だけ更新する。移行済み印と移行後の利用者変更を尊重し、未知の設定・ACLを保持する。設定読込やdry-runへ設定書込みを持ち込まない。詳細の動作検証は[導入検証](docs/verification.md#latestインストーラー)を参照する。

## 不変条件と設計判断

拒否された削除を別shell・別API・別exeへ付け替えない。明示的なサイズ超過以外のゴミ箱失敗時に永久削除せず、処理不明時は確認せず再送しない。保護領域・祖先・リンク先を通常削除で破壊しない。レジストリの完全ACL・raw bytes・transaction・非上書き復元を維持する。

## 導入と検証の境界

利用者向け導入はGitHubの既定ブランチ最新HEADを解決し、取得元・ブランチ・commitを`source-info.json`へ記録する。開発クローン・ローカルビルドをlatest導入の代用にしない。設定の検証には`validate-config`を使い、設定読込とservice構築だけで走査・変更しない。共通指示の生成元は`integration/PRUNLET.md`で、配置済み共通指示の更新とソース変更は別の結果として扱う。

### 起動時自動更新

CodexのMCP登録は`integration/start-prunlet-mcp.ps1`をPowerShell 7で起動する。launcherがGitHubへの照会と更新手順の調停を行い、`Core/StartupUpdateCoordinator`が製品・登録・移行の状態遷移を、`StartupUpdatePackage`・`StartupPublishedDownload`がパッケージ検証と取得を、`StartupUpdateBudget`・`StartupUpdateSlot`・`StartupUpdateRotation`が容量と再利用を担当する。`StartupUpdateGate`は通常CLI・MCP・保守の開始前に更新状態を検査する。hook専用の`prunlet-hook.exe`はこのgateを通らず、削除を実行するCLIのパスを受け取って案内する。

MCP起動時に公開済みlatestを確認し、既存版の子孫で更新protocolと保管形式が互換の候補だけを準備する。既存の製品・登録の所有とhashを確認し、旧CLI/MCPと保守exeを同時にwrite排他できなければ変更せず延期する。hookは独立exeとして継続し、旧プロセスを終了させない。固定の更新状態は製品切替・登録・移行の再開と更新cacheの所有確認・再利用に限り、ファイル操作履歴には使わない。途中状態では通常CLI/MCPと保守を止め、候補からレジストリ移行を再開する。移行開始後は旧exeへrollbackせず、registryが利用可能になってからsource-infoとidleを確定する。書込みや置換が不明なときは保全して自動再送せず、確定したregistryの利用とは分離する。

stageは再帰削除せず、完了した世代の正規製品とmetadataをhashと実体で照合して主streamだけを再利用する。正常な次回更新を、stageが存在するだけで止めない。未知の項目は残して容量へ含め、未確定の切替・移行は先に同じ候補で再開する。

配布元の方針は公開済みGitHub Releaseであり、その発行者を信頼する。`.github/workflows/prunlet-release-package.yml`が公開タグからwin-x64・win-arm64をビルドし、`scripts/Package-PrunletUpdate.ps1`でZIPを作成する。公開前に`Verify-ReleasePackage.ps1`がentryの過不足・重複、metadataの取得元・commit・runtime等、および全同梱ファイルの長さ・SHA-256を今回のpublish出力・sourceと照合する。検証済みZIP全体のSHA-256をアップロード直前にも再確認し、同じreleaseへ添付する。既存assetは上書きしない。取得側はタグが既定ブランチ上のcommitを指すこととasset digest・size、パッケージ内のcommit・runtime・製品hashを検証する。digestは転送内容の一致を示し、ソースからビルドされたことを独立に証明しない。Actionsの期限付きartifactを更新の必須条件としない。

更新用cacheはレジストリ復元領域とは別に合計2 GiBを上限とする。公開ZIP・stage・製品slot・固定candidate/previous・保全した異常世代・各ディレクトリのADS・更新管理ファイルを容量に含め、確保前と完了後に検査する。slotはcache専用で、実行・移動・削除しない。正規hash・長さ・単一linkを同じ排他handleで確認し、通常streamだけをin-place更新する。候補へはそのhandleの通常streamだけをCreateNewコピーする。ADSや不明な部分書込みは保持し、予算不足を自動削除で回避しない。

ビルドと検証の実行規約・必須コマンドは[AGENTS.md](AGENTS.md#ビルドと検証)、各経路の検証範囲とfixtureの保持・清掃は[検証手順](docs/verification.md)を正本とする。

## 依存更新の境界

`.github/dependabot.yml`はGitHub ActionsとNuGetの更新を毎週月曜09:00（日本時間）に確認し、minor・patchをまとめ、majorは個別PRにする。`.github/workflows/dependency-validation.yml`はDependabotのPRまたは手動起動を対象に、Windows・.NET 10でrestore・buildとCLI・MCP・hookの通常E2Eを行う。出力はrunnerの一時領域へ分離し、checkoutの認証情報を保持せず、権限はcontentsの読取りに限定する。

`.github/workflows/dependabot-auto-merge.yml`は、書込み権限を持つ処理を信頼済み既定ブランチ側で実行し、PRのコードは実行しない。対象は所有者`1llum1n4t1s`のリポジトリで、同一リポジトリから既定ブランチへ向けたDependabotの非draft PRに限る。依存更新として判定できる差分と署名済みコミットを検査し、workflowの変更は`uses`の参照更新だけを許可する。PRのhead SHAに対応する依存検証の最新実行が成功し、他のcheck・commit statusにも失敗や未完了がなく、競合がない場合だけマージを試みる。直前にhead・既定ブランチのSHAとマージ可能状態を再確認し、変更や未検証状態があれば保留する。GitHub側のマージ要件も維持する。依存検証の成功と書込み処理を分離することで、未検証のPRコードをマージ権限で実行する経路を避ける。
