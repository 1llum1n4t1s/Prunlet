# Prunletの設計

PrunletはWindowsのファイル・フォルダーをWindowsのゴミ箱へ移し、操作IDで非上書き復元するツールである。実体の保管・清掃はWindowsが管理し、Prunletは識別情報と操作記録を保持する。レジストリのキー・値はsnapshotとKTMトランザクションで保全する。CLIとstdio MCPは同じCoreを使い、フックは直接削除を検査・拒否してCLIを案内する。利用手順は[README](README.md)、開発規約は[AGENTS.md](AGENTS.md)を参照する。

## 構成と責務

| 実装 | 責務と境界 |
| --- | --- |
| `Program.cs` / `Protocol/McpServer.cs` | CLI・JSON出力、stdio JSON-RPCと6つのMCPツール |
| `Core/DeletionService.Recycle*.cs` / `Core/RecycleOperation.cs` / `Core/NativeRecycleBin.cs` | schema 6のゴミ箱操作、Shell識別情報とFile ID照合、非上書き復元 |
| `Core/DeletionService.Moves.cs` / `Core/NativeFiles.Moves.cs` | 既存schema 4の同一ボリューム・非上書き復元 |
| `Core/MoveOperation.cs` / `Core/DeletionService.MoveRecords.cs` | schema 4の中央manifest、追記するreceiptの永続化と照合、中断状態の検証 |
| `Core/VolumeRecoveryStore.cs` | ボリューム別専用領域、所有者ACL・marker・ボリュームとFile IDの照合 |
| `Core/DeletionService.Registry*.cs` / `Core/RegistryOperation.cs` / `Core/NativeRegistry.cs` / `Core/NativeFiles.RegistrySecurity.cs` | schema 5のsnapshot・receipt、KTMによる削除と復元、完全ACLと非公開保存の検証、snapshotの消費・整理 |
| `Core/RegistrySession*.cs` | 明示native sessionの接続・認証・scope識別と要求委任 |
| `Core/DeletionService.MoveMaintenance.cs` | schema 4と旧コピーの容量集計・保持制御・明示purgeの統合 |
| `Core/DeletionService.Metadata.cs` / `Core/DeletionService.Retention.cs` / `Core/DeletionService.Purge.cs` | schema 1/2/3の読込み・コピー検証・復元・整理の互換経路 |
| `Core/DeletionService.HistoryCompaction.cs` / `Core/HistoryCompactionResult.cs` | 旧コピー形式の整理済み履歴のNTFS圧縮 |
| `Core/PrunletConfig.cs` / `Core/PathPolicy.cs` / `Core/NativeFiles.cs` | 設定と実体パス検証、祖先の固定、旧コピー形式を含むWin32処理 |
| `Protocol/HookRouter.cs` / `Protocol/BoundedInputReader.cs` | 入力検査と直接削除の拒否・CLI案内。削除・自動置換をしない |
| `integration/` / `scripts/Install-Prunlet.ps1` | 所有範囲に限定した登録・解除、GitHub最新HEADからの導入 |
| `scripts/Publish-Prunlet.ps1` / `scripts/Verify-*.ps1` | 外部絶対パスへのビルドと別プロセスE2E |

## 削除と復元のデータフロー

1. 1〜256件のローカル絶対パスを検証する。重複・祖先重複、中央metadataと旧専用領域、その祖先を拒否する。リンク先を辿らず、非空フォルダーには明示`recursive`を必要とする。
2. 共通`maintenance.lock`を取得し、対象・元親のFile IDと種類を検査する。dry-runは読取りのみで、ゴミ箱・操作記録・ロックを変更しない。新規削除は専用payload領域を作らず、Prunletの容量予算を消費しない。
3. `backupDirectory`のGUID操作フォルダーに`operation.lock`とschema 6の`recycle-manifest.json`を置く。machine・ユーザーSID・対象と元親の128-bit File ID・種類に加え、リンク先を辿らず全項目の相対名・ID・Owner/Group/DACLのnative bytesを記録する。全項目のREAD_CONTROL・WRITE_DACを確認し、`recycle_intent`を永続化してからShellを呼ぶ。直前にも構成・ID・ACLを照合する。上限は1対象65,536項目・descriptorごと1 MiB・記録128 MiBで、超過は移動前に拒否する。
4. 専用STAで対象親の`ITransferSource::RecycleItem`だけを呼ぶ。永久削除の`RemoveItem`や高位の削除fallbackを呼ぶ経路は持たない。UI・自動昇格を使わず、返却された項目を現在のゴミ箱namespaceの実体・File IDと照合してcanonical PIDLを完了receiptへ永続化する。正常情報値`COPYENGINE_S_DONT_PROCESS_CHILDREN`は非NULL実体とID一致を条件に扱う。callback失敗、項目不一致、完了記録欠損は成功と推定しない。
5. `operationId`と項目ごとの成否を返す。複数入力全体は一括トランザクションではなく、途中失敗でも完了項目と記録を保持する。

