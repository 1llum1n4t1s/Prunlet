# Windowsの更新ZIP配布

新しいRust CLIはCloudflare R2からWindowsの更新ZIPを取得する。GitHub Releaseは発行者・タグ・コミット・digest・sizeを確認する信頼の基点と、旧CLI向けの同一ZIPの配布を担う。macOSの起動時更新と、手動installerの最新HEADからのソースビルドはこの変更の対象に含めない。

## R2の設定

既存のCloudflare運用と同様に、専用bucketと公開用カスタムドメインを使う。設定変更や資源作成は公開時に別途実行する。開発時のfixture検証によって作成されたとは扱わない。

| 設定 | 値・役割 |
| --- | --- |
| bucket | `prunlet-updates`。既存bucketを使う場合はrepository variable `PRUNLET_R2_BUCKET`を指定する。 |
| 公開ドメイン | `prunlet.kagayoi.com`を対象bucketへ接続する。クライアントとpublisherが同じ固定ホストを使用する。 |
| repository secret `PRUNLET_R2_ACCOUNT_ID` | 対象Cloudflareアカウントの32桁ID。 |
| repository secret `PRUNLET_R2_ACCESS_KEY_ID` | 対象bucketだけに範囲を限定したS3互換APIのアクセスキー。 |
| repository secret `PRUNLET_R2_SECRET_ACCESS_KEY` | 上記の秘密キー。script引数・ソース・ログへ保存しない。 |

