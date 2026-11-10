# 更新ZIPの配布

## Windowsの更新ZIP

GitHub Releaseを発行者・タグ・コミット・digest・sizeの信頼の基点とし、同じ更新ZIPを既存のCloudflare R2にも配置する。現行クライアントはGitHubから取得し、公開済みの旧Windowsクライアントは従来のR2アドレスから取得する。schema 1と同梱12ファイルを共通に保つ。

## 既存の配信先

- bucket: `prunlet-updates`（repository variable `PRUNLET_R2_BUCKET`で既存の別bucketを指定可能）。
- 公開ホスト: `https://prunlet.kagayoi.com`。
- object key: `releases/<小文字のowner/repo>/<commit>/<runtime>/<ZIPの小文字SHA-256>.zip`。
- repository secrets: `PRUNLET_R2_ACCOUNT_ID`、`PRUNLET_R2_ACCESS_KEY_ID`、`PRUNLET_R2_SECRET_ACCESS_KEY`。対象bucketのobject読書きに限定し、値を引数・ソース・ログへ出さない。

## 公開の順序

送信前には、公開済みWindowsクライアントと同じZIP 512 MiB・実行ファイル各256 MiB・補助ファイル各4 MiBの上限、PE offset・machine、リンク属性の禁止、AuthenticodeがNotSignedまたはValidであることも照合する。

release workflowは公開タグからWindows x64・ARM64をビルドし、`Package-PrunletUpdate.ps1`で梱包する。`Verify-ReleasePackage.ps1`が同梱物・版・machine・metadata・hashを検証した後、`Publish-PrunletR2.ps1`で同じZIPを固定して既存R2へ送る。R2 SDK連携は`R2Distribution.Common.ps1`に置き、新規objectはcreate-onlyで送信し、既存objectは内容全体で照合する。結果不明の送信を自動再送しない。

R2の既存配信処理に含まれる内容照合が成功した後だけ、ZIP全体のhashを再確認し、同一ファイルをGitHub Releaseへ添付する。既存assetを上書きしない。bucket・DNS・資源の作成や削除は公開処理に含めない。

## Apple Silicon版の公開手順

`vava` のMac工程は `ssh mac` のApple Silicon実機で実行する。GitHubは公開ZIPの保管と配布に使う。

1. `ssh -o BatchMode=yes mac 'uname -sm; xcode-select -p'` で `Darwin arm64` とXcodeを確認する。非対話SSHから、`rust-toolchain.toml` のツールチェーンと `aarch64-apple-darwin` を使えるようにする。Mac上の外部作業ディレクトリに、`main` に含まれる固定済みリリースSHAのクリーンなチェックアウトと専用出力先を用意する。
2. [Macのリリースビルド](macos.md#リリースビルド)に従い、同じSSHセッションでDeveloper ID Applicationの署名鍵と `notarytool` のプロファイルを使う。資格情報が未配置なら、管理者の署名用正本から今回専用のキーチェーンを準備する。鍵やパスワードをソース・ログ・GitHubへ渡さず、一時キーチェーンと鍵の作業コピーは作業後に清掃する。
3. 公証の `Accepted` と `package.json` の版・SHA・`osx-arm64`・ZIPのサイズとSHA-256を確認する。Macから転送した同じ `prunlet-update-osx-arm64.zip` を添付直前に再度照合する。
4. 新規リリースでは固定SHAのタグに対応するGitHub Releaseの下書きへZIPを添付する。GitHubが返したasset名・サイズ・SHA-256が一致したら公開し、Windows版の既存配布workflowの結果を確認する。再開時は対象タグと既存assetの状態を確認し、一致済みのZIPを再ビルド・再送しない。不一致や結果不明のassetを上書きしない。

## Linux版の公開手順

`ssh mac` でApple Silicon実機に接続し、Limaの `linux-validation` に固定済みリリースSHAのクリーンなチェックアウトと新規の外部出力先を用意する。ゲストのUbuntu ARM64上で、`rust-toolchain.toml` が指定するRustと `aarch64-unknown-linux-gnu`・`x86_64-unknown-linux-gnu` を使う。x64のクロスリンクには `x86_64-linux-gnu-gcc` と対象のglibc開発環境を使う。

ゲスト内で `bash scripts/Publish-PrunletLinux.sh <新規の絶対出力先> <40桁SHA> linux-arm64` と、別出力先への `linux-x64` を実行する。生成するtar.gzには `prunlet` と、版・コミット・対象・実行体サイズ・SHA-256を記録した `manifest.json` を収録する。スクリプトがELFのアーキテクチャと梱包内容を照合し、配布実物のチェックサムを `.tar.gz.sha256` へ保存する。 `--preview` で生成したファイルは公開対象外とする。

転送後にチェックサムを再照合し、Mac版と同じGitHub Release下書きへ各アーカイブとチェックサムを添付する。GitHubが返したasset名・サイズ・SHA-256を確認してから公開する。

Linuxの起動時更新はこのtar.gzを直接使う。対象assetは `prunlet-linux-arm64.tar.gz`・`prunlet-linux-x64.tar.gz` とし、GNU tarのustar形式で `prunlet`、`manifest.json` の順に収録する。展開前と実行ファイルの上限は各64 MiB。起動側はGitHub APIのasset SHA-256とサイズを照合し、ローカルのチェックサムファイルは手動取得時に使う。
