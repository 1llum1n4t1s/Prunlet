# Apple Silicon MacでPrunletを使う

## インストーラー（推奨）

`scripts/Install-Prunlet.sh` が、`https://prunlet.kagayoi.com` の署名付きマニフェストの検証、そこに記録された配布物の取得、サイズ・SHA-256の照合、Developer ID・公証の検証、`--install-macos` による配置までを1回で行います。マニフェストはスクリプトに組み込んだ公開鍵と `/usr/bin/openssl` で検証し、配布物はマニフェストが指す不変の取得先からリダイレクトを辿らずに取得します。GitHubのAPI・Release・認証は使いません。既定の導入先は `$HOME/.local/share/Prunlet` で、既に存在する場合は何も変更しません（更新はMCPの起動時自動更新が行います）。MCPホストの設定ファイルは書き換えず、登録に使う設定行だけを表示します。

```bash
curl -fsSL https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.sh -o /tmp/Install-Prunlet.sh &&
bash /tmp/Install-Prunlet.sh --dry-run &&
bash /tmp/Install-Prunlet.sh
```

`--dry-run` は、署名を検証したマニフェストの版・コミット・配布物・SHA-256と導入先を表示するだけです。`--tag vX.Y.Z` で版（その版のマニフェスト `manifests/<版>/osx-arm64.json` を使います）、`--install-dir <絶対パス>` で導入先を指定できます。`--repository` は互換のために受け付けますが、公式（`1llum1n4t1s/Prunlet`）以外はマニフェストと一致しないため導入しません。署名・製品・runtime・配布物名・取得先・版のどれかが一致しない場合は、理由（`signature-verification-failed` など）を表示して何も導入しません。初回は公証チケットの取得のため、検証が数秒かかることがあります。

## 手動で導入する

インストーラーを使わない場合も、配布物の取得先と期待値は署名付きマニフェストから決めます。R2には固定名のZIPを置いていません。上の `--dry-run` が署名を検証したうえで表示する `release`（版とコミット）と `sha256` を使い、不変の取得先から `prunlet-update-osx-arm64.zip` を取得して、表示された値と一致することを確認します。

```bash
curl -fsS --proto =https --max-redirs 0 -o prunlet-update-osx-arm64.zip \
  "https://prunlet.kagayoi.com/releases/1llum1n4t1s/prunlet/<コミット>/osx-arm64/<sha256>.zip" &&
shasum -a 256 prunlet-update-osx-arm64.zip
```

一致したZIPを専用フォルダーへ展開します。ZIP内の `prunlet` はDeveloper IDで署名し、Appleの公証を受けています。初回起動時の公証チケット確認にはネット接続が必要です。

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

MCPの登録済み入口が起動時に `https://prunlet.kagayoi.com/latest/osx-arm64.json` の署名付きマニフェストを取得し、実行ファイルに組み込んだ公開鍵で検証します。製品・リポジトリ・runtime・固定の配布物名と取得先が一致し、導入済みより版が大きい場合だけ、リダイレクトを辿らずに公開ZIPを取得し、長さ・SHA-256、同梱物、arm64実行形式、Developer IDと公証を照合します。CLI・MCP・削除待機workerが使用中なら更新を延期します。候補は同じディレクトリの新しいファイルへ書き、検証後に実行ファイルの名前を原子的に切り替えます。設定・復元領域・Codexの登録は保持します。GitHubの認証やトークンは使いません。

公開先に接続できない場合や、マニフェスト・候補の検証に失敗した場合は、何も変更せずに現行のMCPを起動し、理由を標準エラーへ出します。次回の起動で再確認します。

## 旧版からの再導入

配布元をR2の署名付きマニフェストへ移す前の版（GitHub Releaseで配布していた版）は、新しい配布元を参照しないため、起動時自動更新で新しい版を検知できません。現行のMCPを起動し続けるだけで壊れることはありませんが、自動では移行しないので、一度だけ手動で実行ファイルを入れ替えます。インストーラーは既存の導入先を変更しないため、別の新しい導入先へ導入し、その実行ファイルで旧導入先の実行ファイルを置き換えます。設定・復元領域・Codexの登録はそのまま使えます。

```bash
curl -fsSL https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.sh -o /tmp/Install-Prunlet.sh &&
bash /tmp/Install-Prunlet.sh --install-dir "$HOME/.local/share/Prunlet-reinstall"
```

Prunletを使うMCPホスト（Codexなど）を終了し、PrunletのCLI・MCPが動いていないことを確認してから、旧導入先の実行ファイルを置き換えます。

```bash
root="$HOME/.local/share/Prunlet"
install -m 700 "$HOME/.local/share/Prunlet-reinstall/bin/prunlet" "$root/bin/prunlet.new" &&
mv -f "$root/bin/prunlet.new" "$root/bin/prunlet" &&
"$root/bin/prunlet" --macos-build-info
```

表示された `version` と `commit` が、インストーラーの表示と一致することを確認します。一時的に作った導入先（`Prunlet-reinstall`）は、置換を確認した後に不要ならゴミ箱へ移せます。以後の更新はMCP起動時の自動更新が行います。

## リリースビルド

Apple Silicon実機で、公開するコミットのクリーンなソースから `bash scripts/Publish-PrunletMac.sh <外部の新規出力先> <40桁SHA>` を実行します。スクリプトにDeveloper IDの署名用キーチェーンと `notarytool` の認証プロファイルを環境変数で指定します。公証の `Accepted` と配布ZIPの版・コミット・SHA-256を確認し、同じ実物を `scripts/Send-PrunletMacPackage.ps1` でR2の不変キーへ新規作成のみで送ってから、`release/<版>` のrefで `prunlet-mac-release.yml` を実行して署名付きマニフェストを発行します。手順は[Apple Silicon版の公開手順](distribution.md#apple-silicon版の公開手順)、WindowsのZIPは[配布経路](distribution.md)を参照してください。