削除完了receiptにはゴミ箱到着時の全項目のIDとOwner/Group/DACLも記録する。復元前はこのreceiptと現在のゴミ箱実体を照合し、外部ハードリンク等からACLが変更されていたら書き戻さず停止する。

復元はmanifest・receipt、現在のゴミ箱namespaceへの所属、元親と実体のIDを照合する。元パスが空いていることを確認し、同一ボリュームの復元用stageのID・場所をintentへ先行永続化する。ゴミ箱の`ITransferSource::MoveItem`へ`TSF_FAIL_EXIST`を指定してstageへ移し、全項目のWRITE_DACハンドルと同一ID・Owner/Groupを確認した後、元DACLを復元する。native bytes・ID・属性の完全一致を検証してreadyを永続化し、最後にハンドル指定の非上書きrenameで元パスへ公開する。公開後の再照合まで通ってから完了receiptを書く。既存ファイル・フォルダーへ上書きもマージもせず`conflict`とし、ゴミ箱またはstageの実体を保持する。成功時は`restored`、同一オブジェクトの復元を確認できる再実行は`already_restored`となる。元親がなくなった場合やIDが変わった場合は停止する。

stageにreadyがある場合は元snapshotとの完全一致を条件に再開できる。既存stageにreadyがない場合は途中停止と後発のACL変更を区別できないため、ACL・属性を補正せず保全して停止する。公開済み原本の完了記録が欠けてもACL・属性を再適用せず、完全一致した場合だけ完了できる。snapshotのない旧schema 6はWindowsのACL動作に従う互換復元を残し、元ACLを保証できない旨を結果のwarningsへ返す。

中断・欠損・ID不一致は記録を保全して停止し、削除を自動再送しない。ゴミ箱項目を元パスや名前だけで補完しない。Windowsや利用者が完全削除した項目は復元できず、`missing`を返す。操作一覧は操作IDの列挙であり、復元可能性を保証しない。

Shell APIは旧ハンドルrenameと同じ原子的な対象名固定を文書化していない。呼出前後のFile ID照合で取り違えを検出し、不一致は`ambiguous`として保持する。schema 1〜4は既存記録の復元・整理専用とし、新規作成へ戻さない。

## レジストリの削除と復元

レジストリ操作も`Core`へ集約する。CLIは`registry-delete --view <32|64> [--value-name <literal-name> | --value-name=] [--recursive] [--dry-run] -- <single-key-path>`、MCPは`delete_registry`と`restore_registry`を提供する。共通CLIの`restore`はファイルとレジストリを振り分け、MCPの`restore_files`はファイル操作に限定する。削除要求はview必須、値名省略はキー、空文字は既定値であり、値削除の再帰指定を拒否する。

schema 5の`registry-manifest`・snapshot・intent・receiptで、未知の値型も含め型のuint値と生バイト列、キーごとのOwner・Group・DACL・SACL（Mandatory Labelを含む）を保持する。実削除は非トランザクションの対象または親HKEYを保持し、その同じオブジェクトをRootDirectory・空の相対名で`NtOpenKeyTransactedEx`に渡す。まず削除をトランザクション内へstageし、外部には元データが見える状態で、保持した非トランザクションHKEYからsnapshotを取得する。snapshot・manifest・intentのflushとハッシュ検証を済ませてからcommitし、完了receiptを永続化する。したがって外部に削除が確定する前に保全データが永続化される。dry-runは削除をstageしない読取り検査である。

snapshotを先に読んでから削除をstageすると、その間の外部書込みが成功したまま失われるおそれがあるため、この順序へ戻さない。先行stage後も非トランザクションの外部書込みが受理される場合はあるが、競合したcommitは失敗し、外部の新データを含む元対象を保全する。KTM非対応時の非トランザクション削除は行わない。完全なキーACL取得には`SeSecurityPrivilege`が必要であり、現在のトークンに存在する場合のみ一時有効化し、自動昇格しない。権限不足やsnapshot失敗ではcommitせずロールバックする。値には独立ACLがなく、親ACLを変更しない。

