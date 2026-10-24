# Codexとの連携

PrunletはWindows向けCLIとstdio MCPを一つのexeで提供します。Codexの`PreToolUse` hookはネイティブexeだけで入力を検査し、認識した直接削除を拒否してCLI手順を案内します。入力の自動置換や削除は実行しません。PowerShellは導入・登録・ビルド・E2Eの管理スクリプトで使います。

## 準備

通常は[READMEのlatestインストール手順](../README.md#インストールと更新)を使います。GitHubの既定ブランチ最新HEADからソースを取得し、exe・連携スクリプト・共通指示を`%USERPROFILE%\.local\Prunlet\bin`へ配置します。`-RegisterCodex`で下記の共通登録も実行できます。ローカルクローン内のファイルを実行元に登録しません。

## エージェント共通指示

`-RegisterCodex -RegisterAgentInstructions`を明示すると、Codex homeの`PRUNLET.md`を配置し、共通`AGENTS.md`の先頭へ管理マーカー付きの参照と、配置済みexe・設定の絶対パスを追加します。各リポジトリへの記載は不要です。ファイル・フォルダー削除では最初から`cmd.exe`・`login: false`のPrunlet CLIを使います。空白・Unicode・多数・長い対象パスは`--paths-file`で渡します。exe・設定のパス自体をCMDで安全に表現できない場合は、実行前に同じCoreのMCPを選びます。拒否された削除を別shellやPrunletへ付け替えて再試行しません。

この登録は共通AGENTSの専用ブロックを変更するため明示オプションにしています。旧ファイル専用CLIブロックと旧MCP優先ブロックは既知の正確な内容とguideのハッシュを照合して移行します。既存本文を保持し、重複・不完全な管理マーカーや利用者が編集した指示を検出した場合は自動更新を拒否します。更新時に登録が途中で失敗した場合は、MCP・hookに加えてAGENTSと専用指示も復旧対象になります。

共通指示を登録した導入は更新時も同じオプションを渡します。オプションを省略した更新では共通指示は不変更です。その間に配置済みguideだけが更新された場合、古い共通指示を編集済みの指示と区別できないため、自動更新・解除は停止することがあります。

配置済みアプリに初めて共通指示を登録する場合は、次のhelperも利用できます。

```powershell
$bin = Join-Path $env:USERPROFILE '.local\Prunlet\bin'
$instructionBackup = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Codex\TaskArtifacts\Prunlet\instructions-' + [guid]::NewGuid().ToString('N'))
& (Join-Path $bin 'install-agent-instructions.ps1') -SourceGuidePath (Join-Path $bin 'PRUNLET.md') -ExecutablePath (Join-Path $bin 'prunlet.exe') -ConfigPath (Join-Path $env:USERPROFILE '.local\Prunlet\config.json') -BackupDirectory $instructionBackup
```

RTKの共通指示と同様、エージェントのツール選択を案内する方式です。フックによる直接削除の拒否や、将来の全呼び出しの強制とは区別してください。

## 手動の設定準備

以下は配置済みアプリを手動で設定・登録する場合の手順です。登録スクリプトと`configuration-common.ps1`は同じディレクトリに置きます。PowerShell 7の`pwsh`が必要です。

設定は中央metadataと旧コピーの保存先である`backupDirectory`から初期化します。そのディレクトリは事前に作成してください。削除対象フォルダーの事前登録は不要で、既存の設定ファイルは上書きしません。

```powershell
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
& $exe --config $config init --backup-directory 'D:\PrunletBackup'
```

設定の形式は次のとおりです。ローカルドライブ内の通常ファイル・フォルダーを扱い、復元データ保存先内は通常削除から保護します。旧`allowedRoots`・`--allowed-root`・`-AllowedRoot`は互換用に受理しますが、対象フォルダーを制限しません。

```json
{
  "schema": 1,
  "backupDirectory": "D:\\PrunletBackup"
}
```

新規ファイル・フォルダーはWindowsのゴミ箱へ移し、Prunletは操作ID・Shell項目・File ID・元のOwner/Group/DACLを記録します。ゴミ箱へ移せない場合の永久削除や独自領域へのfallbackはありません。保持期間・容量はWindowsの設定に従います。`backupDirectory`は操作記録・レジストリsnapshot・旧コピーの保存先として残します。`volumeRecoveryDirectories`は既存schema 4の復元・整理に使い、schema 6の復元中はそのbaseに`.restore`を付けた別領域で元DACLを検証してから非上書き移動します。旧schema 1〜4と、ACL snapshotのない旧schema 6の互換復元も保持します。旧schema 6は元ACLを保証できない旨をwarningsに返します。[方式の設計](../DESIGN.md#削除と復元のデータフロー)を参照してください。

復元途中で停止した場合も、同じ操作IDを指定します。ready記録のあるstageは内容の識別情報・ACL・属性を照合して再開します。readyがないstageや照合不一致は保全して停止するため、結果の`backupPath`と操作記録を保持してください。別の削除方法でstageを消したり、元パスへ手動でマージしたりしないでください。

## 使用中のファイルと同時実行

同じ復元領域を使う操作が重なった場合、Prunletは`maintenance.lock`が解放されるまで待ち、取得後に処理を続けます。大量操作で60秒を超えても、待ち時間だけを理由に失敗しません。待機中は元対象と復元データを変更しません。保持プロセスが終了するとOSがロックを解放します。待機自体を中止する場合はCLIを通常の方法で終了できます。ロックファイルは通常運用でも残るため、競合の解消を目的に削除しないでください。

1秒以上待つ場合は、stderrへ待機中の経過時間を出し、以後5秒おきとロック取得時にも通知します。これは処理状況の案内で、失敗を意味しません。CLIのstdoutは最終結果のJSONだけなので、成否は終了コードと結果JSONで判断してください。MCPクライアントは`tools/call`の`params._meta.progressToken`に文字列・整数を指定すると、同じ状況を`notifications/progress`で受け取れます。表示方法はクライアントによります。

ロード中のDLLや使用中のファイルは、容量走査や移動用ハンドルの取得、renameをWindowsが拒む場合があります。新規操作はコピーを作らず、属性やアクセス権限を変更して拒否を回避しません。失敗時は結果と操作IDを確認し、中断して退避済みの実体がある場合はその記録を保持してください。旧コピー形式の整理にある削除保留の待機と、新規renameの可否は別の検証です。

.NETの一時領域を清掃する場合は、そのビルド処理が終わったことを確認してください。Prunletの標準ビルドは`-p:UseSharedCompilation=false`を指定し、共有コンパイラーによる一時DLLの保持を防ぎます。ほかの専用ビルドでも`-p:UseSharedCompilation=false -nodeReuse:false`を指定できます。共有ビルドサーバーを終了する場合は、他のビルドへの影響も確認してください。Prunletが利用プロセスを自動終了することはありません。

## 登録

```powershell
$bin = Join-Path $env:USERPROFILE '.local\Prunlet\bin'
$rollback = Join-Path $env:LOCALAPPDATA 'Codex\TaskArtifacts\Prunlet\integration-backup'
& (Join-Path $bin 'install-codex.ps1') `
  -ExecutablePath (Join-Path $bin 'prunlet.exe') `
  -ConfigPath (Join-Path $env:USERPROFILE '.local\Prunlet\config.json') `
  -BackupDirectory $rollback
```

既定の登録先は`CODEX_HOME`、未指定なら`%USERPROFILE%\.codex`です。`-CodexHome <絶対パス>`で隔離した設定先も指定できます。`hooks.json`の既存entryは保持し、Prunletのhandlerだけを追加します。`config.toml`には`[mcp_servers.prunlet]`と必要な`features.hooks = true`を追記します。既存の同名MCP、異なるPrunlet登録、明示的な`features.hooks = false`があれば書込み前に停止します。

設定ファイルの上書き前に、`-BackupDirectory`へ元ファイルと復元記録を保存します。この保存先はCodexHome、ユーザーの`.codex`、リポジトリの外に置いてください。Prunletの削除バックアップとは別の用途です。変更対象の`features`と`mcp_servers`にquoted key、表名の内部空白、dotted root keyがある場合や、複数行文字列を含むTOMLは、既存値を保持するため自動更新を拒否します。その場合は手動登録が必要です。プロジェクトのtrust tableなど、変更対象以外のquoted tableは保持します。設定ファイルの更新中にI/Oエラーが起きた場合は、表示された保存先の復元記録を確認してください。

フックの登録後はCodexで`/hooks`を開き、Prunlet hookの定義を確認して信頼してください。`install-codex.ps1`はhookのtrust記録やAGENTS.mdを変更しません。共通AGENTSを変更するのは上記の明示オプションです。Codexを再起動してMCP・共通指示・hookの読込みを確認します。

MCP登録の実行内容は次のとおりです。

```powershell
& $exe --config $config mcp
```

## hookの検査範囲

対応するtool名は`Bash`、`exec_command`、`functions.exec_command`です。入力は`tool_input.command`または`tool_input.cmd`を読みます。対象外toolや削除候補のないshell入力にはexe単体で`{}`を返します。認識した直接ファイル削除は理由とPrunlet CLI手順を付けて拒否し、入力の自動置換を行いません。

登録するWindows hookコマンドは`<Systemのcmd.exe絶対パス> /d /c call "<exe>" --config "<config>" hook`です。Codexは環境の既定シェルをフックへ引き継ぐため、CMDを明示して`call`をCMD内で実行します。登録パスにCMD再展開文字やPowerShellの展開文字（ドル記号・バッククォート）が含まれる場合は、書込み前に自動登録を拒否します。旧`--hook-script <script>`は互換引数として受理するだけで、PowerShell backendを起動しません。更新で配置済み旧backendを退役させる際は、製品バックアップを保全してCoreによるバックアップ付き削除を使います。

| 入力 | 結果 |
| --- | --- |
| 認識した`Remove-Item`・削除alias・CMDの`del` / `erase`によるファイル削除 | 拒否してCLI手順を案内 |
| レジストリを含む`Remove-Item`・既定alias、`Remove-ItemProperty`・`rp` | 拒否して専用CLIを案内 |
| `reg delete`・`reg.exe delete` | 拒否して専用CLIを案内 |
| 読み取れるwrapper内のファイル削除・レジストリとファイルの混在 | 拒否。各文を個別に検査する |
| 削除候補のない入力、Prunlet CLI自身 | 通過 |
| 未知のshell | 自動置換しない。検出可能な直接削除は拒否 |
| 不正なhook JSON、入力検査の失敗 | 理由を付けて拒否 |

フックはstdoutにJSONだけを返し、診断はstderrへ出します。Codexの既存の承認・安全設定・他hookの判定を変更しません。

レジストリ限定の素通し例外はありません。認識した`Remove-Item`・既定alias、`Remove-ItemProperty`・`rp`と`reg[.exe] delete`を拒否します。`reg query`や`echo`の引数にある無関係なコマンド文字列は通過します。既存のwrapper・escape検出を維持します。`{}`は実行許可ではなく、他hookとホストの承認へ判断を委ねる応答です。

拒否時は配置済みexe・設定で、ファイルには`delete --paths-file <absolute-json-file>`、レジストリには`registry-delete --view <32|64> [--value-name <literal-name> | --value-name=] [--recursive] -- <single-key-path>`を最初からCMDで使う手順を案内します。成功した`operationId`を保持し、共通`restore <operationId>`で非上書き復元します。MCP代替入口は`delete_registry`・`restore_registry`です。view必須、既定値の空文字、完全ACLの権限とKTMの境界は[README](../README.md#レジストリの削除・復元)を参照してください。削除許可とホスト承認を維持し、拒否対象を別経路で再試行しません。hook自身は削除・自動置換・PowerShell backend起動を行いません。

MCPの1行とhookの入力全体は、UTF-16の文字数で1,048,576文字まで受理します。MCPは空白だけの行を従来どおり無視します。それ以外の超過行は残りを改行まで読み捨ててエラーを返し、次の要求を処理します。hookは上限超過を検出するとEOFを待たず拒否します。読み取り中も保持する入力をこの上限までに抑えます。

このhookは任意コードの全削除を検出する境界ではありません。動的なコマンド名、独自alias、.NETのファイルAPI、他言語のコード、外部スクリプト、エンコード済みコマンド、対話型shellへ後から送る入力などは検出対象外です。Prunletのローカル絶対パス検査・復元データ保存先の保護はCLIとMCPの入口で別途適用されます。通常の削除例とJSON一覧の制限は[README](../README.md#削除・復元)を参照してください。

## レジストリの6801と起動コンテキスト

`Win32 6801`（`ERROR_RM_NOT_ACTIVE`）は、その実行コンテキストでレジストリのtransaction resource managerを利用できないことを示します。MSIX等から継承した仮想viewでも発生し得るため、番号だけでhiveの破損と判断しません。仮想view内のtransactionが利用できない場合は停止し、非transaction削除へfallbackしません。通常Windowsのレジストリを操作する場合は、以下の明示セッションを最初から選びます。

切分けは次の読取りだけで行います。

1. 失敗した起動元・親process列・SID・hive・32/64 view・対象の正確な名前とnative pathを記録します。predefined hive handle、`APPMODEL_ERROR_NO_PACKAGE`、`TokenIsAppSilo=false`やtokenのvirtualization無効だけでは継承viewを区別できません。
2. 同じ起動コンテキストで対象の存在と識別情報を読み、transactional openのnative errorとrollback結果を記録します。読取りprobeには削除・修復を含めません。
3. 承認済みの独立した起動コンテキストがある場合は、同じSID・hive・view・正確な対象名で読取りを比較します。同じ文字列が別のキーを指したり不存在になったりするため、別コンテキストでの不存在を元対象の清掃成功と扱いません。識別が一致しなければ対象を同定できるまで停止します。

この切分けのためにOSのRMをresetしたり、ホストのpolicyをoverrideしたり、自動のTask Scheduler brokerを追加したりしません。起動フラグの変更でも解消しない場合があり、具体的な観測と検証範囲は[検証手順](verification.md#レジストリの削除と復元)に記録します。

## 通常Windowsのレジストリを明示して操作する

この方式は、利用者が通常Windows側のレジストリへの操作を明示して委任するためのものです。呼出元のjob・siloの制約をセッションへ引き継ぐ方式ではありません。利用者が通常デスクトップから同じexeを起動し、CLI・MCPと同じ専用設定を使います。Prunletはセッションを自動起動・昇格せず、サービスやタスクも登録しません。

設定へ次の2項目を追加します。`registrySessionFile`は、通常のローカルディレクトリ内の未使用の絶対パスを指定します。セッションの接続情報は本人とSYSTEMだけが読めるACLで作成するため、内容を共有・ログ出力しないでください。期限後も接続情報は残り、同じファイルを上書きしません。次の起動には別の未使用パスを設定するか、終了を確認してからPrunletで古い接続情報を明示清掃します。

```json
{
  "schema": 1,
  "backupDirectory": "D:\\PrunletBackup",
  "registryScope": "nativeWindows",
  "registrySessionFile": "D:\\PrunletSession\\native-session.json"
}
```

1. 通常デスクトップのターミナルで、`prunlet --config <同じ設定の絶対パス> registry-session --minutes 15 --assert-native-windows`を起動します。期限は1〜60分です。起動時にSoftwareのnative pathとtransaction接続を確認し、MSIX由来の仮想viewでの誤起動を拒否します。
2. Codexから同じexe・設定で、通常の`registry-delete`・`restore`、またはMCPの`delete_registry`・`restore_registry`を使います。dry-runも同じセッションで行います。ファイル操作は従来どおり呼出元で実行します。
3. 接続が切れた場合は、通知された`operationId`を保持してCLIの`registry-reconcile <operationId>`、またはMCPの`reconcile_registry`で記録を確認します。削除要求を自動で再送しません。

セッションはlocal接続・同じログオン・同じexeに限定し、要求ごとに呼出元をimpersonateします。セッションとCLI・MCPは通常同士、または利用者が明示起動した管理者同士で使います。UACで別のログオン識別子になったプロセスは、同じSIDでも接続を拒否します。完全ACLの保全・復元に必要な権限が呼出元になければ拒否し、セッション自身の権限を貸しません。期限後は新しい要求を受け付けず、処理中のCoreは安全に完了またはrollbackして終了します。未接続・期限切れ・設定やscopeの不一致では停止し、呼出元の仮想viewへ切り替えません。

native scopeのmachine・SID・32/64 viewを復元記録とsnapshotへ結び付け、復元も同じscopeに限定します。scopeのない旧記録をnativeと推定しません。`registryScope`を省略した設定は従来の呼出元viewを使い、native記録をそこで復元することはできません。

## 解除と復元

自動整理のWindowsタスクはCodex連携とは独立しています。次のCodex登録解除でも維持されます。タスクだけを解除する場合は、配置済み`uninstall-maintenance.ps1`へ同じexe・設定を渡します。解除後も実削除時の自動整理は行われますが、使っていない間の期限切れ整理は行われません。

```powershell
& (Join-Path $bin 'uninstall-maintenance.ps1') -ExecutablePath $exe -ConfigPath $config
```

```powershell
& (Join-Path $bin 'uninstall-codex.ps1') -ExecutablePath $exe -ConfigPath $config -BackupDirectory $rollback
```

隔離先へ登録した場合は同じ`-CodexHome`を渡します。exeや設定を標準配置以外へ置いた場合も、登録時と同じ`-ExecutablePath`・`-ConfigPath`を渡します。Prunlet handlerと専用マーカー内のMCP設定、Prunletが追加したhook機能設定を解除し、他のhook・MCP・設定を保持します。共通指示を登録済みの場合は、所有するAGENTS参照と専用guideも検証して解除します。利用者の編集があれば書込み前に停止します。同じ操作を繰り返しても登録は増えません。解除はexe、Prunlet設定、削除バックアップを残します。

専用マーカー内を編集した場合や、MCPマーカーの末尾から次のtableまでに利用者の値を追加した場合は、所属tableを保持するため書込み前に自動解除を停止します。内容を確認してから手動でPrunlet部分だけを解除してください。復元が必要なら、保存された記録の`target`、`backup`、`existed`を確認し、現在の変更を保全して元ファイルを戻します。記録は連携の検証と復元の必要がなくなった時点で清掃できます。
