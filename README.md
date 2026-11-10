# Prunlet — Anti “blocked by policy”

Prunletは、`blocked by policy`による清掃の停止を減らすために、AIエージェントのファイル・フォルダー削除を専用CLI・MCPへ集約するWindows・Apple Silicon Mac・Linux用ツールです。許可された削除を最初からPrunletへ任せる使い方に揃えます。

通常はファイル・フォルダーをOSのゴミ箱へ移します。Prunletはファイルの操作記録・操作ID・復元用snapshotを保存せず、ゴミ箱からの復元と保持はOSに任せます。Codexフックは直接削除を検査・拒否し、CLI手順を案内します。提供元はKagayoiです。

ファイルと空フォルダーを扱い、`--recursive`を明示するとフォルダー全体を削除できます。リンク先は辿りません。ハードリンクはゴミ箱への移動後も生存する別名と内容を共有します。条件付きの永久削除と[レジストリの削除・復元](#レジストリの削除復元)はWindows専用です。

## `blocked by policy`対策としての使い方

AIが生成した`Remove-Item`や`rm`などの削除コマンドで清掃が止まりやすい環境では、許可された削除を最初からPrunlet CLIへ任せます。Apple Silicon MacとLinuxのCodexでは、導入時に配置したCLIと設定を使います。[macOSの導入手順](docs/macos.md)・[Linuxの導入手順](docs/linux.md)

WindowsのCodexでは、次の順序で利用します。

1. 下の[インストールと更新](#インストールと更新)のコマンドを、`-RegisterCodex -RegisterAgentInstructions`付きで実行します。CLI・MCP・フックと、Prunlet CLIを最初から使う共通指示を登録します。
2. Codexで`/hooks`を開いてPrunletフックを信頼し、Codexを再起動して登録内容を読み込みます。
3. 通常どおり作業や清掃を依頼します。共通指示は、配置済みCLIと設定の絶対パスを使い、CMD（`shell: cmd.exe`、`login: false`）からPrunletを直接呼び出すようCodexへ指示します。各リポジトリへ同じ指示を追加する必要はありません。

清掃を明示して依頼する場合は、たとえば次のように伝えます。

> 今回作成した不要な一時ファイルと作業フォルダーを、最初からPrunlet CLIで清掃してください。

空白・Unicode・長いパス・複数対象はUTF-8のJSON一覧を`--paths-file`で渡し、非空フォルダーには`--recursive`を明示します。実際のコマンドと復元方法は[削除・復元](#削除復元)を参照してください。

フックは直接削除を検出・拒否してCLI手順を案内する補助で、自動変換は行いません。失敗と再試行を繰り返さずに済むよう、共通指示による初回からのCLI利用を基本にします。ホストやOSの権限・承認・管理ポリシーは引き続き適用されます。Prunletの呼出し自体が拒否された場合は停止し、別経路で再試行しません。登録と検査範囲の詳細は[連携手順](docs/integration.md)を参照してください。

CodexからMacなどへ送るPowerShellスクリプトは、[フックの連携手順](docs/integration.md#hookの検査範囲)にある明示的な子PowerShellの形式で渡します。Codexのフック入力には実行shellが渡らないため、`shell: "pwsh"`の指定だけではヒアストリング内の削除を区別できません。

## インストールと更新

### Apple Silicon Mac

[GitHub Releases](https://github.com/1llum1n4t1s/Prunlet/releases/latest)から`prunlet-update-osx-arm64.zip`を取得します。署名・公証の確認、専用フォルダーへの新規導入、CodexのMCP登録は[macOSの導入手順](docs/macos.md)に従ってください。登録済みMCPは起動時に更新を確認し、使用中なら次回以降に延期します。

### Linux

CPUに合う`prunlet-linux-x64.tar.gz`または`prunlet-linux-arm64.tar.gz`と、同名の`.sha256`ファイルを取得します。[GitHub Releases](https://github.com/1llum1n4t1s/Prunlet/releases)

チェックサムの照合、専用ディレクトリへの配置、Codex登録は[Linuxの導入手順](docs/linux.md#初回インストール)を参照してください。公式配布版は、手順どおりに配置するとMCP起動時に更新を確認し、使用中なら次回以降に延期します。

### Windows

Windows x64・ARM64に対応します。下のインストーラーは[GitHubリポジトリ](https://github.com/1llum1n4t1s/Prunlet)の既定ブランチの最新コミットからビルドするため、PowerShell 7、Rustup・Cargo、対象アーキテクチャのMSVCビルドツールとWindows SDKが必要です。ビルドに使うRustの版は[`rust-toolchain.toml`](rust-toolchain.toml)の`channel`で固定されています。Rustターゲットがなければ、`rustup target add --toolchain <channelの値> <ターゲット名>`で追加してください。

| ビルド先 | Rustターゲット | インストーラーの指定 |
| --- | --- | --- |
| Windows x64 | `x86_64-pc-windows-msvc` | `-Runtime win-x64`（既定） |
| Windows ARM64 | `aarch64-pc-windows-msvc` | `-Runtime win-arm64` |

Windows ARM64では、下の実行コマンドに`-Runtime`を明示してください。x64エミュレーションを選ぶ場合は`-Runtime win-x64`を指定します。

```powershell
$installerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Codex\Prunlet\bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $installerDirectory | Out-Null
$installer = Join-Path $installerDirectory 'Install-Prunlet.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.ps1' -OutFile $installer
pwsh -NoProfile -File $installer -RegisterCodex -RegisterAgentInstructions
```

GitHub APIの未認証枠が上限に達した場合は、上の`pwsh`コマンドに`-UseGitHubCliAuthentication`を追加すると、既存のログイン済みGitHub CLIを利用できます。ghの自動導入・ログインは行いません。この指定は手動インストーラー用です。

インストーラーはGitHub APIから既定ブランチと最新コミットを取得し、そのコミットのアーカイブを取得してビルドします。導入処理中は取得したSHAでソースを揃えますが、次回の導入・更新は再び最新HEADを解決します。取得失敗やリモートの実装不足では停止し、ローカルクローンへ切り替えません。

既定の配置先は`%USERPROFILE%\.local\Prunlet`です。`bin\prunlet.exe`と登録用スクリプト・共通指示を配置し、`source-info.json`に取得元・ブランチ・コミットを記録します。`-RegisterCodex`を指定すると共通MCPとネイティブexeのフックも登録します。

自動更新では、CodexがPrunlet MCPを起動する際にGitHub Releaseのビルド済みバイナリを確認し、旧MCPや保守プロセスが終了しているときに切り替えます。自動更新ではソースの再ビルドは不要です。製品exeの実行に.NETランタイムやVCランタイムの追加導入は不要です。使用中なら終了させず、次のMCP起動時に再確認します。GitHub APIの未認証の通常リクエスト枠を使い切った場合は、設定済みのGitHub CLI（`gh`）の認証を使って自動で照会を続けます。通信や取得に失敗した場合は、更新前の状態が安全に保たれていれば現在の版を使います。

自動更新はGitHub Releaseの発行者を信頼し、取得した配布物の一致を検査します。検証の仕組みと信頼範囲は[起動時自動更新の設計](DESIGN.md#起動時自動更新)を参照してください。

更新データは専用の2 GiB枠で管理します。確認済みの領域を再利用し、未知のデータや中断した出力は保全します。容量不足時は更新を延期し、レジストリの復元データは整理対象にしません。

`-RegisterCodex`を指定した導入・更新後は、Codexで`/hooks`を開いてPrunletフックの定義を確認し、信頼してください。インストーラーは信頼設定を変更せず、結果の`requiresHookTrust`でこの操作が必要なことを通知します。Codexを再起動し、MCP・共通指示・フックの読込みを確認してください。登録と解除の詳細は[連携手順](docs/integration.md#登録)を参照してください。

上の`-RegisterAgentInstructions`は、Codex homeの`PRUNLET.md`と、共通`AGENTS.md`の専用参照・配置済みexeと設定の絶対パスを登録する明示オプションです。各リポジトリへ追記せず、最初からCMD上のPrunlet CLIで削除するようCodexへ指示します。exe・設定のパス自体をCMDで安全に表現できない場合は、実行前に同じCoreを使うMCPを選びます。共通指示を変更したくない場合はこのオプションを外してください。

自動更新では、共通指示を含む登録内容が変更不要な候補だけを切り替えます。登録済みの`PRUNLET.md`と候補の違いがCRLFとLFの改行形式だけなら、既存のファイルをそのまま使います。登録の上書きが必要な場合や、利用者による登録の変更を検出した場合は、更新を保留します。手動でインストーラーを使う更新では、共通指示を登録済みなら同じ`-RegisterAgentInstructions`を指定してください。詳細は[エージェント共通指示](docs/integration.md#エージェント共通指示)を参照してください。

自動更新の仕組みを持たない旧版からの初回更新や手動更新では、最新版のインストーラーを再取得して実行します。既存の`config.json`は保持容量の一度だけの移行を除いて保持します。旧復元データは[明示移行](#旧ファイル復元データの移行)で扱います。削除対象フォルダーの事前登録は不要です。旧`-AllowedRoot`は互換引数として受理しますが、削除範囲を制限しません。配置先は`-InstallDirectory`で変更できます。利用者のクローンパスをCodex設定へ登録することはありません。

既存の管理済み配置がGitリポジトリ配下にあり、通常の保存先検査で更新が止まる場合は、再取得したインストーラーに`-UpdateManagedInstallation -InstallDirectory <既存配置の絶対パス>`を追加できます。既存設定・配置情報・製品hashの一致を確認し、Git追跡対象がなく、Gitで除外されているか現在の共通CLI登録と一致する配置を更新します。確認できない配置は保全して停止します。条件の詳細は[連携手順](docs/integration.md#手動の設定準備)を参照してください。

事前に確認した最新HEADとの一致を要求する場合は、`-ExpectedCommitSha <40桁SHA>`を追加できます。取得した既定ブランチのHEADが異なれば、導入前に停止します。

取得したbootstrapファイルは一時物です。導入結果を確認して、そのbootstrap専用ディレクトリだけを清掃してください。アプリの配置先と復元用データは清掃対象に含めません。

更新前の製品や登録前のCodex設定のバックアップがある場合、導入結果の`updateBackupDirectory`に保存先が表示されます。既定は`%LOCALAPPDATA%\Codex\TaskArtifacts\Prunlet\install-<ID>`です。動作とCodex登録を確認し、復旧が不要になってから、その導入分のバックアップだけを清掃してください。連携スクリプトの設定バックアップは[連携手順](docs/integration.md)を参照してください。

MSIX環境でAppDataが別の実体へ転送される場合は、`-UpdateBackupRoot <実体の絶対パス>`で更新バックアップの親を明示できます。その下へ導入ごとの`install-<ID>`を作ります。導入ごとの保存先がリポジトリ、Codex home、配置先、作業場所、復元データと重なる場合は拒否します。旧PowerShellフックが残っている場合、インストーラーはPrunletでWindowsのゴミ箱へ移し、結果を同じ更新バックアップの`retired-products.json`に保存します。

## 初期設定

macOSとLinuxでは各OSの導入手順で設定を作成します。以下はWindowsの初期設定手順です。Windowsのインストーラーを利用した場合は初期化済みです。手動ではレジストリ復元データの保存先を指定します。`init`は既存設定を上書きしません。

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
& $exe --config $config migrate --dry-run
& $exe --config $config migrate --apply
```

`backupDirectory`はレジストリsnapshotと移行前の旧データを置く保護領域です。新しいファイル削除の記録・内容は保存しません。レジストリ記録は専用の`.registry-records-v1`配下へ保存します。設定の`allowedRoots`と旧`--allowed-root`は互換入力であり、削除範囲の許可リストには使いません。

手動の`init`は設定作成だけを行います。レジストリを使う前に`migrate --dry-run`で対象を確認し、`migrate --apply`を実行してください。未移行ならレジストリの通常操作は`migration_required`で停止し、旧ファイル領域を自動探索しません。ファイル削除はレジストリの移行状況に依存しません。

```json
{
  "schema": 1,
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery",
  "retentionDays": 7,
  "maxRecoveryBytes": 1073741824
}
```

## 削除・復元

### Apple Silicon Macでの削除・復元

[macOSのCLI例](docs/macos.md)にある実行ファイルと設定の絶対パスを使います。`delete --dry-run -- <絶対パス>`で対象を確認し、実行時は`--dry-run`を外します。`recycled`の項目はFinderのゴミ箱から復元できます。`ambiguous`の場合は元のパスとゴミ箱を確認し、同じ削除を自動再送しないでください。

協調的な`flock`の解放を待つには`delete-queue -- <絶対パス>`で登録し、`delete-queue-status <job-id>`で最終結果を確認します。取消は`pending`の間に`delete-queue-cancel <job-id>`で行います。

### Linuxでの削除・復元

[LinuxのCLI例](docs/linux.md#初回インストール)の実行ファイルと設定の絶対パスを使います。`delete --dry-run -- <絶対パス>`で対象を確認し、実行時は`--dry-run`を外します。ホームTrashと同じマウントの項目を移せます。`recycled`の項目はfreedesktop Trash対応のファイルマネージャーで復元できます。`ambiguous`の場合は元のパスとゴミ箱を確認し、同じ削除を自動再送しないでください。

### Windowsでの削除・復元

正式なsandbox権限申請に対応し、実効設定で申請が必要かつ許可されるCodexホストでは、実削除を初回から申請付きで実行します。dry-runはゴミ箱へのアクセス許可を保証しません。Windowsの管理者権限が必要な場合は、許可範囲内でエージェントが管理者CMDを起動し、同じ配置済みCLIと設定で実行・結果確認を行います。本人のUAC同意が必要な場合は操作を案内します。Prunlet自身は自動昇格せず、拒否・結果不明を別経路で再試行しません。詳細は[連携手順](docs/integration.md#sandboxとゴミ箱へのアクセス)を参照してください。

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --dry-run --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --paths-file C:\work\delete-paths.json
```

exe・設定は配置済みの絶対パスへ置き換えてください。Codexでは`cmd.exe`・`login: false`を指定します。空白・Unicode・多数・長い対象パスはshellへ展開せず、UTF-8 JSON配列の絶対パスで渡します。`--paths-file`は1〜256件、最大1 MiBです。

```json
["C:\\work\\project\\unused.txt", "C:\\work\\project\\other.txt"]
```

空フォルダーは通常の`delete`、内容があるフォルダーは`delete --recursive --paths-file <絶対JSONパス>`で扱います。単純なパスは`delete [--dry-run] [--recursive] -- <絶対パス> [...]`でも渡せます。ワイルドカード・ネットワークパス・未知のreparseタグは扱いません。リンクはリンク自体を削除し、リンク先を走査しません。`NUL`や`NUL.txt`などWindows予約名と同じ名前の通常ファイルは、実体を確認して追加確認なしで永久削除します。ゴミ箱には入りません。予約名の祖先・ディレクトリ・リンクはこの例外の対象外です。通常名では、Windowsが対象をゴミ箱には大きすぎると返した場合、またはゴミ箱が利用できず対象ドライブの即時削除設定を確認できた場合に限り、元の実体と名前を照合して永久削除を試みます。

結果は`dryRun`・`items`・`warnings`です。各項目の`path`・`kind`・`status`と任意の`error`を確認します。状態は`recycled`・`permanently_deleted`・`would_recycle`・`would_permanently_delete`・`already_absent`・`failed`・`ambiguous`で、ファイルの操作ID・backupPath・hash・sizeは返しません。`permanently_deleted`は指定した元の名前をゴミ箱に移さず削除したことを示し、他のハードリンクやバックアップの消去は意味しません。`failed`と`ambiguous`は成功扱いになりません。

`recycled`項目の復元はWindowsのゴミ箱から行います。`permanently_deleted`の元の名前はゴミ箱から復元できません。Prunletにはファイル復元コマンド・MCPツールがありません。ゴミ箱の復元先に既存項目がある場合は、Windowsの画面で競合を確認し、上書きしないでください。

使用中・権限不足・パス制限などで移動できない場合は結果を確認してください。失敗時の`error`には対象とエラーコードを含め、使用中の場合は観測できた保持元のPID・名前・ファイルパスも返します。再帰的な永久削除では、結果の`path`と`error`内の`Target`は指定したフォルダーを示します。`Failure entry`がある場合は失敗箇所の絶対パスを示し、保持元の診断もその箇所を対象にします。診断の範囲と制約は[連携手順](docs/integration.md#使用中のファイルと同時実行)を参照してください。Shell処理中に対象名が差し替えられると、別の実体がゴミ箱へ移る可能性があります。Prunletは移動後の実体を照合し、一致しない場合は`ambiguous`で停止します。`ambiguous`は元対象とWindowsのゴミ箱を確認し、同じ削除を自動再送しません。予約名の通常ファイルは、dry-runで`would_permanently_delete`を返し、実際には削除しません。それ以外の`would_recycle`は入力の事前検査結果で、実行時に`permanently_deleted`になるかどうかや実移動の成功は予測できません。

Windowsのゴミ箱にある間のアクセス権と、復元先の親からの権限継承もWindowsの動作に従います。ハードリンクは内容だけでなくACLも共有するため、ゴミ箱への移動時の権限変更が、生存する別名にも反映されます。

### 使用中のファイルを待機して削除する

Windowsで使用中の対象を待つ場合は、削除の開始前に明示的な`delete-queue`へ登録します。通常の`delete`は従来どおり同期で結果を返します。

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-status <job-id>
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-cancel <job-id>
```

非空フォルダーは`delete-queue --recursive --paths-file <絶対JSONパス>`、単純なパスは`delete-queue [--recursive] -- <絶対パス> [...]`で指定できます。登録応答は削除完了ではありません。返されたジョブIDで状態と最終結果を確認してください。MCPでは既存の`delete_files`に`action: "enqueue"`・`"status"`・`"cancel"`を指定します。詳細は[連携手順](docs/integration.md#明示的な削除待機キュー)を参照してください。

キューは対象・親・再帰対象の子の実体を削除前に固定し、共有・ロック違反だけを期限なく待ちます。待機中に実体が変われば中止し、削除開始後の失敗や不明な結果を再送しません。同じユーザー・Windowsセッションで最大8件（完了後の保持中も含む）です。待機中だけ取消でき、最終結果は1時間保持します。ジョブは専用の一時workerのメモリーだけにあり、ファイル操作の記録や復元用IDではありません。期限切れやOS・worker終了で結果を確認できない場合は、元対象とWindowsのゴミ箱を確認し、同じ削除を自動再送しないでください。

## レジストリの削除・復元

許可されたローカルのHKCU・HKLM・HKUのキーまたは値を、明示した32/64ビットviewで退避して削除できます。キーのパスは絶対指定し、`--`の後へ1件だけ渡します。`--value-name`を省略するとキー、指定すると文字通りの値名を対象にします。既定値は空の名前なので、PowerShellから空引数が失われない`--value-name=`を使えます。値削除と`--recursive`は併用できません。子キーを含む削除には`--recursive`が必要です。

キー名に含まれるコロンもそのまま指定できます。たとえば`HKCU:\Software\Example\C:#Program Files#Fixture.exe`の末尾は1つのキー名です。`%5C`などを含む名前も文字通りに扱い、URLデコードは行いません。

```text
prunlet --config <絶対パス> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
prunlet --config <絶対パス> registry-delete --view 64 --recursive -- HKCU:\Software\Example
prunlet --config <絶対パス> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
prunlet --config <絶対パス> registry-restore <operation-id>
```

退避データ・記録は現在のユーザーとSYSTEMだけがアクセスできる権限で保護し、権限の改変を検出した記録は復元・整理せず保全します。キーのデータと完全なアクセス権の保存には`SeSecurityPrivilege`が必要です。権限不足やトランザクションを利用できない環境では削除前に停止し、自動昇格しません。値の復元では親キーのアクセス権を変更しません。64bit Windows・64bitプロセス・view 64の保護された対象には、削除・dry-run・復元それぞれで`--access-mode backupRestore`を明示できます。現在の実効トークンに`SeBackupPrivilege`と`SeRestorePrivilege`が必要で、ACLや所有権を変更してアクセスを得る方式ではありません。既定は`normal`で、自動切替はしません。[選択条件と限界](docs/integration.md#保護されたレジストリへの明示アクセス)も確認してください。保存形式とトランザクションの設計は[DESIGN.md](DESIGN.md#レジストリの削除と復元)を参照してください。

復元は元のviewへ行い、既存キー・値（空の既定値も含む）を上書き・マージしません。Owner/SACLの復元権限が不足した場合もロールバックして退避を保全します。ルート自体・HKCR/HKCC・リモート・相対指定・任意のレジストリリンク・未知のschema・metadataや検証できない復元記録は拒否します。キーのclassも保存しますが、最終書込み時刻は復元せず、volatileキーも非volatileキーとして復元します。commit後の記録確定前に中断した操作は不明状態として保全し、自動整理・復元を拒否します。

実効ユーザーの`Software\Classes`別名の配下は、宛先を検証して扱います。削除・復元には別名への追加の書込み権限が必要で、別名の最終書込み時刻が変わる場合があります。dry-runは書込みを行いません。Classes自身やその他のリンクは対象にしません。対応するパスと安全条件は[設計](DESIGN.md#レジストリの削除と復元)を参照してください。

MSIX由来の仮想viewで6801になる場合は、[通常Windowsの明示セッション](docs/integration.md#通常windowsのレジストリを明示して操作する)を利用できます。利用者が通常デスクトップで期限付きセッションを起動し、専用設定を選んだCLI・MCPから接続します。仮想viewからの自動切替や自動昇格は行わず、仮想view内のキーを通常Windows側の同名キーとして扱いません。

セッションの応答が失われた場合は、通知された`operationId`を保持し、`prunlet --config <同じ設定の絶対パス> registry-reconcile <operation-id>`で保存済みの結果を確認してください。同じ削除を再送せず、不明なcommit結果を現在のキーの有無から推測しません。復元成功後はsnapshotを消費するため、同じ操作IDから繰り返し復元できません。

レジストリの`--dry-run`は、実削除と同じ対象・権限・再帰範囲でトランザクションへの接続も確認し、接続できない場合は失敗します。データの書込み・削除は行わず、後続の実削除の成功までは保証しません。

## 復元データの保持と自動整理

`retentionDays`（既定7日）と`maxRecoveryBytes`（既定1 GiB）はレジストリsnapshotだけに適用します。Windowsのゴミ箱はWindowsが保持・清掃し、Prunletは容量・期限・purgeの対象にしません。

旧設定で容量上限の移行印が未設定、または1未満の場合、latest導入時に一度だけ`maxRecoveryBytes`を1 GiBへ更新します。移行後の利用者による容量変更は再更新でも保持します。

`operations`はレジストリ操作IDを一覧し、`purge <registry-operation-id> [--dry-run | --apply]`と`maintain [--dry-run | --apply] [--audit-records]`もレジストリ専用です。省略時は検査のみです。削除前と明示・定期保守では、保護された記録を検査して保持条件を適用します。曖昧な記録や検証できないsnapshotは保全します。

## 旧ファイル復元データの移行

`migrate [--dry-run | --apply]`は、旧ファイルの退避データと操作記録を整理し、旧レジストリ記録を専用namespaceへ移します。**旧ファイルの復元互換は終了します。** 所有を確認できる旧ファイル領域は、形式の展開・内容hash検査・コピー・bundle化をせず、そのままWindowsのゴミ箱へ送ります。既にゴミ箱にあるファイルはWindows管理のままです。旧データを復元用に変換する処理や、元権限の参照ファイルは作りません。

インストーラーは登録と旧backend退役後に`migrate --apply --if-needed`を実行します。評価済みの中央旧領域は再走査せず、更新時には後から接続されたドライブの所有済み旧データも確認します。通常のファイル削除・一覧・保守は旧操作ディレクトリを走査しません。所有確認と再走査の設計は[DESIGN.md](DESIGN.md#旧ファイル復元データの明示移行)を参照してください。

レジストリの保全・完全ACL・非上書き復元は維持します。レジストリの痕跡がある領域、所有を確認できない領域、オフラインや権限不足の領域は警告付きで残し、ファイル整理の未完了だけでレジストリ通常操作を止めません。

中断・結果不明のファイル整理は自動再送せず、固定の空gateで停止します。元フォルダーとWindowsゴミ箱を確認した後だけ、`migrate --apply --retry-legacy-discard`で明示的に再評価してください。インストーラーはこのackを自動指定しません。移行開始後に導入が失敗した場合も、新しいexe・設定・登録を保持し、旧binaryへ戻しません。

## MCP

`prunlet --config <絶対パス> mcp`でローカルstdioサーバーを起動します。標準出力はJSON-RPC専用です。MCPプロトコルの2025-11-25・2025-06-18・2024-11-05に対応します。`delete_files`の同期削除はWindows・macOS・Linux、待機登録・照会・取消はWindows・macOSで使えます。表のほかのツールはWindows専用です。

| ツール | 引数 | 用途 |
| --- | --- | --- |
| `delete_files` | 同期: `paths`、任意の`dryRun`・`recursive`。待機登録: `action: "enqueue"`・`paths`、任意の`recursive`。照会・取消: `action: "status"` / `"cancel"`・`jobId`のみ | ファイル・フォルダーの同期削除、待機登録・照会・取消。待機登録は`dryRun`非対応 |
| `delete_registry` | `path`・`view`（`"32"`/`"64"`）、任意の`valueName`・`recursive`・`dryRun`・`accessMode` | キーまたは値を保全して削除。空の`valueName`は既定値。`accessMode`は`normal`または`backupRestore` |
| `restore_registry` | `operationId`、任意の`accessMode` | レジストリ操作を非上書きで復元。保護アクセスは復元時にも明示選択 |
| `reconcile_registry` | `operationId` | 切断後に保存済みの結果を読取り確認。削除・復元を再送しない |
| `list_operations` | なし | レジストリ操作IDの一覧（復元可否は復元時に検証） |

サーバーは削除ツールの用途を`instructions`で通知します。Windowsでは通常CLIを使い、配置済みexe・設定をCMDで安全に表現できない場合などにMCPを使えます。レジストリの`purge`は明示CLI操作です。

## Codexとの連携

Windowsの共通MCP登録、削除入力の検査、解除手順は[連携手順](docs/integration.md)を参照してください。macOSとLinuxのMCP登録例とフックの起動引数は、それぞれの導入手順を参照してください。[macOSの導入手順](docs/macos.md)・[Linuxの導入手順](docs/linux.md)

フックは認識した直接削除を拒否し、検知した命令とshellの解釈を理由として返します。shellが不明な場合は候補としての判定であり、ローカル削除と確定したものではありません。検索文字列やリモートスクリプトが拒否された場合は、[フックの検査範囲](docs/integration.md#hookの検査範囲)を確認してください。フックが案内するCLIは、許可されたホストOS上の対象の削除に使います。削除や入力の自動置換は行いません。Codex側の承認や管理ポリシーを維持します。

## 保存先の実体検証で停止する場合

MSIX版のアプリでは、AppDataの新しいフォルダーがパッケージ専用のLocalCacheへ転送される場合があります。通常ディレクトリの転送は実体へ解決して扱いますが、祖先のリンクや実体・属性を検証できない場合は停止します。エラーに示されたパスと属性を確認し、検証を無効化せず、必要ならexe・設定・復元データを`%USERPROFILE%\.local\Prunlet`などの専用ディレクトリへ配置してください。CodexパッケージのLocalCacheを復元データの恒久保存先にすることは推奨しません。

## レジストリのトランザクションが利用できない場合

`ERROR_RM_NOT_ACTIVE`（6801）などで対象hiveのトランザクションが利用できない場合は、削除をcommitせず元データを保全して停止します。同じPCでもhiveごとに利用可否が異なる場合があります。非トランザクション削除への切替や、原因未確認のOS修復は行わず、エラーと対象hive・viewを確認してください。

## 開発資料

開発時のビルドと作業規約は[AGENTS.md](AGENTS.md)、構造と設計判断は[DESIGN.md](DESIGN.md)、E2Eの実行方法と検証範囲は[検証手順](docs/verification.md)を参照してください。
