# 配布

Prunletの配布物（WindowsのZIP・Setup、Apple SiliconのZIP、Linuxのtar.gz）は、Cloudflare R2（`https://prunlet.kagayoi.com`）だけから配る。GitHub Release・タグ・GitHub APIの最新版照会とブランチ比較は、配布にも更新の判定にも使わない。信頼の基点は、専用の鍵で署名したマニフェスト（下記）だけで、クライアントはR2の応答そのものを信頼しない。タグとGitHub Releaseは作らない（公開の告知は別の操作として扱う）。Windows ZIPのschema 1と同梱12ファイルの構成は従来どおり保つ。

## 署名付きマニフェスト

配布物ごとに、R2へ次の封筒（UTF-8・BOMなし・compact・キー順固定・末尾改行なし・16384バイト以下）を置く。

```json
{"schema":1,"keyId":"prunlet-release-1","payload":"<base64>","signature":"<base64 DER>"}
```

- 署名対象はpayloadをbase64復号した生バイトで、ECDSA P-256 + SHA-256、形式はRFC 3279のDER（`SEQUENCE { r, s }`）。base64は標準アルファベット・パディング付きの正規形だけを受理する。
- payloadは`{"schema":1,"product":"Prunlet","repository":"1llum1n4t1s/Prunlet","runtime":..,"version":"x.y.z","commit":"<40桁小文字hex>","defaultBranch":..,"asset":{"name":..,"key":..,"bytes":<整数>,"sha256":"<64桁小文字hex>"}}`の固定の形で、時刻を含まない。同じ入力からは同じバイト列になるため、再実行では署名ではなくpayloadのバイト一致で照合する。
- 配信側の正本は`scripts/PrunletRelease.Common.ps1`、クライアント側の検証はRustの`src/rust/update/manifest.rs`（起動時更新・Setup版の更新・Windows launcherが使う内部コマンド）と、インストーラーの`scripts/Install-Prunlet.ps1`・`scripts/Install-Prunlet.sh`にある。3か所とも公開鍵を定数`PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64`として固定し、Rustは受理する鍵を配列で持って鍵の交代に備える（交代時は新旧を並べ、旧鍵は全クライアントの移行後に外す）。`integration/start-prunlet-mcp.ps1`は鍵を持たず、検証をRustの内部コマンド（`__check-release-manifest`・`__download-release-package`・`__prepare-release-package`）に任せる。テスト鍵（`prunlet-release-test-1`）はテスト用のビルドだけが受理する。

クライアントは次をすべて確かめ、1つでも外れたら何も適用せずに延期する（fail-closed）。取得の失敗も同じ扱いにする。

- 固定の公開鍵での署名検証と、封筒・payloadの正規形。
- `product`・`repository`・`runtime`が自分と一致し、`asset.name`が固定の配布物名であること。
- `asset.key`が、自分で組み立てたキー（下表）と完全一致すること。配布物はベースURLとそのキーだけから取得し、リダイレクトを辿らない。
- `bytes`がruntimeの上限（Windows ZIP・Setupは512 MiB、macOS・Linuxは64 MiB）以下で、取得した実物の長さとSHA-256が一致すること。
- 版が厳密な`x.y.z`で、導入済みの版より厳密に大きいこと（後退・同版の再適用を防ぐ）。

どのcommitを配ってよいかはCIが決める。配信workflowは、起動したブランチが`release/<版>`でその版が`Cargo.toml`と一致すること、チェックアウトしたHEADがイベントのcommitであること、そのcommitが既定ブランチ（`main`）の祖先であることを`scripts/Assert-PrunletReleaseRef.ps1`で確かめてから署名する。クライアントは`main`の子孫判定を自分では行わず、署名済みマニフェストを信頼する。運用の前提は「`main`をpushしてから、同じcommitで`release/<版>`を切る」こと。

