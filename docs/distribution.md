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

1. タグ・イベントSHA・既定ブランチの祖先関係を確認し、指定されたRust toolchainでビルドする。
2. `Package-PrunletUpdate.ps1`でZIPを生成し、`Verify-ReleasePackage.ps1`で同梱全ファイルを今回のソースとpublish出力へ照合する。
3. `Publish-PrunletR2.ps1`で再検証した同一ZIPを固定してR2へ配置し、公開URLから取得した全bytesの長さ・SHA-256を照合する。
4. 返されたSHA-256と手元のZIPを再確認して、従来名`prunlet-update-<runtime>.zip`で同じGitHub Releaseへ添付する。既存assetを上書きしない。

R2の新規配置は`If-None-Match: *`を付ける。[R2の条件付き書込み](https://developers.cloudflare.com/r2/api/s3/api/#conditional-operations)で既存objectの上書きを防ぐ。既存objectはS3側の全bytesと公開URLの全bytesが一致する場合だけ再利用する。内容が異なる場合、HTTPエラー、応答が不明な場合は停止し、objectを削除して再試行しない。R2の成功だけでは公開完了とせず、GitHub側の同一ZIPとdigestを確認する。

失敗時は秘密を含まない`phase`と`code`を表示する。`credentials / unavailable-before-http`は通信前の資格情報不足で、対象bucket用secretを確認する。`s3-put / unknown-no-resend`は書込み結果が不明であるため、同じPUTを自動再送しない。ZIPと期待するkey・SHA-256を保持し、既存objectを全内容照合できる状態になってから再開する。生のHTTP応答・Authorization・秘密キーをログへ追記しない。

## 更新互換と信頼範囲

GitHubのタグ・祖先関係・digest・size・asset IDを認証した後に、R2 URLを導出する。R2に置いたchecksumだけを信頼せず、取得したZIPとGitHubのdigest・sizeを照合する。ZIP内部のcommit・runtime・製品hashの検証も維持する。詳細は[設計](../DESIGN.md#起動時自動更新)を参照する。

R2対応を広告しない旧CLIと、公式以外のリポジトリは従来のGitHub取得を事前に選ぶ。GitHub経路の既存内部コマンドと更新stageはその意味を保つ。準備途中の検証済みstageは元の配布先を継承するため、旧launcherが作ったGitHub stageも新launcherで再開できる。R2専用stageを旧CLIで再準備する操作は拒否して保全する。R2取得の失敗からGitHubへ自動的に切り替えず、安全な現在版を継続できるかは既存の更新状態に従って判定する。`source-info.json`の`downloadUrl`は今回選択した検証済み配布先で、同じZIPをcacheから再利用する場合もそのURLを記録する。

CIのソース取得と自動マージも純git・PowerShell・`gh`で実行する。Node.js、npm、Wranglerは配布に要求しない。GitHub hosted runnerに別用途のNodeが入っていることと、このworkflowの依存は区別する。

## 公開前の確認

[検証手順](verification.md#latestインストーラー)の起動時更新E2Eと、R2 publisher・CI用の隔離fixture検証を使う。fixture成功は本番R2の資格情報・ドメイン・キャッシュ・GitHubの実権限を確認した結果ではない。初回公開時は公開URLの全bytes、GitHub mirrorのdigest・size、旧CLIからの更新と新CLIのR2取得を実際に確認する。
