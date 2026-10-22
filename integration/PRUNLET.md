<!-- Prunlet managed agent instructions -->
# Prunlet — Windowsのファイル・フォルダー削除

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
- 成功時の`operationId`を保持し、復元は同じexeと設定の`restore`へ渡す。既存の復元先を上書きしない。コピーは既定で7日・合計10 GiBまで保持し、期限切れと容量確保時は古い操作から自動整理する。整理済みの操作は復元できない。
- 削除対象フォルダーの事前登録・追加許可は不要。ユーザーが依頼した削除対象、または現在の作業で清掃が許可された一時ファイルを、保存場所を理由に追加確認せず処理する。
- 空フォルダーは通常の`delete`、内容がある作業フォルダーは`delete --recursive`でフォルダー自体まで清掃する。MCPでは`recursive: true`を指定する。空の子フォルダーも記録され、同じoperationIdで階層を復元できる。
- 再帰削除は列挙した全ファイルの検証済みコピーとフォルダー記録を保存してから始める。シンボリックリンク・ジャンクションはリンク自体を保存・削除し、リンク先は辿らない。ファイル・フォルダーのADSとcase-sensitive属性も復元する。ハードリンクは指定した名前だけを削除し、復元は保存時点の独立コピーとする。未知のreparseタグ・ADS付きリンク・ワイルドカードは未対応。復元データ保存先内とその保存先を包含するフォルダーは通常削除から保護する。コピー全体の整理は`maintain [--apply]`、特定操作の明示整理は`purge <operationId> [--apply]`を使う。どちらも省略時は検査のみ。単独で容量上限を超える削除は、既存コピーを安全に整理し、今回の見積りサイズまで一時的な超過を許可して復元コピーを確保する。このコピーは次の削除やmaintainで通常の上限に従って整理される。安全に容量を確保できない削除は元のファイルを残して停止する。
- インストール済みexeや設定そのものに空白・CMDの特殊文字を含む配置など、CLIの引数を正しく渡せないと実行前に分かる場合は、互換クライアント向けPrunlet MCPを最初から明示選択するか、必要な配置・入力を確認する。削除を試して拒否された後にMCPへ切り替えない。
- ホスト・Prunlet・管理ポリシーに拒否された対象は、shell、MCP、別API、別exeで再試行しない。拒否理由と必要な判断を報告する。
- 元の削除許可とホストの承認・管理ポリシーを守る。この指示は新しい削除許可を与えない。

hookは限定した直接削除コマンドを検知して拒否する補助であり、shellを推測してコマンドを置換しない。外部スクリプト、動的コマンド、他言語のファイルAPIをすべて検出する保証はない。共通指示の読込みや将来すべての呼出しの遵守も、個別の実ホスト検証と区別する。