schema 5の原文bytesはpendingファイルの最初の書込み時点から、Ownerを現在のユーザーSID、アクセス主体を現在のユーザーSIDとSYSTEMだけとするprotected DACLを指定してatomicに作成する。操作ディレクトリ・metadata・ロックも同じ非公開ACLで作成し、後からACLを締める公開期間を設けない。読取り・復元・整理でもACLを検証し、改変を検出した記録は処理せず保持する。

キーの生セキュリティ記述子は`BACKUP_SECURITY_INFORMATION`（0x10000）で取得し、Owner・Group・DACL・SACLとMandatory Labelを含めて保持する。Owner/Group/DACL/SACLだけの取得フラグ（0xF）ではMandatory Label ACEが欠落するため使用しない。復元時は完全な記述子を指定して全キーを作成してから、必要なauto-inherited bitだけを要求するsetterを適用し、同じ完全取得方法で再読して生bytesを完全一致で比較する。親のsetterを子の作成前に適用すると、SACL実体がない子のauto-inherited bitが失われるため、この順序を維持する。比較を緩和せず、保持できない場合はロールバックしてsnapshotを保全する。

復元はトランザクション内で新規作成だけを許し、既存キー・値・空の既定値を上書きもマージもしない。値復元は先に書込みをstageしてから、保持した非トランザクション親HKEYで同名値の不存在を確認する。既存値ならロールバックし、競合する外部書込みがあればcommitを失敗させて外部値を保全する。Owner/SACLの適用権限不足もロールバックしsnapshotを保全する。commitとreceipt永続化の間の中断は`ambiguous`としてpayloadを保持し、推測した復元・自動整理を拒否する。キーのclassも保存するが、最終書込み時刻は復元せず、volatileキーも非volatileキーとして復元する。

対象はローカルHKCU/HKLM/HKUの絶対キーで、`Registry::`およびmodule prefixを許容する。ルート自体、mergedなHKCR/HKCC、remote、relative、レジストリリンク、未知のschema・metadataや検証できない復元記録は拒否する。保持期間7日・容量1 GiBの既定値はschema 4および旧schema 1/2/3と合算し、共通ロック・事前走査・整理前後の再走査・単一超過時だけの例外予算を共有する。明示整理は既存CLIの`purge`・`maintain`を使い、MCPにpurgeは追加しない。

MSIX由来の仮想viewでtransactionが利用できない場合も、非transaction操作へ切り替えない。通常Windows側の操作には、利用者が通常デスクトップで明示起動する期限付きnative sessionを用意し、`registryScope=nativeWindows`と専用接続情報を選んだCLI・MCPから同じCoreへ委任する。job・silo制約をsessionへ転送する方式ではなく、利用者が通常Windows scopeへの委任を明示する方式である。自動起動・昇格・タスク登録・仮想viewからのfallbackは行わない。要求ごとのeffective tokenを使用し、session固有の権限を呼出元へ貸さない。sessionはlocal・同じログオン・同じexeに限定し、期限後は新規受付を停止するが進行中のCoreを強制終了しない。

