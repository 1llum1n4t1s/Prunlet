# 更新ZIPの配布

## Windowsの更新ZIP

GitHub Releaseを発行者・タグ・コミット・digest・sizeの信頼の基点とし、同じ更新ZIPを既存のCloudflare R2にも配置する。現行クライアントはGitHubから取得し、公開済みの旧Windowsクライアントは従来のR2アドレスから取得する。schema 1と同梱12ファイルを共通に保つ。

## 既存の配信先

- bucket: `prunlet-updates`（repository variable `PRUNLET_R2_BUCKET`で既存の別bucketを指定可能）。
- 公開ホスト: `https://prunlet.kagayoi.com`。
- object key: `releases/<小文字のowner/repo>/<commit>/<runtime>/<ZIPの小文字SHA-256>.zip`。
- repository secrets: `PRUNLET_R2_ACCOUNT_ID`、`PRUNLET_R2_ACCESS_KEY_ID`、`PRUNLET_R2_SECRET_ACCESS_KEY`。対象bucketのobject読書きに限定し、値を引数・ソース・ログへ出さない。

## 署名

`prunlet.exe`・`prunlet-maintenance.exe`・`prunlet-hook.exe`はCertumのコード署名証明書でAuthenticode署名し、RFC 3161タイムスタンプを付ける。署名はrelease workflowで[Sigilune](https://github.com/1llum1n4t1s/Sigilune)を使い、SimplySignのクラウド鍵へ直接接続して行う（SimplySign Desktop・手入力のワンタイムコードは不要）。hookはCLIと同一hashである必要があるので、CLIを署名してからhookへ複製する。同梱の`.ps1`・`PRUNLET.md`はsourceと同一bytesで照合するため署名しない。`Install-Prunlet.ps1`による手動導入もソースをビルドせず、このreleaseに添付された署名済み更新ZIPを起動時更新と同じ条件で照合して配置する。未署名・署名者違い・タイムスタンプなしの実行ファイルは配置しない。そのため、release公開から配布workflowの承認・添付が終わるまでの間は手動導入が「assetがまだない」として停止する。

- 署名用のSecrets `SIGILUNE_EMAIL`・`SIGILUNE_TOTP_URI` は、Environment `release`（承認者なし。`main`・`v*`タグだけ許可）にだけ置く。workflowは署名stepだけへ渡し、Rustのビルド（依存crateのbuild scriptを含む）には渡さない。
- 別マシンの並列jobが同じTOTP時間枠を使うとCertumが後者を拒否するため、win-x64・win-arm64を1つのjobで扱い、同じSigiluneセッションで署名してログインを1回にする。v1.0.0公開前のSigiluneで1回の呼出しに複数ファイルを渡すと、signtoolの異常終了やdlibのpanicが観測されたため、1ファイルずつ呼び出す。失敗時に自動再試行しない。
- 署名・検証の処理は`scripts/Signing.Common.ps1`と`scripts/Sign-PrunletBuild.ps1`に集約する。署名後はSigiluneの検証に加えて、Windowsの判定が`Valid`であること、署名者の共通名、タイムスタンプの存在を独立に確認する。タイムスタンプがないと証明書の期限切れ後に`Valid`でなくなり、公開済みクライアント（NotSigned・Valid以外を拒否する）が更新を受け付けなくなる。

## 公開の順序

送信前には、公開済みWindowsクライアントと同じZIP 512 MiB・実行ファイル各256 MiB・補助ファイル各4 MiBの上限、PE offset・machine、リンク属性の禁止、Authenticodeが署名者・タイムスタンプ付きのValidであることも照合する。

release公開をきっかけに、release workflowが1つのjobで次を行う。jobは承認待ちなしで始まる（Environment `release`は承認者なし・ブランチ制限だけ）。

1. 公開タグのcommitが既定ブランチ上にあることを確認し、win-x64・win-arm64を`Publish-Prunlet.ps1`でビルドして版を照合する。
2. Sigiluneを導入し、`Sign-PrunletBuild.ps1`で両runtimeの実行ファイルを署名する。署名後のhashと署名者・署名前hashを`build-manifest.json`へ記録する。
3. `Package-PrunletUpdate.ps1`で梱包し、`Verify-ReleasePackage.ps1 -RequireSignature`が同梱物・版・machine・metadata・hashと署名を検証する。
4. `Publish-PrunletR2.ps1`が署名を含めて再検証し、同じZIPを固定して既存R2へ送る。R2 SDK連携は`R2Distribution.Common.ps1`に置き、新規objectはcreate-onlyで送信し、既存objectは内容全体で照合する。結果不明の送信を自動再送しない。
5. R2の内容照合が成功した後だけ、ZIP全体のhashを再確認し、同一ファイルをGitHub Releaseへ添付する。既存assetを上書きしない。

bucket・DNS・資源の作成や削除は公開処理に含めない。

## Apple Silicon版の公開手順

`vava` のMac工程は `ssh mac` のApple Silicon実機で実行する。GitHubは公開ZIPの保管と配布に使う。

1. `ssh -o BatchMode=yes mac 'uname -sm; xcode-select -p'` で `Darwin arm64` とXcodeを確認する。非対話SSHから、`rust-toolchain.toml` のツールチェーンと `aarch64-apple-darwin` を使えるようにする。Mac上の外部作業ディレクトリに、`main` に含まれる固定済みリリースSHAのクリーンなチェックアウトと専用出力先を用意する。
2. [Macのリリースビルド](macos.md#リリースビルド)に従い、同じSSHセッションでDeveloper ID Applicationの署名鍵と `notarytool` のプロファイルを使う。資格情報が未配置なら、管理者の署名用正本から今回専用のキーチェーンを準備する。鍵やパスワードをソース・ログ・GitHubへ渡さず、一時キーチェーンと鍵の作業コピーは作業後に清掃する。
3. 公証の `Accepted` と `package.json` の版・SHA・`osx-arm64`・ZIPのサイズとSHA-256を確認する。Macから転送した同じ `prunlet-update-osx-arm64.zip` を添付直前に再度照合する。
4. 新規リリースでは固定SHAのタグに対応するGitHub Releaseの下書きへZIPを添付する。GitHubが返したasset名・サイズ・SHA-256が一致したら公開する。公開後にWindows版の配布workflowが承認待ちなしで動くので、署名・R2配置・添付の結果を確認する。再開時は対象タグと既存assetの状態を確認し、一致済みのZIPを再ビルド・再送しない。不一致や結果不明のassetを上書きしない。

## Linux版の公開手順

Linux版は、Releaseの公開（`published`）で `.github/workflows/prunlet-linux-release.yml` が自動で動く。手作業での添付はしない。公開タグを固定済みリリースSHAとしてクリーンにチェックアウトし、既定ブランチ上のコミットであることを確認してから、x64は `ubuntu-24.04`、ARM64は `ubuntu-24.04-arm` の各ランナー（`ubuntu-latest` はglibc要件が `docs/linux.md` の2.39を超える版へ移ったため使わない）で次を行う。

1. `rust-toolchain.toml` が指定するRustで `cargo test --locked --lib` と `cargo test --locked --test localization` を実行する。
2. `bash scripts/Publish-PrunletLinux.sh <新規の絶対出力先> <40桁SHA> <linux-x64|linux-arm64>` でビルドする。生成するtar.gzには `prunlet` と、版・コミット・対象・実行体サイズ・SHA-256を記録した `manifest.json` を収録する。スクリプトがELFのアーキテクチャと梱包内容を照合し、配布実物のチェックサムを `.tar.gz.sha256` へ保存する。
3. 成果物から、tarの内容・manifest・上限・チェックサムを再確認し、実行体が要求するglibcのシンボル版が2.39以下であることを確認する。
4. 配布tar.gzから取り出した実行体で `scripts/Verify-LinuxFiles.ts` を、版とコミットが異なる3世代のデバッグビルド（`prunlet_linux_update_tests`）で `scripts/Verify-UnixStartupUpdate.ts` を実行する。
5. 両CPUの検証が成功した場合だけ、同じGitHub Releaseへ各アーカイブとチェックサムを添付する。既存のassetは上書きせず、同一内容なら再利用し、異なれば失敗する。GitHubが返したasset名・サイズ・SHA-256を手元の実物と照合する。

過去タグへの後付けと、添付しない検証は `workflow_dispatch` で行う。`tag` に対象のタグ（例 `v1.0.47`）を指定し、`attach` をtrueにすると添付する。`tag` を空にすると起動したrefをビルド・検証するだけで、成果物はartifactにだけ残す。検証用のブランチでは、一時的に `push` トリガーを足して同じjobを回し、添付しない状態で両CPUの成功を確認してから、トリガーを戻す。後付けのときは、タグのツリーのスクリプトとworkflowを使うため、タグ側にも `Publish-PrunletLinux.sh` と検証スクリプトが必要になる。

Linuxの起動時更新はこのtar.gzを直接使う。対象assetは `prunlet-linux-arm64.tar.gz`・`prunlet-linux-x64.tar.gz` とし、GNU tarのustar形式で `prunlet`、`manifest.json` の順に収録する。展開前と実行ファイルの上限は各64 MiB。起動側はGitHub APIのasset SHA-256とサイズを照合し、ローカルのチェックサムファイルは手動取得時に使う。
