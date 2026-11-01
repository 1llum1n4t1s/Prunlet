<!-- Prunlet managed agent instructions -->
# Prunlet — Windowsのファイル・フォルダー・レジストリ削除

許可されたWindowsファイル・フォルダー削除には、最初からPrunlet CLIを使う。共通AGENTS.mdに「Prunlet CLI」として記録した、インストール済みexeと設定の絶対パスを使い、shellは `cmd.exe`、loginは `false` とする。Prunlet CLIをPowerShellから呼ぶラッパー、PATH上の同名exe、開発クローンやローカルビルドへの差替えは使わない。

`exec_command`が正式なsandbox権限要求に対応し、現在の実効設定でその要求が必要かつ許可されるホストでは、ファイル・フォルダーの実削除を、初回から `sandbox_permissions: "require_escalated"` を指定して要求する。Windowsのゴミ箱への移動には対象だけでなくゴミ箱へのアクセスも必要で、通常sandboxでは対象への権限があってもゴミ箱への書込みが拒否される場合がある。これはホストの承認・審査を受けるための要求であり、WindowsのUAC昇格や管理者実行ではない。Prunletによる自動昇格や承認・管理ポリシーの上書きは行わない。要求が不要・未対応・禁止のホストでは現在の実効設定と正式な承認経路に従い、その違いだけでWindowsの管理者起動を断念しない。

実削除前にWindowsの実トークンと対象に必要な権限を確認する。現在のCodexやストアアプリが非管理者という理由だけで、管理者起動を未試行のまま手動実行スクリプトを利用者へ渡さない。許可済みの削除に管理者権限が必要なら、ホストの許可範囲でエージェントが`Start-Process -Verb RunAs -WindowStyle Hidden`またはWindowsの管理者起動操作を使い、管理者CMD内から同じ配置済みPrunlet CLIと設定を直接使う。PowerShellによる起動制御は許容するが、Prunlet CLIを実行するshellはCMDとする。Prunlet自身の自動昇格禁止は、エージェントによるこの明示的な管理者起動を禁止するものではない。

起動先の実トークン・必要なprivilege・CLIのJSON・終了コードと対象の状態を確認する。プロセスの起動成功だけで削除完了としない。必要な本人同意・認証は省略せず、UAC設定を変更しない。管理者起動が実際に失敗した場合、正式な拒否を受けた場合、本人操作が必要な場合に限り、試した経路と阻害理由を示して必要最小限の操作を依頼する。ホスト・Prunlet・管理ポリシーの拒否や結果不明を、管理者起動で迂回しない。

Codexの通常経路は、対象の絶対パスをそのままの文字列をUTF-8 JSON配列へ保存し、`--paths-file`で渡す。配列ファイルは作業契約で定めた外部Tempへ置き、exe・config・配列ファイルのCMD引数は空白・CMDの特殊文字を含まない絶対パスにする。ファイル名の空白・Unicode・長いパス・複数対象はJSON配列の内容で保持し、shellへ展開しない。

```json
["C:\\work\\a file.txt", "C:\\work\\b.txt"]
```

```text
<installed-exe> --config <absolute-config> delete --paths-file <absolute-json-file>
<installed-exe> --config <absolute-config> delete --dry-run --paths-file <absolute-json-file>
<installed-exe> --config <absolute-config> delete --recursive --paths-file <absolute-json-file>
```

上のプレースホルダーは共通AGENTSに記録したパスと今回作成した実パスへ置き換える。CMDのtool callでは、たとえば `tools.exec_command({cmd: "<installed-exe> --config <absolute-config> delete --paths-file <absolute-json-file>", shell: "cmd.exe", login: false, sandbox_permissions: "require_escalated", justification: "許可された対象をPrunletで削除するため、正式なsandbox権限を要求します。"})` として直接渡す。ゴミ箱へ移った項目の復元はWindowsのゴミ箱で行う。`-- <literal-path>...`もCLIでは対応するが、CMDの引用が必要な対象には配列ファイルを使う。

