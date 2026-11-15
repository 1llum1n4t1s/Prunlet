# Linuxのインストールと使い方

Linux x64・ARM64のCLI、stdio MCP、Codexフックを提供します。ビルド・検証環境はUbuntu 24.04です。実行には対応CPU、glibc 2.39互換環境、`statx` のマウントIDと `renameat2(RENAME_NOREPLACE)` に対応するLinuxとファイルシステム、および `/proc` が必要です。

## 初回インストール

配布物と署名付きマニフェストは `https://prunlet.kagayoi.com` から取得します。GitHubのアカウント・認証は不要です。次の手順は、最新版の署名付きマニフェスト（`latest/linux-<CPU>.json`）を固定の公開鍵で検証し、そこに記録された不変の取得先から配布物を取得して、長さとSHA-256を照合します。公開鍵は、`main` ブランチの `scripts/Install-Prunlet.sh` にある `PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64` の値です（起動時自動更新が使う鍵と同じです）。`cpu` はx64なら `x64`、ARM64なら `arm64` にします。`curl`・`openssl`・`sha256sum` を使います。

```bash
cpu=x64
base=https://prunlet.kagayoi.com
work="$(mktemp -d)" && cd "$work" &&
curl -fsS --proto =https --max-redirs 0 -o manifest.json "$base/latest/linux-$cpu.json" &&
curl -fsS --proto =https -o Install-Prunlet.sh https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.sh &&
key="$(sed -n "s/^PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64='\([A-Za-z0-9+/=]*\)'\$/\1/p" Install-Prunlet.sh)" &&
{ echo '-----BEGIN PUBLIC KEY-----'; printf '%s' "$key" | fold -w 64; printf '\n-----END PUBLIC KEY-----\n'; } >release-public.pem &&
sed -E 's/^.*"payload":"([^"]*)".*$/\1/' manifest.json | base64 -d >payload.json &&
sed -E 's/^.*"signature":"([^"]*)".*$/\1/' manifest.json | base64 -d >signature.der &&
openssl dgst -sha256 -verify release-public.pem -signature signature.der payload.json &&
commit="$(sed -E 's/^.*"commit":"([0-9a-f]{40})".*$/\1/' payload.json)" &&
sha="$(sed -E 's/^.*"sha256":"([0-9a-f]{64})".*$/\1/' payload.json)" &&
grep -q "\"product\":\"Prunlet\",\"repository\":\"1llum1n4t1s/Prunlet\",\"runtime\":\"linux-$cpu\"" payload.json &&
grep -q "\"key\":\"releases/1llum1n4t1s/prunlet/$commit/linux-$cpu/$sha.tar.gz\"" payload.json &&
curl -fsS --proto =https --max-redirs 0 -o "prunlet-linux-$cpu.tar.gz" "$base/releases/1llum1n4t1s/prunlet/$commit/linux-$cpu/$sha.tar.gz" &&
echo "$sha  prunlet-linux-$cpu.tar.gz" | sha256sum -c - &&
tar -xzf "prunlet-linux-$cpu.tar.gz" prunlet &&
cat payload.json
```

`openssl` が `Verified OK` を表示し、どのコマンドも失敗しなかった場合だけ続けます。表示されたpayloadの `version` と `commit` が導入する版です。署名・製品・CPU・取得先のどれかが一致しない場合は、取得した物を使わずに停止します。

署名を検証しない簡易な取得先として、固定名の `https://prunlet.kagayoi.com/download/latest/prunlet-linux-<x64|arm64>.tar.gz` と、同名の `.sha256` ファイルも置いています。`sha256sum -c` による照合は転送の破損を確かめるだけで、発行元の確認にはなりません。公開の途中は、固定名の更新が最新のマニフェストより遅れることがあります。

展開した `prunlet` のあるディレクトリで次を実行します。

```bash
root="$HOME/.local/share/Prunlet"
mkdir -p "$HOME/.local/share" &&
mkdir -m 700 "$root" &&
mkdir -m 700 "$root/bin" "$root/recovery" &&
install -m 700 ./prunlet "$root/bin/prunlet" &&
"$root/bin/prunlet" --config "$root/config.json" init --backup-directory "$root/recovery"
```

Codexの `config.toml` へ以下を登録します。`/home/you` は自分のホームの絶対パスに置き換えます。

```toml
[mcp_servers.prunlet]
command = "/home/you/.local/share/Prunlet/bin/prunlet"
args = ["--config", "/home/you/.local/share/Prunlet/config.json", "mcp"]
startup_timeout_sec = 90
```

CLIも同じ実行体と設定を使います。フックの引数は `--config <設定の絶対パス> hook` です。

```bash
"$root/bin/prunlet" --config "$root/config.json" delete --dry-run -- "$HOME/example.txt"
```

## 削除と復元

同じマウントの項目を `$XDG_DATA_HOME/Trash`（既定 `$HOME/.local/share/Trash`）へ移動します。復元はfreedesktop Trashに対応するファイルマネージャーで行います。内容のあるディレクトリには `--recursive` またはMCPの `recursive: true` が必要です。リンクはリンク自身を移し、祖先のシンボリックリンクと別マウントは拒否します。 `ambiguous` の場合は元のパスとゴミ箱を確認してください。

LinuxのMCPは同期の `delete_files` を提供します。

## MCP起動時の自動更新

公式配布版は、上記の非公開ディレクトリ構成でMCPを起動すると、`/usr/bin/curl` で `https://prunlet.kagayoi.com/latest/linux-<CPU>.json` の署名付きマニフェストを取得し、実行ファイルに組み込んだ公開鍵で署名を検証します。製品・リポジトリ・CPU・固定の配布物名と取得先が一致し、導入済みより版が大きい場合だけ、リダイレクトを辿らずに配布物を取得します。長さとSHA-256、tar.gzの同梱物、manifest、ELFのCPUを検査し、実行ファイルだけを原子的に差し替えます。GitHubの認証やトークンは使いません。

別のPrunletが同じ配置を使用中の場合、通信エラーの場合、またはマニフェストや候補を確認できない場合は、何も変更せずに現行版のMCPを起動し、次回の起動で再確認します。設定・復元領域・Codexの登録は保持されます。配布の流れは[Linux版の公開手順](distribution.md#linux版の公開手順)を参照してください。

## 旧版からの再導入

配布元をR2の署名付きマニフェストへ移す前の版（GitHub Releaseで配布していた版）と旧プレビュー版は、新しい配布元を参照しないため、起動時自動更新で新しい版を検知できません。現行版のMCPを起動し続けるだけで壊れることはありませんが、自動では移行しないので、一度だけ手動で実行ファイルを入れ替えます。設定・復元領域・Codexの登録はそのまま使えます。

1. [初回インストール](#初回インストール)の検証手順で、新しい `prunlet` を取得・展開します。導入先の作成と `init` は行いません。
2. Prunletを使うMCPホスト（Codexなど）を終了し、PrunletのCLI・MCPが動いていないことを確認します。
3. 展開した `prunlet` のあるディレクトリで、導入先の実行ファイルを置き換えます。

```bash
root="$HOME/.local/share/Prunlet"
install -m 700 ./prunlet "$root/bin/prunlet.new" &&
mv -f "$root/bin/prunlet.new" "$root/bin/prunlet" &&
"$root/bin/prunlet" --linux-build-info
```

表示された `version` と `commit` が、検証したpayloadの値と一致することを確認します。以後の更新はMCP起動時の自動更新が行います。
