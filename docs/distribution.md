# Windowsの更新ZIP配布

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

Apple Siliconの `prunlet-update-osx-arm64.zip` はGitHub Releaseで配布する。Mac実機での署名・公証・梱包は[macOSのリリースビルド](macos.md#リリースビルド)に従う。