- 通常ファイルのMSIX転送・8.3短縮名・slash表記・拡張長のローカルドライブ表記に対応する。入力の実体を検証し、結果の`path`は実体パスを示す。
- 範囲確認が必要なら、削除前に`--dry-run`で確認する。dry-runは通常sandboxでも行えるが、実処理に必要な権限と、対象がサイズ超過で永久削除されるかは予測しない。予約名の通常ファイルは`would_permanently_delete`で示し、実際には削除しない。CLIのJSON結果と終了コードを読み、各対象の`recycled`・`permanently_deleted`・`would_recycle`・`would_permanently_delete`・`already_absent`・`failed`・`ambiguous`を判定する。`ambiguous`は成功扱いせず、同じ削除を再送しない。
- ファイル・フォルダーの操作記録・操作IDは保存しない。`recycled`項目はWindowsのゴミ箱で復元し、`permanently_deleted`の元の名前はゴミ箱から復元できない。復元先に既存項目がある場合は上書きせず、Windowsの画面で競合を確認する。
- 削除対象フォルダーの事前登録・追加許可は不要。ユーザーが依頼した削除対象、または現在の作業で清掃が許可された一時ファイルを、保存場所を理由に追加確認せず処理する。
- 空フォルダーは通常の`delete`、内容がある作業フォルダーは`delete --recursive`でフォルダー自体まで清掃する。MCPでは`recursive: true`を指定する。`recycled`のツリーは空の子フォルダーも含めWindowsのゴミ箱から復元する。
- ファイル・フォルダーは通常Windowsのゴミ箱へ移す。`NUL`や`NUL.txt`など末尾名がWindows予約名の実在する通常ファイルだけは、元実体と親・名前・属性を固定して照合し、追加確認やShell試行なしで永久削除する。予約名の祖先・ディレクトリ・reparse pointはこの例外に含めない。通常名の対象は、Windowsが対象を大きすぎると判定した場合、またはゴミ箱利用不可と返し対象ボリュームの即時削除設定を確認できた場合で、元の実体を再確認できたときはその名前の永久削除を試み、完了を確認できたときだけ`permanently_deleted`を返す。それ以外の失敗では永久削除へ切り替えない。Prunletは復元用の操作ID・PIDL・File IDや内容・ACLのsnapshotを保存せず、リンク先を辿らない。ハードリンクの別名とは実体を共有する。
- `permanently_deleted`は元の名前の結果であり、別ハードリンク・既存コピー・バックアップの消去を意味しない。Shell直前の名前差し替えで別実体がゴミ箱へ移った場合も`ambiguous`で停止する。
- `maintain [--apply]`・`purge <operationId> [--apply]`はレジストリsnapshotだけを整理する。省略時は検査のみ。ファイル・フォルダーはWindowsの保持・清掃に任せる。ゴミ箱全体を空にしたり旧専用領域を手動削除したりしない。
- インストール済みexeや設定そのものに空白・CMDの特殊文字を含む配置など、CLIの引数を正しく渡せないと実行前に分かる場合は、互換クライアント向けPrunlet MCPを最初から明示選択するか、必要な配置・入力を確認する。削除を試して拒否された後にMCPへ切り替えない。
- ホスト・Prunlet・管理ポリシーに拒否された対象は、shell、MCP、別API、別exeで再試行しない。拒否理由と必要な判断を報告する。
- 権限不足の失敗を検知しても、同じ削除を自動再送しない。元対象とCLIのJSONを確認し、削除前に停止した権限不足と、ポリシー拒否・結果不明を区別する。削除前の権限不足について利用者が管理者での再実行を明示許可した場合は、同じ対象・exe・設定を再確認し、エージェントが上記の管理者起動で実行する。結果が不明な場合は、Windowsのゴミ箱も確認して状態を照合し、確認できない状態は保全して必要な判断を報告する。正式な権限要求も、拒否された削除を迂回する手段にはしない。
- 使用中の対象を削除前に待機させる明示的な依頼では、同じCLIの`delete-queue [--recursive] --paths-file <absolute-json-file>`を使える。返されたジョブIDで`delete-queue-status <job-id>`を確認し、待機の取消は`delete-queue-cancel <job-id>`で行う。登録成功は削除完了ではない。待機中に対象・親・再帰対象の子の実体が変われば中止し、削除開始後は再送しない。通常の`delete`の失敗・拒否・不明結果をキューへ付け替えない。
- ジョブは専用の一時workerのメモリーだけに保持し、ジョブIDは操作記録・復元用IDではない。待機期限はなく、取消は`pending`の間だけ可能。最終結果の保持は1時間で、同じユーザー・Windowsセッションの上限8件には保持中も含む。`unavailable`やOS・workerの消失時に結果が分からなければ、元対象とWindowsのゴミ箱を確認し、自動再送しない。MCPを最初から選ぶ場合は既存の`delete_files`に`action: "enqueue"`、照会・取消は`action: "status"`・`"cancel"`と`jobId`を指定する。
- 元の削除許可とホストの承認・管理ポリシーを守る。この指示は新しい削除許可を与えない。

