# Prunletの設計

PrunletはWindowsのファイル・フォルダーとシンボリックリンク・ジャンクションを、同一ボリュームの専用領域へrenameして退避するツールである。新規削除ではコピー後の削除を行わない。CLIとローカルstdio MCPを単一exeで提供し、Codexのフックは直接削除を検査・拒否してCLI手順を案内する。利用手順は[README](README.md)、開発・検証の規約は[AGENTS.md](AGENTS.md)を参照する。

## 構成と責務

| 実装 | 責務と境界 |
| --- | --- |
| `Program.cs` / `Protocol/McpServer.cs` | CLI・JSON出力、stdio JSON-RPCと3つのMCPツール |
| `Core/DeletionService.Moves.cs` / `Core/NativeFiles.Moves.cs` | 新規削除と復元、ハンドルによる同一ボリューム・非上書きrename、容量の事前走査 |
| `Core/MoveOperation.cs` / `Core/DeletionService.MoveRecords.cs` | schema 4の中央manifest、追記するreceiptの永続化と照合、中断状態の検証 |
| `Core/VolumeRecoveryStore.cs` | ボリューム別専用領域、所有者ACL・marker・ボリュームとFile IDの照合 |
| `Core/DeletionService.MoveMaintenance.cs` | schema 4と旧コピーの容量集計・保持制御・明示purgeの統合 |
| `Core/DeletionService.Metadata.cs` / `Core/DeletionService.Retention.cs` / `Core/DeletionService.Purge.cs` | schema 1/2/3の読込み・コピー検証・復元・整理の互換経路 |
| `Core/DeletionService.HistoryCompaction.cs` / `Core/HistoryCompactionResult.cs` | 旧コピー形式の整理済み履歴のNTFS圧縮 |
| `Core/PrunletConfig.cs` / `Core/PathPolicy.cs` / `Core/NativeFiles.cs` | 設定と実体パス検証、祖先の固定、旧コピー形式を含むWin32処理 |
| `Protocol/HookRouter.cs` / `Protocol/BoundedInputReader.cs` | 入力検査と直接削除の拒否・CLI案内。削除・自動置換をしない |
| `integration/` / `scripts/Install-Prunlet.ps1` | 所有範囲に限定した登録・解除、GitHub最新HEADからの導入 |
| `scripts/Publish-Prunlet.ps1` / `scripts/Verify-*.ps1` | 外部絶対パスへのビルドと別プロセスE2E |

## 削除と復元のデータフロー

1. 設定と1〜256件のパスを検証する。重複・祖先重複・復元領域内・復元領域を包含する対象を拒否する。入力と祖先の実体を確認し、リンクはリンク自体を扱う。非空フォルダーには明示`recursive`を必要とする。
2. 実削除は共通`maintenance.lock`を取得し、対象ツリーを走査して通常データとADSの容量を計数する。元対象と既存復元データを検証し、整理前後に容量を走査して必要容量を確保する。検査・計数・整理に失敗した場合は移動を始めない。dry-runは読取り検査のみで、専用領域・操作記録・共通ロックを作らない。
3. `backupDirectory`の32桁小文字GUID操作フォルダーに`operation.lock`とschema 4の`move-manifest.json`を置く。対象と元親、退避先と親のボリューム・128-bit File ID・種類を記録し、`move_intent`をflushしてから実体を移動する。
4. ハンドルで対象と移動先親を再照合し、`ReplaceIfExists=false`のrenameで`0000.entry`などへ移動する。フォルダーは子をコピー・個別削除せず、ツリーのルートごと移動する。子の計測ハンドルはrootを固定した後に解放し、移動後に実体と容量を再照合する。予約容量を超えた場合は非上書きで戻し、戻せない場合も退避実体と記録を保持して失敗とする。完了receiptは検証後に新規作成・永続化し、既存内容を上書きしない。
5. 結果の`operationId`と項目ごとの成否を返す。複数入力の全体は一括トランザクションではないため、途中失敗では既に移動した対象と記録を保持する。

復元は記録・receipt・元親・退避先・実体のIDを照合し、復元intentを永続化してから同一オブジェクトを元パスへ非上書きrenameする。既存ファイル・フォルダーへはマージせず`conflict`とし、退避実体を保持する。成功時は`restored`、整合する復元済み記録の再実行は`already_restored`となる。復元は消費型であり、成功後に退避実体は残らない。元親がなくなった場合やIDが変わった場合は停止する。

