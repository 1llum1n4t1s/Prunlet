# Apple Silicon MacでPrunletを使う

[GitHub Releases](https://github.com/1llum1n4t1s/Prunlet/releases/latest)の `prunlet-update-osx-arm64.zip` を取得し、専用フォルダーへ展開します。ZIP内の `prunlet` はDeveloper IDで署名し、Appleの公証を受けています。初回起動時の公証チケット確認にはネット接続が必要です。

```bash
cd /absolute/path/to/extracted &&
/usr/bin/codesign --verify --strict \
  -R '=anchor apple generic and identifier "com.kagayoi.prunlet" and certificate leaf[subject.OU] = "SL228Y8UUR" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and notarized' \
  ./prunlet &&
mkdir -p "$HOME/.local/share" &&
./prunlet --install-macos "$HOME/.local/share/Prunlet"
```

インストーラーは新規ディレクトリを作成します。旧Mac版の配置がある場合は、別の導入先を指定し、旧設定の原本を保管してください。

Codexの `config.toml` に次のMCP設定を登録します。`/Users/you` は自分のホームの絶対パスに置き換えてください。同名の登録がすでにある場合は、その登録を更新します。

```toml
[mcp_servers.prunlet]
command = "/Users/you/.local/share/Prunlet/bin/prunlet"
args = ["--config", "/Users/you/.local/share/Prunlet/config.json", "mcp"]
startup_timeout_sec = 90
```

CLIは同じ実行ファイルと設定の絶対パスを使います。例えば、所有する検証ファイルのdry-runは次のとおりです。

```bash
"$HOME/.local/share/Prunlet/bin/prunlet" --config "$HOME/.local/share/Prunlet/config.json" \
  delete --dry-run -- "$HOME/prunlet-fixture/example.txt"
```

MCPは `delete_files` を提供します。リンク先には辿らず、macOSのゴミ箱に移せた結果だけを成功とします。結果が `ambiguous` の場合は元のパスとゴミ箱を確認してください。明示的な削除待機キューは協調的な `flock` を待機対象とします。レジストリ操作はWindows専用です。フックの実行引数は `--config <設定の絶対パス> hook` です。

## 起動時自動更新

MCPの登録済み入口が起動時にGitHubの安定版を確認します。導入コミットから前進し `main` に含まれる新しい版に対し、公開ZIPの長さ・SHA-256、同梱物、arm64実行形式、Developer IDと公証を照合します。CLI・MCP・削除待機workerが使用中なら更新を延期します。候補は同じディレクトリの新しいファイルへ書き、検証後に実行ファイルの名前を原子的に切り替えます。設定・復元領域・Codexの登録は保持します。

公開先に接続できない場合や候補の検証に失敗した場合は現行のMCPを起動し、理由を標準エラーへ出します。

## リリースビルド

Apple Silicon実機で、公開するコミットのクリーンなソースから `bash scripts/Publish-PrunletMac.sh <外部の新規出力先> <40桁SHA>` を実行します。スクリプトにDeveloper IDの署名用キーチェーンと `notarytool` の認証プロファイルを環境変数で指定します。公証の `Accepted` と配布ZIPの版・コミット・SHA-256を確認し、同じ実物をGitHub Releaseに添付します。WindowsのZIPは既存の[配布経路](distribution.md)を使用します。