## レジストリ

明示的に許可されたキー・値の削除も、共通AGENTSに記録されたインストール済みexe・設定の絶対パスを使い、最初から`cmd.exe`・`login: false`で専用CLIを呼ぶ。ファイル削除の許可をレジストリへ広げない。対象キーは`--`の後へ1件だけ渡し、`--view 32`または`--view 64`を必ず指定する。

```text
<installed-exe> --config <absolute-config> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
<installed-exe> --config <absolute-config> registry-delete --view 64 --recursive -- HKCU:\Software\Example
<installed-exe> --config <absolute-config> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
<installed-exe> --config <absolute-config> registry-restore <operation-id>
```

exe・configは共通AGENTSのbindingへ置き換える。上のCMD例は空白・特殊文字のない引数を前提とする。キー・値名も含めCMDで安全に表現できないと実行前に分かる場合は、最初からMCPの`delete_registry`（`path`・`view`必須、任意`valueName`・`recursive`・`dryRun`）を選ぶ。`valueName`省略はキー、空文字は既定値である。CLIの`--value-name=`は空引数の欠落を避ける。値名は文字通り扱い、値削除と再帰指定は併用しない。成功の`operationId`を保存し、CLIの`registry-restore`（`restore`もレジストリ専用の別名）かMCPの`restore_registry`へ渡す。`operations`とMCPの`list_operations`もレジストリ専用である。

キーは未知の値型も含め型のuint値・生バイト列とOwner・Group・DACL・SACL（Mandatory Labelを含む）を保全する。完全ACL取得に必要な`SeSecurityPrivilege`がトークンにある場合だけ一時有効化し、不足時は削除前に停止する。自動昇格やKTM非対応時のfallbackはない。値の復元は親ACLを変更しない。既存キー・値・空の既定値を上書きせず、復元権限不足はロールバックして退避を保全する。キーのclassも保存するが、最終書込み時刻は復元せず、volatileキーも非volatileキーとして復元する。commit後の記録未確定は不明状態として保全し、自動整理・復元を拒否する。保持期間・容量はレジストリsnapshotを対象に既定7日・1 GiBであり、新規ファイルのゴミ箱項目は含まない。

ルート自体、HKCR/HKCC、リモート、相対指定、レジストリリンク、未知のschema・metadataや検証できない復元記録は拒否する。`Remove-Item`のレジストリ素通し例外はなく、認識した`Remove-ItemProperty`・`rp`・`reg[.exe] delete`も拒否し専用CLIを案内する。拒否された対象をMCPや別APIへ付け替えて再試行しない。

hookは限定した直接削除コマンドを検知して拒否する補助であり、shellを推測してコマンドを置換しない。外部スクリプト、動的コマンド、他言語のファイルAPIをすべて検出する保証はない。共通指示の読込みや将来すべての呼出しの遵守も、個別の実ホスト検証と区別する。

Codexのフック入力には`exec_command`の実行shellが渡らず、`shell: "pwsh"`だけではMac等に送るヒアストリング内の`rm`を区別できない。ローカルPowerShellスクリプト全体をshellを起動せずUTF-16LE Base64へ変換し、単独の`pwsh -NoProfile -EncodedCommand <base64>`で渡す。先頭にASCIIコメント行を置いてGit Bashのパス変換を避ける。Prunletはこの形式を復号して限定検査し、ローカルの直接削除・不正入力・解析不能な展開等は拒否する。Base64は秘密を隠さない。裸のヒアストリングやSSHの存在だけでは素通しせず、拒否された実削除を別形式へ付け替えて再送しない。具体例と検査範囲はリポジトリの連携手順を参照する。