キーには対象bucketのobject読み書き権限が必要。既存objectの全内容照合に読取りを使う。bucket一覧・資源作成・object削除を配布処理に追加しない。公開ドメインはHTTPSで直接配信し、認証ページや別ホストへのリダイレクトを挟まない。[Cloudflareの公開bucketの説明](https://developers.cloudflare.com/r2/buckets/public-buckets/)に従い、本番配信に開発用`r2.dev`を使用しない。

object keyは`releases/1llum1n4t1s/prunlet/<commit>/<runtime>/<ZIP SHA-256>.zip`で、commitとSHA-256は小文字。runtimeは`win-x64`または`win-arm64`に限定する。同じcommitの再ビルドでもZIPが異なれば別のkeyになる。可変の`latest` objectは作らない。

## 公開の順序

通常の修正では公開しない。正式リリースを依頼された場合に、公開タグへ固定したworkflowが次の順に実行する。

1. タグ・イベントSHA・既定ブランチの祖先関係と製品versionを確認する。`rust-toolchain.toml`の固定toolchainでホスト用`prunlet-release`だけを外部targetへbootstrapし、`prunlet-release build --release-source true`で指定runtimeの製品3本と`build-provenance.json`を生成する。ビルド前後でGit HEADが指定commitと一致することと、同梱scripts・integrationを含む全製品入力がHEADの追跡内容と一致することを確認し、対象入力のdirty・untracked・ignoredファイルを拒否する。
2. `prunlet-release package`でZIPを生成し、`prunlet-release verify`で同梱全ファイル・PE/version・ソース・build provenanceを今回のpublish出力へ照合する。既存の12 payloadと`package.json`の形式を維持する。
3. `prunlet-release publish-r2`で再検証した同一ZIPを固定してR2へ配置し、公開URLから取得した全bytesの長さ・SHA-256を照合する。資格情報は上記の環境変数で渡す。
4. 返されたSHA-256と手元のZIPを再確認して、従来名`prunlet-update-<runtime>.zip`で同じGitHub Releaseへ添付する。既存assetを上書きしない。

R2の新規配置は`If-None-Match: *`を付ける。[R2の条件付き書込み](https://developers.cloudflare.com/r2/api/s3/api/#conditional-operations)で既存objectの上書きを防ぐ。既存objectはS3側の全bytesと公開URLの全bytesが一致する場合だけ再利用する。内容が異なる場合、HTTPエラー、応答が不明な場合は停止し、objectを削除して再試行しない。R2の成功だけでは公開完了とせず、GitHub側の同一ZIPとdigestを確認する。

失敗時は秘密を含まない`phase`と`code`を表示する。`credentials / unavailable-before-http`は通信前の資格情報不足で、対象bucket用secretを確認する。`s3-put / unknown-no-resend`は書込み結果が不明であるため、同じPUTを自動再送しない。ZIPと期待するkey・SHA-256を保持し、既存objectを全内容照合できる状態になってから再開する。生のHTTP応答・Authorization・秘密キーをログへ追記しない。

## 更新互換と信頼範囲

GitHubのタグ・祖先関係・digest・size・asset IDを認証した後に、R2 URLを導出する。R2に置いたchecksumだけを信頼せず、取得したZIPとGitHubのdigest・sizeを照合する。ZIP内部のcommit・runtime・製品hashの検証も維持する。詳細は[設計](../DESIGN.md#起動時自動更新)を参照する。

R2対応を広告しない旧CLIと、公式以外のリポジトリは従来のGitHub取得を事前に選ぶ。GitHub経路の既存内部コマンドと更新stageはその意味を保つ。準備途中の検証済みstageは元の配布先を継承するため、旧launcherが作ったGitHub stageも新launcherで再開できる。R2専用stageを旧CLIで再準備する操作は拒否して保全する。R2取得の失敗からGitHubへ自動的に切り替えず、安全な現在版を継続できるかは既存の更新状態に従って判定する。`source-info.json`の`downloadUrl`は今回選択した検証済み配布先で、同じZIPをcacheから再利用する場合もそのURLを記録する。

リリースCIのソース取得と工程の接続はGit Bash・純git・`gh`で行い、ビルド・package・verify・R2処理の中心はRust製`prunlet-release`に置く。Node.js、npm、Wranglerは配布に要求しない。GitHub hosted runnerに別用途のNodeが入っていることと、このworkflowの依存は区別する。インストーラーと開発用probeのPowerShell入口はSDK起動用の薄いbridgeとして維持し、この移行をインストーラー全体の移植とは扱わない。

## Rust製リリースCLI

bootstrapは固定toolchain・`--locked --release --bin prunlet-release`で行う。Cargo targetとTEMP/TMPはリポジトリ外の絶対パスへ隔離し、Windowsでは`CARGO_ENCODED_RUSTFLAGS`に`-C`・区切り文字U+001F・`target-feature=+crt-static`を設定する。bootstrapしたexeの絶対パスを以降の全工程で固定して使う。

```text
prunlet-release.exe build --source <ソース絶対パス> --output <外部出力絶対パス> --commit <40桁SHA> --branch <既定ブランチ> --runtime <win-x64|win-arm64> --repository 1llum1n4t1s/Prunlet --release-source true
prunlet-release.exe package --source <ソース絶対パス> --publish <外部出力絶対パス>/publish --package <ZIP絶対パス> --commit <40桁SHA> --branch <既定ブランチ> --runtime <win-x64|win-arm64> --repository 1llum1n4t1s/Prunlet
```

`verify`と`publish-r2`は`package`と同じ引数を受け取る。これらの公開用コマンドはGit HEADと全製品入力の照合を必須とし、GitHub添付の直前にも`verify`を再実行する。`verify`はZIP全体の大文字SHA-256を1行で返す。`publish-r2`はschema 1の公開結果JSONを返し、`verified`・SHA-256・bytes・commit・runtime・repositoryを照合してから同じZIPをGitHubへ添付する。`build`は任意の`--target-directory <外部絶対パス>`も受け取り、既定の出力先は`<output>/publish`、provenanceは`<output>/build-provenance.json`である。製品3本のAuthenticodeは固定した実物handleに対してWinVerifyTrustで確認し、`NotSigned`と`Valid`だけを許容する。無効な署名は拒否し、未署名を署名済みとは扱わない。インストーラー用のarchiveビルドは`--release-source`の既定値falseを使い、公開用のGit拘束と区別する。

## 公開前の確認

[検証手順](verification.md#latestインストーラー)に、起動時更新の既存E2EとRust製R2 publisherの検証範囲を分けて記載する。旧.NET providerのfixture結果を新しいWinHTTP providerの検証結果として扱わない。新WinHTTP provider向けの障害条件fixtureは未整備である。公開時は実物ZIPの`verify`、公開URLの全bytes、GitHub mirrorのdigest・sizeを確認する。旧CLIからの更新と新CLIのR2取得は、公開処理の成功と区別して扱う。
