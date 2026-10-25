<!-- Prunlet managed agent instructions -->
# Prunlet — Windowsのファイル・フォルダー・レジストリ削除

許可されたWindowsファイル・フォルダー削除には、最初からPrunlet CLIを使う。共通AGENTS.mdに「Prunlet CLI」として記録した、インストール済みexeと設定の絶対パスを使い、shellは `cmd.exe`、loginは `false` とする。PowerShellのラッパー、PATH上の同名exe、開発クローンやローカルビルドへの差替えは使わない。

`exec_command`が正式なsandbox権限要求に対応するホストでは、ファイル・フォルダーの実削除と復元を、初回から `sandbox_permissions: "require_escalated"` を指定して要求する。Windowsのゴミ箱への移動・復元には対象だけでなくゴミ箱へのアクセスも必要で、通常sandboxでは対象への権限があってもゴミ箱への書込みが拒否される場合がある。これはホストの承認・審査を受けるための要求であり、WindowsのUAC昇格や管理者実行ではない。Prunletによる自動昇格や承認・管理ポリシーの上書きは行わない。対応しないホストでは、そのホストが提供する正式な承認経路に従い、権限を指定できない場合は必要な判断を報告する。

Codexの通常経路は、対象の絶対パスをそのままの文字列をUTF-8 JSON配列へ保存し、`--paths-file`で渡す。配列ファイルは作業契約で定めた外部Tempへ置き、exe・config・配列ファイルのCMD引数は空白・CMDの特殊文字を含まない絶対パスにする。ファイル名の空白・Unicode・長いパス・複数対象はJSON配列の内容で保持し、shellへ展開しない。

```json
["C:\\work\\a file.txt", "C:\\work\\b.txt"]
```

```text
<installed-exe> --config <absolute-config> delete --paths-file <absolute-json-file>
<installed-exe> --config <absolute-config> delete --dry-run --paths-file <absolute-json-file>
<installed-exe> --config <absolute-config> delete --recursive --paths-file <absolute-json-file>
<installed-exe> --config <absolute-config> restore <operation-id>
```

上のプレースホルダーは共通AGENTSに記録したパスと今回作成した実パスへ置き換える。CMDのtool callでは、たとえば `tools.exec_command({cmd: "<installed-exe> --config <absolute-config> delete --paths-file <absolute-json-file>", shell: "cmd.exe", login: false, sandbox_permissions: "require_escalated", justification: "許可された対象をWindowsのゴミ箱へ移すため、正式なsandbox権限を要求します。"})` として直接渡す。復元も同じ指定で `cmd` を `<installed-exe> --config <absolute-config> restore <operation-id>` にする。`-- <literal-path>...`もCLIでは対応するが、CMDの引用が必要な対象には配列ファイルを使う。

- 通常ファイルのMSIX転送・8.3短縮名・slash表記・拡張長のローカルドライブ表記に対応する。入力の実体を検証し、結果の`path`と新しい復元記録は実体パスを示す。
- 範囲確認が必要なら、削除前に`--dry-run`で確認する。dry-runは通常sandboxでも行えるが、ゴミ箱への実移動や復元は行わず、成功しても実処理に必要な権限を保証しない。CLIのJSON結果と終了コードを読み、各対象の成功・失敗を判定する。
- 成功時の`operationId`を保持し、同じexe・設定の`restore`へ渡す。新しいファイル実体はWindowsのゴミ箱が管理し、Windows側で完全削除された項目は復元できない。既存の復元先を上書き・マージしない。
- 削除対象フォルダーの事前登録・追加許可は不要。ユーザーが依頼した削除対象、または現在の作業で清掃が許可された一時ファイルを、保存場所を理由に追加確認せず処理する。
- 空フォルダーは通常の`delete`、内容がある作業フォルダーは`delete --recursive`でフォルダー自体まで清掃する。MCPでは`recursive: true`を指定する。空の子フォルダーを含むツリーを同じoperationIdで元へ戻せる。
- 新規ファイル・フォルダーはschema 6でWindowsのゴミ箱へ移す。Prunletは操作ID・PIDL・File IDを保持してCLI・MCPの非上書き復元へ結び付ける。永久削除や独自領域へのfallbackは行わず、リンク先を辿らない。ハードリンクの別名とは実体を共有する。既存schema 1〜4の退避データも同じCLI・MCPから復元できる。
- `maintain [--apply]`・`purge <operationId> [--apply]`は旧schema 1〜4とレジストリsnapshotだけを整理する。省略時は検査のみ。schema 6はWindowsの保持・清掃に任せ、Prunletの容量・期限の対象にしない。ゴミ箱全体を空にしたり旧専用領域を手動削除したりしない。
- インストール済みexeや設定そのものに空白・CMDの特殊文字を含む配置など、CLIの引数を正しく渡せないと実行前に分かる場合は、互換クライアント向けPrunlet MCPを最初から明示選択するか、必要な配置・入力を確認する。削除を試して拒否された後にMCPへ切り替えない。
- ホスト・Prunlet・管理ポリシーに拒否された対象は、shell、MCP、別API、別exeで再試行しない。拒否理由と必要な判断を報告する。
- 権限不足の失敗を検知しても、同じ削除を自動再送しない。結果が不明な場合は、元対象・CLIのJSON・`operationId`・`list`の復元記録を確認して状態を照合し、確認できない状態は保全して必要な判断を報告する。正式な権限要求も、拒否された削除を迂回する手段にはしない。
- 元の削除許可とホストの承認・管理ポリシーを守る。この指示は新しい削除許可を与えない。