中断時はmanifestのintent、immutable receipt、元パスと退避先のFile IDから状態を判定する。移動済みだが完了receiptがない場合も実体を照合して扱う。欠損・両方の存在・ID不一致・記録の矛盾など状態が確定できない場合は保全して停止し、存在しないことだけを理由に成功へ変更しない。操作一覧は中央操作IDの列挙であり、復元可能性を保証しない。

## ボリューム別の復元領域

`backupDirectory`は中央metadataと既存schema 1/2/3コピーの保存先として維持する。新規payloadの既定位置は`<volumeRoot>\.Prunlet-Recovery-<SID>\<storeKey>\<operationId>\0000.entry`である。`storeKey`は中央metadataの配置に対応する識別子で、異なる設定の領域を混同しない。

任意設定`volumeRecoveryDirectories`は`D:\`などのローカルドライブルートから専用baseへの対応である。フォルダーマウントやreparse祖先を通常パスとして通さない。テスト・管理時も必ず移動元と同じボリュームへ置き、中央metadataと専用baseは相互に包含できない。別ボリュームへのコピーfallbackは行わない。専用領域を作成できない、ファイルシステムや権限が必要な検証・renameに対応しない場合は元対象を残す。

StoreRootは本人・SYSTEM・Administratorsだけに許可するACLを検証し、所有marker、volume GUID、ボリュームserialと128-bit File IDを照合する。既存の不明なディレクトリや別操作の領域を流用しない。中央metadataと各ボリュームの専用領域は通常削除から保護する。

## フォルダーの削除と復元

新規操作はファイル・フォルダー・特殊対象ともschema 4で記録する。ツリー全体を事前走査するため、件数に応じた走査時間と保持ハンドルが必要だが、データの複製は行わない。rootのrenameにより、空フォルダー・階層・正確な名前を同じオブジェクトのまま保持する。復元先の既存フォルダーへはマージしない。

## 通常属性の保存と復元

新規操作ではACL、読み取り専用・隠し・システム等の属性、case-sensitive属性、圧縮状態を同一オブジェクトの移動によって保持する。移動した木のrootではWindowsが継承ACEを一時的に明示化し、同値のAllow ACEを統合する場合がある。E2Eではこの表現上の変化を権限変更と区別し、子項目と元親へ復元後のACLは元のSDDLとの完全一致で検証する。比較と改変検出の規約は[AGENTS.mdの追加検証](AGENTS.md#ビルドと検証)を参照する。

通常ファイルのrenameはDELETEハンドルを閉じる際にArchive属性を付ける。Archiveのない対象だけは移動前に属性変更権限を確保し、ハンドルを閉じてから元属性へ戻す。権限を確保できない対象は移動前に拒否する。復元intentにも移動直前の属性を永続化する。Windowsがrenameを拒否した場合に、読み取り専用属性やアクセス権限を緩めて再試行することはない。

## 特殊対象の保存と復元

ADSは元オブジェクトに付随して移動し、`Zone.Identifier`や正確なstream名も保持する。シンボリックリンク・ジャンクションはリンク自体を移動し、リンク先を辿らない。未知のreparseタグ・ADS付きリンク・ネットワークパス・ワイルドカードは拒否する。

ハードリンクでは指定した名前だけが移動する。外部に残る別名と同じ実体を共有するため、別名からの書込みは保管中の内容にも反映される。新方式は保存時点の不変コピーではない。復元後も同じリンク関係を保持する。

## 旧コピー形式の互換性

新規通常経路からschema 1/2/3のコピー作成を外し、既存操作の復元・purge・maintainのために読込みと検証を残す。schema 1はfile、schema 2はfile/directoryのflat tree、schema 3はADS・reparse情報を含むコピー形式である。既存記録を書き換えてschema 4へ移行しない。

旧形式の`manifest.json`・`0000.bak`等はサイズ・SHA-256・型・実体・単一リンクを検証して扱う。`backup_ready`はコピー準備状態であり、削除成功を意味しない。復元は新規作成と内容検証を行い、既存ファイルを上書きしない。旧ツリー復元は既存の通常ディレクトリを利用でき、旧コピーは復元成功後も残る。旧ハードリンクの復元は独立コピーで、属性を持たない旧記録は元属性を再現しない。case-sensitive属性の変更が必要ならWindowsの必要権限を要求し、失敗時はコピーを保持する。

## 復元データの自動整理

既定は操作作成から7日・合計10 GiBで、項目を省略した旧設定にも適用する。新しい退避実体と旧コピーを合計し、期限切れ、次いで容量確保に必要な古い操作を整理する。実削除前と`maintain --apply`が同じ経路を使い、インストーラーの定期タスクは毎日03:00とログオン時に同じCLIを実行する。dry-run・復元・一覧・hook検査では自動整理しない。

共通`maintenance.lock`で実削除・復元・purge・maintainを直列化する。元対象の容量走査、整理前後の既存全体走査、移動直前・直後の照合で予算を検証する。通常の有効予算は`maxRecoveryBytes`。1回の入力合計がそれを超える場合だけ`max(maxRecoveryBytes, incomingBytes)`を有効予算とし、既存データを0バイトまで安全に整理できることを必要とする。設定は変更せず、次回の削除・maintainは通常予算を再適用する。

中央記録と、利用可能なローカルボリュームの同じStoreKeyの実体を両側から照合する。中央記録を失った退避データや未知の領域内データ、計数できない領域、不正・破損・使用中・矛盾した記録を無視して上限達成とは判定しない。安全に容量を確保できなければ新しい移動を停止する。ハードリンクの外部別名など、Prunletの共通ロック外からの変更を不変コピーとして扱わない。

移動拒否やrollback成功でpayloadがないことを確定できた対象は、`move-<index>-cancelled.json`を永続化する。元パスの後日の削除・置換を根拠に容量不明へ戻さない。中断した未移動intentの確定はapplyだけが行い、dry-runでは記録を変更しない。purge intent以降の対象は、一部の子が既に消えている可能性があるため復元を拒否する。

ロック競合は解放まで待機し、1秒以上で経過時間、以後5秒おきと取得後にも通知する。CLIはstderrへ即時通知しstdoutを結果JSON用に保つ。MCPは文字列・整数の`params._meta.progressToken`を持つ要求だけに同じtokenの`notifications/progress`を送り、最終応答後は送らない。利用プロセスの強制終了や別方式への切替は行わない。

## 操作履歴の圧縮

`compact-history [--dry-run | --apply]`は既定検査のみで、旧schema 1/2/3の正常なpurge済み履歴JSONをNTFS圧縮する。JSONの内容・名前・ロック・操作IDを保持し、圧縮前後のSHA-256と長さを照合する。コピーが残る操作、未知項目、不正記録、使用中などは理由付きで保持する。

schema 4の移動記録とreceiptは当面この圧縮対象から外し、理由付き`retained`として保持する。`maintain`と実削除前の自動経路も同じ境界を守る。履歴metadataの物理容量と復元payloadの容量予算は分離する。[検証手順](docs/verification.md#操作履歴の圧縮)を参照する。

## 復元データの明示整理

`purge <operationId>`は検査のみ、`--apply`で適用する。schema 4はmarker・manifest・receipt・File IDを照合し、purge intentの永続化後に退避実体を整理する。処理後のreceiptを残し、矛盾や欠損を推測で削除しない。中央記録・ロックは保持する。MCPへpurgeは追加しない。

旧schema 1/2/3は従来の検証済みコピーと、失敗・欠損項目に対応する正規名の途中コピーを扱う。途中コピーを含むpurge intentのschema 2はサイズ・SHA-256を`incompleteTargets`へ記録し、検証済みコピーは`targets`へ残す。旧intentのschema 1も読み、サイズ・hash不一致を途中コピーへ格下げしない。intentを永続化してから削除し、未知ファイル・不正記録・リンクを保全する。

## 不変条件と設計判断

- 対象フォルダーの許可リストは設けない。旧`allowedRoots`・`--allowed-root`・`-AllowedRoot`は互換入力だけに使用する。呼出し側の削除許可・ホストの承認・管理ポリシーを維持する。
- slash表記・拡張長ローカルパス・8.3短縮名・MSIX転送を実体へ揃え、新記録は実体パスを保存する。祖先リンク・UNC・未対応デバイス構文・検証不能な実体は停止する。
- 対象・親・専用領域の保持ハンドルとFile ID照合を用い、別名・差し替え・別volumeを検査する。新規削除・復元ではコピーfallbackを行わず、復元先を上書きしない。
- 中断時は先行永続化した記録と実体を照合し、確定できないものを保持する。

## 大量操作の記録

schema 4は入力rootごとに記録するため、再帰ツリーの全子項目をmanifestへ展開しない。容量・安全性の事前走査は省かない。旧schema 1/2/3のmanifest・結果・purge intentは総件数・総バイト数の旧固定上限を設けず増分読込みし、構造・重複property・型・個々の値を検証する。旧32,768件・8 MiBを超える記録も互換経路で扱う。

## 導入と検証の境界

インストーラーはGitHubの既定ブランチ最新HEADを解決し、そのSHAのアーカイブを検査・ビルドして配置する。ローカルクローンへのフォールバックはしない。`source-info.json`に取得元・ブランチ・SHAとアーカイブ・exeのハッシュを記録する。更新対象の製品ファイルを検証済みバックアップへ保全し、既存設定と復元データを保持する。失敗時は変更済み製品と登録設定の復旧を試み、復旧失敗時は保存先を報告する。

定期整理タスクの識別子は現在のユーザーSID・exe・設定の絶対パスから導出する。所有マーカー・ユーザー・実行先が一致する既存タスクは再登録せず、時刻や無効化を保持する。不一致は製品ファイルの変更前に拒否する。更新バックアップには既存タスクのXMLと復旧情報も保存し、登録の復旧に失敗した場合は残った登録先の製品ファイルを保持する。Codex連携の解除ではタスクを残し、専用の解除入口で所有を検証して解除する。

登録・解除は所有部分だけを変更する。既存の同名登録、明示的なhook無効化、変更対象のTOMLを安全に扱えない構文は自動更新を拒否する。設定保持を優先するため、手動登録が必要な場合がある。

hookの起動はシステムの`cmd.exe /d /c call`を明示し、Codexが引き継ぐ既定shellに依存せずネイティブexeへ到達させる。CMD・PowerShellの展開文字を含む登録パスは書込み前に拒否する。既知の旧起動経路は所有handlerの内容が一致する場合だけ移行し、利用者の編集や他handlerを保持する。登録はhookの信頼を付与せず、`requiresHookTrust`で利用者の確認が必要なことを通知する。具体的な登録コマンドと信頼操作は[連携手順](docs/integration.md#登録)を参照する。

`-RegisterAgentInstructions`は`-RegisterCodex`と併用し、共通AGENTSから専用の`PRUNLET.md`を読む経路と配置済みexe・設定の絶対パスを明示登録する。初回からCMDのCLIを選ぶ指示であり、exe・設定をCMDで安全に表現できない場合は事前に同じCoreのMCPを選ぶ。登録・解除は管理マーカー・参照ブロック・guideのハッシュで所有範囲を限定し、既存本文と利用者の編集を保護する。旧MCP優先ブロックの移行は既知の正確な内容・ハッシュに一致する場合だけ行う。オプションを省略すると共通指示は変更しない。登録途中の失敗ではMCP・hookと同様に指示ファイルも復旧対象にする。

配置済みの旧PowerShell backendは、更新前の製品バックアップを検証してからCoreで同一ボリュームの復元領域へ退避して退役させる。退役専用設定は中央metadataと保持設定を独立させ、通常設定の`volumeRecoveryDirectories`だけを引き継ぐ。通常経路に旧backendを残さない。

検証は実exe・stdio・hook・登録スクリプトを別プロセスで動かし、外部JSONレポートへ結果を残す。latest導入のE2Eは検証用アーカイブと実GitHubの確認を区別する。Codex自身のhook読込・拒否・承認、共通指示の読込とCLI選択は別途実ホストで確認する。[検証手順](docs/verification.md)を参照する。

## 依存更新の境界

`.github/dependabot.yml`はGitHub ActionsとNuGetの更新を毎週月曜09:00（日本時間）に確認し、minor・patchをまとめ、majorは個別PRにする。`.github/workflows/dependency-validation.yml`はDependabotのPRまたは手動起動を対象に、Windows・.NET 10でrestore・buildとCLI・MCP・hookの通常E2Eを行う。出力はrunnerの一時領域へ分離し、checkoutの認証情報を保持せず、権限はcontentsの読取りに限定する。

`.github/workflows/dependabot-auto-merge.yml`は、書込み権限を持つ処理を信頼済み既定ブランチ側で実行し、PRのコードは実行しない。対象は所有者`1llum1n4t1s`のリポジトリで、同一リポジトリから既定ブランチへ向けたDependabotの非draft PRに限る。依存更新として判定できる差分と署名済みコミットを検査し、workflowの変更は`uses`の参照更新だけを許可する。PRのhead SHAに対応する依存検証の最新実行が成功し、他のcheck・commit statusにも失敗や未完了がなく、競合がない場合だけマージを試みる。直前にhead・既定ブランチのSHAとマージ可能状態を再確認し、変更や未検証状態があれば保留する。GitHub側のマージ要件も維持する。依存検証の成功と書込み処理を分離することで、未検証のPRコードをマージ権限で実行する経路を避ける。
