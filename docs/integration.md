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

設定は復元データの保存先から初期化します。そのディレクトリは事前に作成してください。削除対象フォルダーの事前登録は不要で、既存の設定ファイルは上書きしません。

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

## 使用中のファイルと同時実行

同じ復元領域を使う操作が重なった場合、Prunletは`maintenance.lock`が解放されるまで待ち、取得後に処理を続けます。大量操作で60秒を超えても、待ち時間だけを理由に失敗しません。待機中は元対象と復元コピーを変更しません。保持プロセスが終了するとOSがロックを解放します。待機自体を中止する場合はCLIを通常の方法で終了できます。ロックファイルは通常運用でも残るため、競合の解消を目的に削除しないでください。

1秒以上待つ場合は、stderrへ待機中の経過時間を出し、以後5秒おきとロック取得時にも通知します。これは処理状況の案内で、失敗を意味しません。CLIのstdoutは最終結果のJSONだけなので、成否は終了コードと結果JSONで判断してください。MCPクライアントは`tools/call`の`params._meta.progressToken`に文字列・整数を指定すると、同じ状況を`notifications/progress`で受け取れます。表示方法はクライアントによります。

ロード中のDLLは、ファイルの読み取りとバックアップに成功してもWindowsが削除を拒む場合があります。Prunletは同じ検証済みハンドルで最大10秒待ち、解放されれば削除を続けます。解放されなければ失敗を返し、残った元対象と復元コピーを保持します。読み取り専用ファイルは、元の属性を書き換えずにWindowsの対応APIで削除し、復元時に元の通常属性へ戻します。アクセス権限は変更しません。

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

対応するtool名は`Bash`、`exec_command`、`functions.exec_command`です。入力は`tool_input.command`または`tool_input.cmd`を読みます。対象外toolや削除候補のないshell入力にはexe単体で`{}`を返します。認識した直接削除は理由とPrunlet CLI手順を付けて拒否し、入力の自動置換を行いません。

登録するWindows hookコマンドは`<Systemのcmd.exe絶対パス> /d /c call "<exe>" --config "<config>" hook`です。Codexは環境の既定シェルをフックへ引き継ぐため、CMDを明示して`call`をCMD内で実行します。登録パスにCMD再展開文字やPowerShellの展開文字（ドル記号・バッククォート）が含まれる場合は、書込み前に自動登録を拒否します。旧`--hook-script <script>`は互換引数として受理するだけで、PowerShell backendを起動しません。更新で配置済み旧backendを退役させる際は、製品バックアップを保全してCoreによるバックアップ付き削除を使います。

| 入力 | 結果 |
| --- | --- |
| 認識した`Remove-Item`・削除alias・CMDの`del` / `erase` | 拒否してCLI手順を案内 |
| 読み取れるwrapper内の直接削除・削除を含む複数文 | 拒否。別shellへの付け替えはしない |
| 削除候補のない入力、Prunlet CLI自身 | 通過 |
| 未知のshell | 自動置換しない。検出可能な直接削除は拒否 |
| 不正なhook JSON、入力検査の失敗 | 理由を付けて拒否 |

フックはstdoutにJSONだけを返し、診断はstderrへ出します。Codexの既存の承認・安全設定・他hookの判定を変更しません。

MCPの1行とhookの入力全体は、UTF-16の文字数で1,048,576文字まで受理します。MCPは空白だけの行を従来どおり無視します。それ以外の超過行は残りを改行まで読み捨ててエラーを返し、次の要求を処理します。hookは上限超過を検出するとEOFを待たず拒否します。読み取り中も保持する入力をこの上限までに抑えます。

このhookは任意コードの全削除を検出する境界ではありません。動的なコマンド名、独自alias、.NETのファイルAPI、他言語のコード、外部スクリプト、エンコード済みコマンド、対話型shellへ後から送る入力などは検出対象外です。Prunletのローカル絶対パス検査・復元データ保存先の保護はCLIとMCPの入口で別途適用されます。通常の削除例とJSON一覧の制限は[README](../README.md#削除・復元)を参照してください。

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