## レジストリ

明示的に許可されたキー・値の削除も、共通AGENTSに記録されたインストール済みexe・設定の絶対パスを使い、最初から`cmd.exe`・`login: false`で専用CLIを呼ぶ。ファイル削除の許可をレジストリへ広げない。対象キーは`--`の後へ1件だけ渡し、`--view 32`または`--view 64`を必ず指定する。

```text
<installed-exe> --config <absolute-config> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
<installed-exe> --config <absolute-config> registry-delete --view 64 --recursive -- HKCU:\Software\Example
<installed-exe> --config <absolute-config> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
<installed-exe> --config <absolute-config> restore <operation-id>
```

exe・configは共通AGENTSのbindingへ置き換える。上のCMD例は空白・特殊文字のない引数を前提とする。キー・値名も含めCMDで安全に表現できないと実行前に分かる場合は、最初からMCPの`delete_registry`（`path`・`view`必須、任意`valueName`・`recursive`・`dryRun`）を選ぶ。`valueName`省略はキー、空文字は既定値である。CLIの`--value-name=`は空引数の欠落を避ける。値名は文字通り扱い、値削除と再帰指定は併用しない。成功の`operationId`を保存し、CLIの共通`restore`かMCPの`restore_registry`へ渡す。MCPの`restore_files`はファイル用である。

キーは未知の値型も含め型のuint値・生バイト列とOwner・Group・DACL・SACL（Mandatory Labelを含む）を保全する。完全ACL取得に必要な`SeSecurityPrivilege`がトークンにある場合だけ一時有効化し、不足時は削除前に停止する。自動昇格やKTM非対応時のfallbackはない。値の復元は親ACLを変更しない。既存キー・値・空の既定値を上書きせず、復元権限不足はロールバックして退避を保全する。キーのclassも保存するが、最終書込み時刻は復元せず、volatileキーも非volatileキーとして復元する。commit後の記録未確定は不明状態として保全し、自動整理・復元を拒否する。保持期間・容量は旧schema 1〜4と合計で既定7日・1 GiBであり、新規ファイルのゴミ箱項目は含まない。

ルート自体、HKCR/HKCC、リモート、相対指定、レジストリリンク、未知のschema・metadataや検証できない復元記録は拒否する。`Remove-Item`のレジストリ素通し例外はなく、認識した`Remove-ItemProperty`・`rp`・`reg[.exe] delete`も拒否し専用CLIを案内する。拒否された対象をMCPや別APIへ付け替えて再試行しない。

hookは限定した直接削除コマンドを検知して拒否する補助であり、shellを推測してコマンドを置換しない。外部スクリプト、動的コマンド、他言語のファイルAPIをすべて検出する保証はない。共通指示の読込みや将来すべての呼出しの遵守も、個別の実ホスト検証と区別する。