native scopeの識別はmanifestとsnapshotのhash内に保存し、machine・SID・viewの一致を復元前に確認する。scope欠落の旧記録をnativeと推定せず、異なるscopeからの復元を拒否する。restoreのIPC分岐は共通ロックの取得前に行い、server側だけでCoreの共通ロックを取得する。deleteのoperationIdはclientで先に決め、応答喪失時は同じ削除を再送せず、read-onlyの`registry-reconcile`で記録を確認する。接続・scope・認証の不一致は元対象と復元データを保持して停止する。起動・設定の手順は[連携手順](docs/integration.md#通常windowsのレジストリを明示して操作する)を参照する。

## ボリューム別の復元領域

この節は既存schema 4の互換経路である。`backupDirectory`は全schemaの中央metadata、レジストリsnapshotと旧コピーの保存先である。schema 4のpayloadは`<volumeRoot>\.Prunlet-Recovery-<SID>\<storeKey>\<operationId>\0000.entry`にある。新規ゴミ箱操作はこの専用領域を作らない。

schema 6の復元中だけは別の`<volumeRoot>\.Prunlet-Restore-<SID>\<storeKey>\<stageId>`を使う。`volumeRecoveryDirectories`指定時は設定baseへ`.restore`を付けた同一ボリュームの場所を使う。親領域は作成時から本人・SYSTEM限定のACLと所有markerで検証し、中央metadataとともに通常削除から保護する。stageの実体は旧データの容量予算・自動整理に含めない。これは復元中の一時移動であり、新規削除の退避fallbackではない。対象自身の明示ACLや外部ハードリンクによるアクセスまで隔離する機構ではない。

任意設定`volumeRecoveryDirectories`は`D:\`などのローカルドライブルートから専用baseへの対応である。フォルダーマウントやreparse祖先を通常パスとして通さない。テスト・管理時も必ず移動元と同じボリュームへ置き、中央metadataと専用baseは相互に包含できない。別ボリュームへのコピーfallbackは行わない。専用領域を作成できない、ファイルシステムや権限が必要な検証・renameに対応しない場合は元対象を残す。

StoreRootは本人・SYSTEM・Administratorsだけに許可するACLを検証し、所有marker、volume GUID、ボリュームserialと128-bit File IDを照合する。既存の不明なディレクトリや別操作の領域を流用しない。中央metadataと各ボリュームの専用領域は通常削除から保護する。

## フォルダーの削除と復元

新規操作はschema 6でフォルダーごとWindowsのゴミ箱へ移す。非空フォルダーには明示`recursive`が必要で、復元先へマージしない。既存schema 4のroot renameによる非上書き復元も維持する。

## 通常属性の保存と復元

Windowsゴミ箱での属性・ACL・ADS・File ID・case-sensitive属性の保持は実プロセスE2Eで確認する。ゴミ箱内の継承DACLはWindowsが管理する。snapshot付きschema 6の復元成功にはOwner/Group/DACLのnative bytesと全control flagの完全一致を要求する。DACLは同一IDを確認したハンドルへ`NtSetSecurityObject`で戻し、Owner/Groupは変更しない。SACLはこのsnapshotの対象外で、完全SACLの保全検証とは区別する。noncanonical DACLの転送中の挙動は未検証である。Shellが扱えない対象を直接削除へ切り替えない。以下のrename後の属性調整はschema 4と6の復元に適用する。schema 4の既存検証では継承ACEの明示化や同値Allow ACEの統合は権限変更と区別し、復元後のSDDLは元と完全一致で比較する。

通常ファイルのrenameはDELETEハンドルを閉じる際にArchive属性を付ける。Archiveのない対象だけは移動前に属性変更権限を確保し、ハンドルを閉じてから元属性へ戻す。権限を確保できない対象は移動前に拒否する。復元intentにも移動直前の属性を永続化する。Windowsがrenameを拒否した場合に、読み取り専用属性やアクセス権限を緩めて再試行することはない。

## 特殊対象の保存と復元

ADSは元オブジェクトに付随して移動し、`Zone.Identifier`や正確なstream名も保持する。シンボリックリンク・ジャンクションはリンク自体を移動し、リンク先を辿らない。未知のreparseタグ・ADS付きリンク・ネットワークパス・ワイルドカードは拒否する。

ハードリンクでは指定した名前だけが移動する。外部に残る別名と同じ実体を共有するため、別名からの書込みは保管中の内容にも反映される。新方式は保存時点の不変コピーではない。復元後も同じリンク関係を保持する。

## 旧コピー形式の互換性

schema 1/2/3のコピー作成とschema 4の専用領域への新規移動を通常経路から外し、既存操作のrestore・purge・maintainに必要な読込みと検証を残す。schema 1はfile、2はflat tree、3はADS・reparse情報付きコピーである。既存記録をschema 6へ書き換えない。

旧形式の`manifest.json`・`0000.bak`等はサイズ・SHA-256・型・実体・単一リンクを検証して扱う。`backup_ready`はコピー準備状態であり、削除成功を意味しない。復元は新規作成と内容検証を行い、既存ファイルを上書きしない。旧ツリー復元は既存の通常ディレクトリを利用でき、旧コピーは復元成功後も残る。旧ハードリンクの復元は独立コピーで、属性を持たない旧記録は元属性を再現しない。case-sensitive属性の変更が必要ならWindowsの必要権限を要求し、失敗時はコピーを保持する。

## 復元データの自動整理

Prunletの保持制御は既存schema 1〜4とレジストリschema 5だけを対象とし、既定7日・合計1 GiBを維持する。期限切れ、次いで必要容量に応じた古い操作を整理する。レジストリ削除前と`maintain --apply`が同じCoreを使う。定期タスクは毎日03:00とログオン時に保守専用`prunlet-maintenance.exe`を起動する。専用exeはWindows GUI subsystemで`--config <path> maintain --apply`だけを受理し、通常CLIはconsole subsystemを保つ。所有を確認した旧タスクはCommandだけを移行し、Triggers・Principals・Settingsを保つ。新規ファイル削除は旧データの整理を起動しない。schema 6はWindowsが保持・清掃し、Prunletはゴミ箱を空にしない。

共通`maintenance.lock`で実削除・復元・purge・maintainを直列化する。元対象の容量走査、整理前後の既存全体走査、移動直前・直後の照合で予算を検証する。通常の有効予算は`maxRecoveryBytes`。1回の入力合計がそれを超える場合だけ`max(maxRecoveryBytes, incomingBytes)`を有効予算とし、既存データを0バイトまで安全に整理できることを必要とする。設定は変更せず、次回の削除・maintainは通常予算を再適用する。

中央記録と、利用可能なローカルボリュームの同じStoreKeyの実体を両側から照合する。中央記録を失った退避データや未知の領域内データ、計数できない領域、不正・破損・使用中・矛盾した記録を無視して上限達成とは判定しない。安全に容量を確保できなければ新しい移動を停止する。ハードリンクの外部別名など、Prunletの共通ロック外からの変更を不変コピーとして扱わない。

移動拒否やrollback成功でpayloadがないことを確定できた対象は、`move-<index>-cancelled.json`を永続化する。元パスの後日の削除・置換を根拠に容量不明へ戻さない。中断した未移動intentの確定はapplyだけが行い、dry-runでは記録を変更しない。purge intent以降の対象は、一部の子が既に消えている可能性があるため復元を拒否する。

ロック競合は解放まで待機し、1秒以上で経過時間、以後5秒おきと取得後にも通知する。CLIはstderrへ即時通知しstdoutを結果JSON用に保つ。MCPは文字列・整数の`params._meta.progressToken`を持つ要求だけに同じtokenの`notifications/progress`を送り、最終応答後は送らない。利用プロセスの強制終了や別方式への切替は行わない。

## 操作履歴の圧縮

`compact-history [--dry-run | --apply]`は既定検査のみで、旧schema 1/2/3の正常なpurge済み履歴JSONをNTFS圧縮する。JSONの内容・名前・ロック・操作IDを保持し、圧縮前後のSHA-256と長さを照合する。コピーが残る操作、未知項目、不正記録、使用中などは理由付きで保持する。

schema 4の移動記録、schema 5のレジストリ記録、schema 6のゴミ箱記録は履歴圧縮から外し、理由付き`retained`として保持する。metadataとpayloadの容量集計は分離する。

## 復元データの明示整理

`purge <operationId>`は検査のみ、`--apply`で適用する。schema 4はmarker・manifest・receipt・File IDを照合し、purge intentの永続化後に退避実体を整理する。処理後のreceiptを残し、矛盾や欠損を推測で削除しない。中央記録・ロックは保持する。MCPへpurgeは追加しない。

旧schema 1/2/3は従来の検証済みコピーと、失敗・欠損項目に対応する正規名の途中コピーを扱う。途中コピーを含むpurge intentのschema 2はサイズ・SHA-256を`incompleteTargets`へ記録し、検証済みコピーは`targets`へ残す。旧intentのschema 1も読み、サイズ・hash不一致を途中コピーへ格下げしない。intentを永続化してから削除し、未知ファイル・不正記録・リンクを保全する。

## 不変条件と設計判断

- 対象フォルダーの許可リストは設けない。旧`allowedRoots`・`--allowed-root`・`-AllowedRoot`は互換入力だけに使用する。呼出し側の削除許可・ホストの承認・管理ポリシーを維持する。
- slash表記・拡張長ローカルパス・8.3短縮名・MSIX転送を実体へ揃え、新記録は実体パスを保存する。祖先リンク・UNC・未対応デバイス構文・検証不能な実体は停止する。
- 新規操作はShell項目とFile IDを照合する。既存schema 4は対象・親・専用領域の保持ハンドルも照合する。復元先を上書き・マージしない。
- 中断時は先行永続化した記録と実体を照合し、確定できないものを保持する。

## 大量操作の記録

schema 4は入力rootごとに記録するため、再帰ツリーの全子項目をmanifestへ展開しない。容量・安全性の事前走査は省かない。旧schema 1/2/3のmanifest・結果・purge intentは総件数・総バイト数の旧固定上限を設けず増分読込みし、構造・重複property・型・個々の値を検証する。旧32,768件・8 MiBを超える記録も互換経路で扱う。

## 導入と検証の境界

インストーラーはGitHubの既定ブランチ最新HEADを解決し、そのSHAのアーカイブを検査・ビルドして配置する。ローカルクローンへのフォールバックはしない。`source-info.json`に取得元・ブランチ・SHAとアーカイブ・exeのハッシュを記録する。更新対象の製品ファイルを検証済みバックアップへ保全し、既存設定と復元データを保持する。失敗時は変更済み製品と登録設定の復旧を試み、復旧失敗時は保存先を報告する。

定期整理タスクの識別子は現在のユーザーSID・exe・設定の絶対パスから導出する。所有マーカー・ユーザー・実行先が一致する既存タスクは再登録せず、時刻や無効化を保持する。不一致は製品ファイルの変更前に拒否する。更新バックアップには既存タスクのXMLと復旧情報も保存し、登録の復旧に失敗した場合は残った登録先の製品ファイルを保持する。Codex連携の解除ではタスクを残し、専用の解除入口で所有を検証して解除する。

登録・解除は所有部分だけを変更する。既存の同名登録、明示的なhook無効化、変更対象のTOMLを安全に扱えない構文は自動更新を拒否する。設定保持を優先するため、手動登録が必要な場合がある。

hookの起動はシステムの`cmd.exe /d /c call`を明示し、Codexが引き継ぐ既定shellに依存せずネイティブexeへ到達させる。CMD・PowerShellの展開文字を含む登録パスは書込み前に拒否する。既知の旧起動経路は所有handlerの内容が一致する場合だけ移行し、利用者の編集や他handlerを保持する。登録はhookの信頼を付与せず、`requiresHookTrust`で利用者の確認が必要なことを通知する。具体的な登録コマンドと信頼操作は[連携手順](docs/integration.md#登録)を参照する。

`-RegisterAgentInstructions`は`-RegisterCodex`と併用し、共通AGENTSから専用の`PRUNLET.md`を読む経路と配置済みexe・設定の絶対パスを明示登録する。初回からCMDのCLIを選ぶ指示であり、exe・設定をCMDで安全に表現できない場合は事前に同じCoreのMCPを選ぶ。登録・解除は管理マーカー・参照ブロック・guideのハッシュで所有範囲を限定し、既存本文と利用者の編集を保護する。旧MCP優先ブロックの移行は既知の正確な内容・ハッシュに一致する場合だけ行う。オプションを省略すると共通指示は変更しない。登録途中の失敗ではMCP・hookと同様に指示ファイルも復旧対象にする。

配置済みの旧PowerShell backendは、更新バックアップを検証してから同じCoreでゴミ箱へ移して退役させる。退役専用設定のmetadataは通常設定から分離し、復元用の操作IDを保持する。通常経路に旧backendを残さない。

検証は実exe・stdio・hook・登録スクリプトを別プロセスで動かし、外部JSONレポートへ結果を残す。latest導入のE2Eは検証用アーカイブと実GitHubの確認を区別する。Codex自身のhook読込・拒否・承認、共通指示の読込とCLI選択は別途実ホストで確認する。[検証手順](docs/verification.md)を参照する。

## 依存更新の境界

`.github/dependabot.yml`はGitHub ActionsとNuGetの更新を毎週月曜09:00（日本時間）に確認し、minor・patchをまとめ、majorは個別PRにする。`.github/workflows/dependency-validation.yml`はDependabotのPRまたは手動起動を対象に、Windows・.NET 10でrestore・buildとCLI・MCP・hookの通常E2Eを行う。出力はrunnerの一時領域へ分離し、checkoutの認証情報を保持せず、権限はcontentsの読取りに限定する。

`.github/workflows/dependabot-auto-merge.yml`は、書込み権限を持つ処理を信頼済み既定ブランチ側で実行し、PRのコードは実行しない。対象は所有者`1llum1n4t1s`のリポジトリで、同一リポジトリから既定ブランチへ向けたDependabotの非draft PRに限る。依存更新として判定できる差分と署名済みコミットを検査し、workflowの変更は`uses`の参照更新だけを許可する。PRのhead SHAに対応する依存検証の最新実行が成功し、他のcheck・commit statusにも失敗や未完了がなく、競合がない場合だけマージを試みる。直前にhead・既定ブランチのSHAとマージ可能状態を再確認し、変更や未検証状態があれば保留する。GitHub側のマージ要件も維持する。依存検証の成功と書込み処理を分離することで、未検証のPRコードをマージ権限で実行する経路を避ける。