署名鍵はPrunletの配信専用で、秘密鍵（PKCS8 PEM）はGitHub Environment `release`のSecret `PRUNLET_RELEASE_SIGNING_KEY`にだけ置く。workflowは鍵整合の関門とR2へ書くstepだけへ渡し、ビルドstepには渡さない。署名やR2への書込みの前に、`scripts/Test-PrunletReleaseKeyGate.ps1`が本番鍵で試験封筒に署名し、配信側の正本とクライアント側3か所の定数のすべてで検証できることを確かめる。一致しない・定数が無い・重複している場合は、R2へ何も書かずに止まる。関門は各ファイルから「識別子と同じ行の100文字以上のbase64リテラル」をちょうど1件抽出するので、定数は各場所で1か所だけに、識別子と同じ行で定義する。

## 配信先とキー

- bucket: `prunlet-updates`（repository variable `PRUNLET_R2_BUCKET`で既存の別bucketを指定可能）。
- 公開ホスト: `https://prunlet.kagayoi.com`。
- 資格情報: `CLOUDFLARE_API_TOKEN`（Environment `release`のSecret。R2の書込みと固定名のキャッシュ削除の権限）と`PRUNLET_R2_ACCOUNT_ID`。トークンが無い場合はS3互換キー`PRUNLET_R2_ACCESS_KEY_ID`・`PRUNLET_R2_SECRET_ACCESS_KEY`を使う。R2用の値は配信stepだけへ渡し、引数・ソース・ログへ出さない。

