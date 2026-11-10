# Linuxのインストールと使い方

Linux x64・ARM64のCLI、stdio MCP、Codexフックを提供します。ビルド・検証環境はUbuntu 24.04です。実行には対応CPU、glibc 2.39互換環境、`statx` のマウントIDと `renameat2(RENAME_NOREPLACE)` に対応するLinuxとファイルシステム、および `/proc` が必要です。

## 初回インストール

対応するLinux用tar.gzとチェックサムを取得し、`sha256sum -c <ファイル名>.sha256` で照合して専用ディレクトリへ展開します。そこから次を実行します。

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

公式配布版は、上記の非公開ディレクトリ構成でMCPを起動すると、`/usr/bin/curl` でGitHub Releaseの安定版を確認します。導入コミットの子孫で `main` に含まれる、より新しい同じCPU向けの配布物が対象です。公開assetのサイズとSHA-256、tar.gzの同梱物、manifest、ELFのCPUを検査し、実行ファイルだけを原子的に差し替えます。

別のPrunletが同じ配置を使用中の場合、通信エラーの場合、または候補を確認できない場合は現行版のMCPを起動します。設定・復元領域・Codexの登録は保持されます。旧プレビュー版から利用を始めるときは、MCPを閉じ、最初の公式Linux版の実行ファイルを手動で配置してください。[Linux版のビルドと配布](distribution.md#linux版の公開手順)を参照してください。
