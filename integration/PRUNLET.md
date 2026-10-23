<!-- Prunlet managed agent instructions -->
# Prunlet — Windowsのファイル・フォルダー・レジストリ削除

許可されたWindowsファイル・フォルダー削除には、最初からPrunlet CLIを使う。共通AGENTS.mdに「Prunlet CLI」として記録した、インストール済みexeと設定の絶対パスを使い、shellは `cmd.exe`、loginは `false` とする。PowerShellのラッパー、PATH上の同名exe、開発クローンやローカルビルドへの差替えは使わない。

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

上のプレースホルダーは共通AGENTSに記録したパスと今回作成した実パスへ置き換える。CMDのtool callでは、たとえば `tools.exec_command({cmd: "<installed-exe> --config <absolute-config> delete --paths-file <absolute-json-file>", shell: "cmd.exe", login: false})` として直接渡す。`-- <literal-path>...`もCLIでは対応するが、CMDの引用が必要な対象には配列ファイルを使う。

- 通常ファイルのMSIX転送・8.3短縮名・slash表記・拡張長のローカルドライブ表記に対応する。入力の実体を検証し、結果の`path`と新しい復元記録は実体パスを示す。
- 範囲確認が必要なら、削除前に`--dry-run`で確認する。CLIのJSON結果と終了コードを読み、各対象の成功・失敗を判定する。
- 成功時の`operationId`を保持し、復元は同じexeと設定の`restore`へ渡す。既存の復元先を上書きしない。復元データは既定で7日・合計10 GiBまで保持し、期限切れと容量確保時は古い操作から自動整理する。整理済みの操作は復元できない。
- 削除対象フォルダーの事前登録・追加許可は不要。ユーザーが依頼した削除対象、または現在の作業で清掃が許可された一時ファイルを、保存場所を理由に追加確認せず処理する。
- 空フォルダーは通常の`delete`、内容がある作業フォルダーは`delete --recursive`でフォルダー自体まで清掃する。MCPでは`recursive: true`を指定する。空の子フォルダーを含むツリーを同じoperationIdで元へ戻せる。
- 新規削除は事前にツリー全体を検査・容量走査し、同じボリュームのPrunlet専用領域へ対象をrenameする。フォルダーはルートごと移動し、コピー後の削除や異ボリュームへのfallbackは行わない。ADS・ACL・通常属性・case-sensitive属性は同じ実体のまま保持する。シンボリックリンク・ジャンクションはリンク自体を扱い、リンク先を辿らない。ハードリンクの外部別名は実体を共有するため、別名からの書込みは保管内容にも反映される。未知のreparseタグ・ADS付きリンク・ワイルドカードは未対応。中央metadataとボリューム別専用領域は通常削除から保護する。復元は非上書きrenameで、既存フォルダーへもマージせず、成功後は退避実体を消費する。再実行は整合する記録に限り`already_restored`となる。旧schema 1/2/3の復元・整理は互換経路で保持する。
- 全体の整理は`maintain [--apply]`、特定操作は`purge <operationId> [--apply]`を使い、省略時は検査のみ。削除前に新旧復元データの合計を走査し、整理前後に予算を検証する。単独操作の入力合計が上限を超える場合だけ既存データを0まで安全に整理して今回のサイズを予算とし、次回の削除・maintainで通常上限を再適用する。容量が不明・不足なら元対象を残して停止する。専用領域を手動削除しない。
- インストール済みexeや設定そのものに空白・CMDの特殊文字を含む配置など、CLIの引数を正しく渡せないと実行前に分かる場合は、互換クライアント向けPrunlet MCPを最初から明示選択するか、必要な配置・入力を確認する。削除を試して拒否された後にMCPへ切り替えない。
- ホスト・Prunlet・管理ポリシーに拒否された対象は、shell、MCP、別API、別exeで再試行しない。拒否理由と必要な判断を報告する。
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

キーは未知の値型も含め型のuint値・生バイト列とOwner・Group・DACL・SACL（Mandatory Labelを含む）を保全する。完全ACL取得に必要な`SeSecurityPrivilege`がトークンにある場合だけ一時有効化し、不足時は削除前に停止する。自動昇格やKTM非対応時のfallbackはない。値の復元は親ACLを変更しない。既存キー・値・空の既定値を上書きせず、復元権限不足はロールバックして退避を保全する。キーのclassも保存するが、最終書込み時刻は復元せず、volatileキーも非volatileキーとして復元する。commit後の記録未確定は不明状態として保全し、自動整理・復元を拒否する。保持期間・容量はファイルと合計で既定7日・10 GiBである。

ルート自体、HKCR/HKCC、リモート、相対指定、レジストリリンク、未知のschema・metadataや検証できない復元記録は拒否する。`Remove-Item`のレジストリ素通し例外はなく、認識した`Remove-ItemProperty`・`rp`・`reg[.exe] delete`も拒否し専用CLIを案内する。拒否された対象をMCPや別APIへ付け替えて再試行しない。

hookは限定した直接削除コマンドを検知して拒否する補助であり、shellを推測してコマンドを置換しない。外部スクリプト、動的コマンド、他言語のファイルAPIをすべて検出する保証はない。共通指示の読込みや将来すべての呼出しの遵守も、個別の実ホスト検証と区別する。