| object key | 内容 | 書込み |
| --- | --- | --- |
| `releases/1llum1n4t1s/prunlet/<commit>/<runtime>/<sha256>.zip`（Linuxは`.tar.gz`） | Windows・macOS・Linuxの配布物 | 新規作成のみ。既存なら内容全体を照合し、違えば失敗 |
| `manifests/<版>/<runtime>.json` | 版ごとの署名付きマニフェスト | 新規作成のみ。既存なら署名とpayloadを照合し、違えば失敗 |
| `latest/<runtime>.json` | 最新ポインタ（最新版のマニフェストと同じ封筒） | ETag条件付きの置換。現行より古い版へは戻さない |
| `download/latest/prunlet-linux-<x64\|arm64>.tar.gz`と`.sha256` | Linuxの手動取得用の固定名 | 最新ポインタの更新後に置換（`.sha256`が最後） |
| `velopack/`配下と`manifests/<版>/velopack-win-x64.json` | Setup（Velopack）のフィード・nupkgとそのマニフェスト | 下記の[Setup](#windowsの-setupvelopack)の順序 |

runtimeは`win-x64`・`win-arm64`・`linux-x64`・`linux-arm64`・`osx-arm64`・`velopack-win-x64`。Setupは最新ポインタを持たず、フィードの`releases.win.json`が最新を兼ねる。固定名（最新ポインタ・Linuxの固定名）は`no-cache`で配り、置換後にキャッシュ削除を試みる（失敗は警告だけ）。版付きのキーは一意で不変なので削除しない。bucket・DNS・資源の作成や削除は公開処理に含めない。

配信workflowは、書込みの前に全runtimeについて、既存の版マニフェストとの照合と最新ポインタの後退判定を読取りだけで済ませる。そのあと、配布物（新規作成）→公開URLでの照合→版マニフェスト（新規作成）→最新ポインタ→固定名の順に置く。結果が不明な送信を自動再送しない。

## 署名

`prunlet.exe`・`prunlet-maintenance.exe`・`prunlet-hook.exe`はCertumのコード署名証明書でAuthenticode署名し、RFC 3161タイムスタンプを付ける。署名はrelease workflowで[Sigilune](https://github.com/1llum1n4t1s/Sigilune)を使い、SimplySignのクラウド鍵へ直接接続して行う（SimplySign Desktop・手入力のワンタイムコードは不要）。hookはCLIと同一hashである必要があるので、CLIを署名してからhookへ複製する。同梱の`.ps1`・`PRUNLET.md`はsourceと同一bytesで照合するため署名しない。`Install-Prunlet.ps1`による手動導入もソースをビルドせず、署名付きマニフェストが指す署名済み更新ZIPを起動時更新と同じ条件で照合して配置する。未署名・署名者違い・タイムスタンプなしの実行ファイルは配置しない。そのため、配信workflowが最新ポインタを更新するまでの間は、手動導入も前の版を導入する。

- 署名用のSecrets `SIGILUNE_EMAIL`・`SIGILUNE_TOTP_URI` は、Environment `release`（承認者なし。`release/*`ブランチだけ許可）にだけ置く。workflowは署名stepだけへ渡し、Rustのビルド（依存crateのbuild scriptを含む）には渡さない。同じEnvironmentに`PRUNLET_RELEASE_SIGNING_KEY`と`CLOUDFLARE_API_TOKEN`も置き、それぞれ関門・R2の各stepだけへ渡す。
- 別マシンの並列jobが同じTOTP時間枠を使うとCertumが後者を拒否するため、win-x64・win-arm64を1つのjobで扱い、同じSigiluneセッションで署名してログインを1回にする。v1.0.0公開前のSigiluneで1回の呼出しに複数ファイルを渡すと、signtoolの異常終了やdlibのpanicが観測されたため、1ファイルずつ呼び出す。失敗時に自動再試行しない。
- 署名・検証の処理は`scripts/Signing.Common.ps1`と`scripts/Sign-PrunletBuild.ps1`に集約する。署名後はSigiluneの検証に加えて、Windowsの判定が`Valid`であること、署名者の共通名、タイムスタンプの存在を独立に確認する。タイムスタンプがないと証明書の期限切れ後に`Valid`でなくなり、公開済みクライアント（NotSigned・Valid以外を拒否する）が更新を受け付けなくなる。

## 公開の順序

送信前には、公開済みWindowsクライアントと同じZIP 512 MiB・実行ファイル各256 MiB・補助ファイル各4 MiBの上限、PE offset・machine、リンク属性の禁止、Authenticodeが署名者・タイムスタンプ付きのValidであることも照合する。

`release/<版>`ブランチへのpush（`/vava`が`main`をpushしてから同じcommitで`release/<版>`をpushする）をきっかけに、`.github/workflows/prunlet-release-package.yml`が1つのjobで次を行う。jobは承認待ちなしで始まる（Environment `release`は承認者なし・ブランチ制限だけ）。

1. `Assert-PrunletReleaseRef.ps1`がブランチ名と`Cargo.toml`の版、HEADとイベントのcommit、既定ブランチの祖先であることを確認し、鍵整合の関門を通す。続けて`scripts/Invoke-PrunletTests.ps1 -Mode Standard`（`cargo test --locked`）を実行し、失敗したら署名・R2配置へ進まない。起動時更新の検証用cfg（`prunlet_windows_update_tests`）のテストは、`main`のpushとPRで動く`.github/workflows/prunlet-tests.yml`の`update-cfg` jobが担う（配信jobでは動かさない）。
2. win-x64・win-arm64を`Publish-Prunlet.ps1`でビルドし、製品の版を照合する。
3. Sigiluneを導入し、`Sign-PrunletBuild.ps1`で両runtimeの実行ファイルを署名する。署名後のhashと署名者・署名前hashを`build-manifest.json`へ記録する。
4. `Package-PrunletUpdate.ps1`で梱包し、`Verify-ReleasePackage.ps1 -RequireSignature`が同梱物・版・machine・metadata・hashと署名を検証する。
5. `Publish-PrunletR2.ps1 -CheckOnly`が全runtimeの既存マニフェストと最新ポインタを読取りだけで検査し、続けて`Publish-PrunletR2.ps1`が署名を含めて再検証したZIPを、上の順序でR2へ置いて署名付きマニフェストを発行する。R2 SDK連携は`R2Distribution.Common.ps1`に置く。

再実行は、原因を確認してから同じ`release/<版>`のrefで`workflow_dispatch`する。署名の失敗を自動で再実行しない。同じ版を再ビルドするとZIPのhashが変わるため、配信済みの版の再配信はpayloadの不一致で失敗する（patchを上げて新しい`release/<版>`を切る）。

## Windowsの Setup（Velopack）

Windows x64には、更新ZIPとは別に Velopack の Setup（ユーザー単位・管理者不要・署名付き）を配る。ZIP（上記）と併存し、同じ`release/<版>`の同じ`prunlet.exe`・`prunlet-maintenance.exe`を使う。win-arm64はZIPのままで、Velopackには含めない。ZIPと旧更新コードの廃止は別の変更で行う。

契約:

- packId `PrunletApp`、packTitle `Prunlet`、主exe `prunlet.exe`、チャネル `win`、runtime `win-x64`、ショートカットなし。Velopack CLI（`vpk`）は 1.2.161 に固定する（Rust側のcrateも同じ版）。導入先は`%LOCALAPPDATA%\PrunletApp`で、`%LOCALAPPDATA%\Prunlet`（Backups等）とは衝突しない。
- `lib/app/`のエントリは`prunlet.exe`・`prunlet-maintenance.exe`・`LICENSE`と、vpkが足す管理ファイル（`Squirrel.exe`・`Prunlet_ExecutionStub.exe`・`sq.version`）だけ。`prunlet-hook.exe`・ps1・`PRUNLET.md`は入れない（hookは導入・更新後に署名済みの`prunlet.exe`の複製を`%LOCALAPPDATA%\Prunlet\hook`へ置く）。
- フィード: バケット `prunlet-updates` の`velopack/`、公開URL `https://prunlet.kagayoi.com/velopack/`（`releases.win.json`・`assets.win.json`・`RELEASES`・版付きnupkg・版付き／固定名のSetup）。ZIPのobject key（`releases/...`）とは別のprefixで、互いに触れない。
- 信頼の基点は署名付きマニフェスト`manifests/<版>/velopack-win-x64.json`（runtime `velopack-win-x64`、asset名`PrunletApp-<版>-full.nupkg`、キー`velopack/PrunletApp-<版>-full.nupkg`）。クライアントは、署名・製品名・版・エントリ集合の検査に加えて、R2から取得したnupkgのSHA-256を、このマニフェストの値と照合し、照合できなければ適用しない。フィードの版から版付きのマニフェストを引き、導入済みより新しい版だけを候補にする。

公開の流れ（`.github/workflows/prunlet-release-package.yml`の`package` jobにstepを足している。Sigiluneのログインを1回に保つため別jobにしない）:

1. win-x64・win-arm64のビルドと版照合（上記）。続けて`vpk` 1.2.161を導入する。失敗してもZIPの配布は止めない。
2. Sigiluneを導入し、`Sign-PrunletBuild.ps1`で両runtimeのexeを署名する（上記）。同じstepで`scripts/velopack/pack-windows.ps1 -Sign`が署名済みのwin-x64 publishから`vpk pack`を行い、vpk自身の生成物（`Squirrel.exe`・実行スタブ・Setup）を署名する。署名済みの製品exeは`Sign-IfNeeded.ps1`が再署名せず通すので、ZIPとnupkgで同じバイト列になる。このstepはcargoを動かさない。vpkの失敗は出力`velopack_pack=failed`へ残し、署名（`Sign-PrunletBuild.ps1`）の失敗だけがjobを止める。
3. ZIPの梱包と検証（上記）。
4. `scripts/velopack/verify-windows.ps1 -RequireSignature`がVelopackの一式を検証する: フィードのFull資産とnupkgの一致、エントリ集合、全PEの署名者CN（`Open Source Developer Yuichiro Shinozaki`）・タイムスタンプ、PE machineがx64、製品名`Prunlet`と製品版がnupkgの版、Setupの署名。nupkgのSHA-256ファイルを`packages\`の外へ作る（保存物の整合確認用で、信頼の基点ではない）。
5. 検証済みの一式をartifact `prunlet-velopack-<版>`として保存する（やり直し用。保持30日）。
6. ZIPをR2へ置き、署名付きマニフェストを発行する（上記）。
7. `scripts/velopack/publish-r2.ps1 -ManifestOnly`が、Setupの署名付きマニフェストをnupkgより先に新規作成のみで置く（既存なら署名とpayloadで照合する。現行のフィードが新しい版なら何も置かずに失敗する）。
8. `scripts/velopack/publish-r2.ps1`がVelopackの一式をR2へ置く。版付きの成果物は新規作成のみ（既存なら内容を照合し、違えば失敗）、フィード（`releases.win.json`、ETag条件付き）を版付きの直後に置き、その成功後にだけ固定名のSetup・assets・RELEASESを置く。配信前に現行の`releases.win.json`を読み、現行が今回より新しければ何も置かずに失敗し、同じ版なら固定名を置き換えない（読めなければ配信しない）。
9. 最後のstepが、vpk・梱包・検証・保存・マニフェスト・R2配信の結果をまとめ、どれかが失敗していればjobを失敗にする（ZIPの配布は独立に完了している）。

secrets・variables: R2は上記ZIPと同じ資格情報と`PRUNLET_R2_BUCKET`（repository variable、未設定は`prunlet-updates`）。署名はEnvironment `release`の`SIGILUNE_EMAIL`・`SIGILUNE_TOTP_URI`、マニフェストの署名は`PRUNLET_RELEASE_SIGNING_KEY`。R2用の値とマニフェストの署名鍵は配信stepだけへ渡し、ビルド・梱包のstepには渡さない。

クライアントがR2のフィードを信用しすぎないための構え（適用前の検査はクライアント側。契約は次のとおり）:

- 取得はVelopackの`download_updates`を使わず、クライアントが自前で行う（`download_updates`は取得直後に`<root>\Update.exe`を上書きし、Deltaがあれば実行するため、検査前の未検証コードがrootに置かれる）。フィードから選ぶのは`TargetFullRelease`のFullだけで、Deltaは無視する。nupkgは`%LOCALAPPDATA%\Prunlet\state\incoming\<GUID>\`（rootの外）へ取得し、フィードのサイズ・SHA-256との照合 → nupkgの検査（署名者CN・タイムスタンプ・製品名・版・エントリ集合・machine）→ 署名付きマニフェストとの照合のすべてに通ったものだけを、Velopackの`packages\`へ移す。どれかに通らなければ`update-check`は`failed`で、`packages\`には何も置かず、`incoming`も片付ける。適用時（`update-apply`）にも、同じ検査とマニフェストの再取得・再検証を行う（SHA-256の不一致は`untrusted`・終了コード2、取得できない・署名を検証できなければ`deferred`）。フィードの`releases.win.json`は版の候補を知るためだけに使う。
- 更新器（`Update.exe`）は、適用時に検証済みのnupkgの`lib/app/Squirrel.exe`（エントリ集合にちょうど1つ、署名検査済み）からだけ展開される。さらに、引き渡す直前に、現行の`<root>\Update.exe`が期待する署名者・タイムスタンプ付きの署名であることを確かめ、そうでなければ`untrusted`で引き渡さない。フィードやR2のファイルが差し替わっても、取得の段階で`<root>\Update.exe`は変わらない。
- 差分更新（Delta）は使わない。梱包は`--delta None`で、フィードにDeltaの資産があっても取得・適用しない（full nupkgだけ）。
- この挙動は、隔離E2Eの悪性フィードの検査（[検証手順](verification.md#setupvelopackの梱包配信の検証)）で、`update-check`が`failed`、`<root>\Update.exe`が不変、`packages\`が空、Deltaが無いことを確かめる。

配信（マニフェスト・R2）だけが失敗したときは、`.github/workflows/prunlet-velopack-redo.yml`を、再配信する`release/<版>`のrefで`workflow_dispatch`し、保存した配布workflowの実行ID（`run_id`）を指定する。保存した実行が同じcommitに対する「Prunlet release packages」のものであることを確かめ、再ビルド・再署名はせず（Sigiluneは使わない）、保存済みの一式を取得して`verify-windows.ps1 -RequireSignature`で再検証し、`.sha256`が保存時と一致することを確かめてから、署名付きマニフェスト（未作成なら署名して置き、既存なら照合する）とR2配信だけを行う。ZIPは再配布しない。artifactの期限切れ、または梱包・検証・保存より前の失敗（vpkの導入・署名・検証）には使えない。その場合は配布workflowの修正と、本人の判断による新しい版での公開が要る。R2のnupkgとマニフェストは新規作成のみで、既存と内容が違えば失敗する。署名の失敗は自動で再実行しない。

手元の確認は、未署名のテスト用packId（`PrunletVelopackTest`）で`pack-windows.ps1`・`verify-windows.ps1`を実行し、`publish-r2.ps1 -DryRun`で配信計画を確かめる（[検証手順](verification.md#setupvelopackの梱包配信の検証)）。実R2・実署名はこの確認に含めない。

## Apple Silicon版の公開手順

`vava` のMac工程は `ssh mac` のApple Silicon実機で実行する。ビルド・署名・公証・ZIP生成はGitHub Actionsで行わない。Actionsの`prunlet-mac-release.yml`は、実機で作ったZIPをR2上で照合して署名付きマニフェストを発行するだけで、自分でビルドしていない物に署名する。Developer IDの署名と公証の検証（Appleの信頼）はクライアント側（インストーラー・起動時更新）の責任で、workflowでは行わない。

1. `ssh -o BatchMode=yes mac 'uname -sm; xcode-select -p'` で `Darwin arm64` とXcodeを確認する。非対話SSHから、`rust-toolchain.toml` のツールチェーンと `aarch64-apple-darwin` を使えるようにする。Mac上の外部作業ディレクトリに、`release/<版>`（`main`に含まれる固定済みリリースSHA）のクリーンなチェックアウトと専用出力先を用意する。
2. [Macのリリースビルド](macos.md#リリースビルド)に従い、同じSSHセッションでDeveloper ID Applicationの署名鍵と `notarytool` のプロファイルを使う。資格情報が未配置なら、管理者の署名用正本から今回専用のキーチェーンを準備する。鍵やパスワードをソース・ログ・GitHubへ渡さず、一時キーチェーンと鍵の作業コピーは作業後に清掃する。
3. 公証の `Accepted` と `package.json` の版・SHA・`osx-arm64`・ZIPのサイズとSHA-256を確認する。Macから転送した同じ `prunlet-update-osx-arm64.zip` を、送信直前に再度照合する。
4. `scripts/Send-PrunletMacPackage.ps1 -PackagePath <ZIP絶対パス> -CommitSha <40桁SHA> -Version <版>`で、R2の不変キー`releases/1llum1n4t1s/prunlet/<commit>/osx-arm64/<sha256>.zip`へ新規作成のみで送る。ZIPの2項目・`manifest.json`の版・commit・runtime・実行体の長さとSHA-256を送信前に独立に検査する。R2の資格情報だけを使い、Macの資格情報やマニフェストの署名鍵は使わない。同じsha256の再送は既存objectを照合するだけで上書きしない。
5. 表示された`sha256`・`bytes`を入力にして、`release/<版>`のrefで`prunlet-mac-release.yml`を`workflow_dispatch`する。workflowはR2の実物の長さ・SHA-256・ZIPの中身・`manifest.json`をチェックアウトしたHEADの版・commitと照合し、既存の版マニフェストと最新ポインタを読取りだけで検査してから、版マニフェスト（新規作成）→最新ポインタの順に発行する。
6. 再開時は、R2の不変キーと版マニフェストの状態を確認し、一致済みのZIPを再ビルド・再送しない。不一致や結果不明のobjectを上書きしない。

## Linux版の公開手順

Linux版は、`release/<版>`ブランチへのpushで `.github/workflows/prunlet-linux-release.yml` が自動で動く。手作業での配信はしない。build jobは、x64は `ubuntu-24.04`、ARM64は `ubuntu-24.04-arm` の各ランナー（`ubuntu-latest` はglibc要件が `docs/linux.md` の2.39を超える版へ移ったため使わない）で、起動したrefをクリーンにチェックアウトし、`release/*`ではWindows版と同じ検査（ブランチ名と版、HEADとイベントのcommit、既定ブランチの祖先）を通してから次を行う。build jobはSecretsを持たない。

1. `rust-toolchain.toml` が指定するRustで `cargo test --locked --lib` と `cargo test --locked --test localization` を実行する。
2. `bash scripts/Publish-PrunletLinux.sh <新規の絶対出力先> <40桁SHA> <linux-x64|linux-arm64>` でビルドする。生成するtar.gzには `prunlet` と、版・コミット・対象・実行体サイズ・SHA-256を記録した `manifest.json` を収録する。スクリプトがELFのアーキテクチャと梱包内容を照合し、配布実物のチェックサムを `.tar.gz.sha256` へ保存する。
3. 成果物から、tarの内容・manifest・上限・チェックサムを再確認し、実行体が要求するglibcのシンボル版が2.39以下であることを確認する。
4. 配布tar.gzから取り出した実行体で `scripts/Verify-LinuxFiles.ts` を、版とコミットが異なる3世代のデバッグビルド（`prunlet_linux_update_tests`）で `scripts/Verify-UnixStartupUpdate.ts` を実行する。Windowsの起動時更新に相当する実プロセスの検証（E2E）は配信workflowでは行わず（cfg付きの`cargo test --lib`だけは`prunlet-tests.yml`で行う）、`all(windows, debug_assertions, prunlet_windows_update_tests)`の検証用ビルド（`RUSTFLAGS='--cfg prunlet_windows_update_tests -C debug-assertions=on'`で`Publish-Prunlet.ps1 -IncludeVerificationProbe`）を`Verify-LatestInstall.ps1`へ渡して手元で行う（[latestインストーラー](verification.md#latestインストーラー)）。
5. 検証済みのtar.gzとチェックサムをartifactへ保存する。

publish job（Environment `release`。`release/*`の実行だけで動く）は、両CPUのbuildが成功した場合だけ、同じref検査と鍵整合の関門を通し、artifactの中身（ustar・2エントリ・manifest・上限・`.sha256`）を`scripts/Publish-PrunletLinuxR2.ps1`で独立に再検査する。`-CheckOnly`で既存の版マニフェストと最新ポインタを読取りだけで検査してから、tar.gz（新規作成）→公開URLでの照合→版マニフェスト（新規作成）→最新ポインタ→手動取得用の固定名（`download/latest/`。`.sha256`が最後）の順に置く。

`release/*`以外のrefで`workflow_dispatch`すると、build jobのビルド・検証とartifact化だけを行い、publish jobは動かない。検証用のブランチでの確認に使う。

Linuxの起動時更新はこのtar.gzを直接使う。対象assetは `prunlet-linux-arm64.tar.gz`・`prunlet-linux-x64.tar.gz` とし、GNU tarのustar形式で `prunlet`、`manifest.json` の順に収録する。展開前と実行ファイルの上限は各64 MiB。起動側は署名付きマニフェストの長さとSHA-256で照合し、固定名の`.sha256`は手動取得時の転送確認に使う。
