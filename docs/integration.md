# Codexとの連携

PrunletはWindows向けCLIとstdio MCPを一つのexeで提供します。Codexの`PreToolUse` hookはexeの高速判定入口を呼び、削除候補だけPowerShell AST helperで解析します。対応するPowerShell削除を通常のshell tool上のPrunlet CLI呼出しに置き換え、hook自身は削除処理を実行しません。

## 準備

通常は[READMEのlatestインストール手順](../README.md#インストールと更新)を使います。GitHubの既定ブランチ最新HEADからソースを取得し、exeと4つの連携スクリプトを`%USERPROFILE%\.local\Prunlet\bin`へ配置します。`-RegisterCodex`で下記の共通登録も実行できます。ローカルクローン内のファイルを実行元に登録しません。

以下は配置済みアプリを手動で設定・登録する場合の手順です。登録スクリプトと`configuration-common.ps1`は同じディレクトリに置きます。PowerShell 7の`pwsh`が必要です。

設定は明示的な許可ルートと削除バックアップ先から初期化します。両ディレクトリは事前に作成してください。既存の設定ファイルは上書きしません。

```powershell
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
& $exe --config $config init --allowed-root 'C:\work\project' --backup-directory 'D:\PrunletBackup'
```

設定の形式は次のとおりです。許可ルートは必要な範囲だけを指定します。

```json
{
  "schema": 1,
  "allowedRoots": ["C:\\work\\project"],
  "backupDirectory": "D:\\PrunletBackup"
}
```

## 登録

```powershell
$bin = Join-Path $env:USERPROFILE '.local\Prunlet\bin'
$rollback = Join-Path $env:LOCALAPPDATA 'Codex\TaskArtifacts\Prunlet\integration-backup'
& (Join-Path $bin 'install-codex.ps1') `
  -ExecutablePath (Join-Path $bin 'prunlet.exe') `
  -ConfigPath (Join-Path $env:USERPROFILE '.local\Prunlet\config.json') `
  -HookPath (Join-Path $bin 'codex-pretooluse.ps1') `
  -BackupDirectory $rollback
```

既定の登録先は`CODEX_HOME`、未指定なら`%USERPROFILE%\.codex`です。`-CodexHome <絶対パス>`で隔離した設定先も指定できます。`hooks.json`の既存entryは保持し、Prunletのhandlerだけを追加します。`config.toml`には`[mcp_servers.prunlet]`と必要な`features.hooks = true`を追記します。既存の同名MCP、異なるPrunlet登録、明示的な`features.hooks = false`があれば書込み前に停止します。

設定ファイルの上書き前に、`-BackupDirectory`へ元ファイルと復元記録を保存します。この保存先はCodexHome、ユーザーの`.codex`、リポジトリの外に置いてください。Prunletの削除バックアップとは別の用途です。変更対象の`features`と`mcp_servers`にquoted key、表名の内部空白、dotted root keyがある場合や、複数行文字列を含むTOMLは、既存値を保持するため自動更新を拒否します。その場合は手動登録が必要です。プロジェクトのtrust tableなど、変更対象以外のquoted tableは保持します。設定ファイルの更新中にI/Oエラーが起きた場合は、表示された保存先の復元記録を確認してください。

登録後はCodexで`/hooks`を開き、Prunlet hookの定義を確認して信頼してください。登録スクリプトはhookのtrust記録やAGENTS.mdを変更しません。Codexを再起動してMCPとhookの読込みを確認します。

MCP登録の実行内容は次のとおりです。

```powershell
& $exe --config $config mcp
```

## hookの変換範囲

対応するtool名は`Bash`、`exec_command`、`functions.exec_command`です。入力は`tool_input.command`または`tool_input.cmd`を読み、その他の引数を保持します。対象外toolや削除候補のないshell入力にはexe単体で`{}`を返し、PowerShell起動を省きます。削除候補は既存のAST helperで解析します。

登録されるWindows hookコマンドは`call "<exe>" --config "<config>" hook --hook-script "<script>"`です。CodexのWindows command hook runnerで使うcmdの内部`call`により、空白を含むexeパスを扱います。登録パスにcmd再展開文字`%`、`!`、`^`、`&`などが含まれる場合は自動登録を拒否します。

| 入力 | 結果 |
| --- | --- |
| 単独の`Remove-Item -LiteralPath 'C:\work\a.txt'` | Prunlet CLIへ置換 |
| `Microsoft.PowerShell.Management\Remove-Item`、`ri`、`rm`、`del`、`erase` | 同じ限定構文であれば置換 |
| `-LiteralPath 'C:\work\a.txt','C:\work\b.txt'` | 定数文字列の配列として置換 |
| `-Force`、`-ErrorAction Stop` | 対応。CLI自身の方針で処理 |
| `-WhatIf` | `delete --dry-run`へ置換 |
| 相対パス、変数、式、`*`や`?`、`-Path`、`-Recurse` | 実行前に拒否 |
| 複数文、パイプ、リダイレクト、呼出し演算子による削除 | 実行前に拒否 |
| 代表的なcmd/pwsh/PowerShell wrapper内で読み取れる直接削除 | 実行前に拒否 |
| 不正なhook JSON、識別済み削除の解析失敗、exe/config不在 | 理由を付けて拒否 |

角括弧を含むファイル名は`-LiteralPath`で文字どおり扱います。例では次のように置換されます。

```powershell
Remove-Item -LiteralPath 'C:\work\a[1].txt' -WhatIf
# 通常のshell toolへ返すコマンド
& 'C:\Users\IMT\AppData\Local\Prunlet\bin\prunlet.exe' --config 'C:\Users\IMT\AppData\Local\Prunlet\config.json' delete --dry-run -- 'C:\work\a[1].txt'
```

hookはPowerShell AST上の直接コマンド名を調べます。文字列に`Remove-Item`という単語があるだけでは削除とみなしません。Prunlet CLI自身も再変換しません。出力はstdoutにJSONだけ、診断はstderrです。`allow`と`updatedInput`による置換はCodexの正式なhook契約を使い、既存の承認・安全設定・他hookの判定を変更しません。[Codex公式hook仕様](https://learn.chatgpt.com/docs/hooks)

このhookは任意コードの全削除を検出する境界ではありません。動的なコマンド名、独自alias、.NETのファイルAPI、他言語のコード、外部スクリプト、エンコード済みコマンド、対話型shellへ後から送る入力などは検出対象外です。PowerShell以外のshellで同じ名前が別の意味を持つ場合も自動変換できません。Prunletの許可ルート・パス検査はCLIとMCPの入口で別途適用されます。

## 解除と復元

```powershell
& (Join-Path $bin 'uninstall-codex.ps1') -BackupDirectory $rollback
```

隔離先へ登録した場合は同じ`-CodexHome`を渡します。Prunlet handlerと専用マーカー内のMCP設定、Prunletが追加したhook機能設定を解除し、他のhook・MCP・設定を保持します。同じ操作を繰り返しても登録は増えません。解除はexe、Prunlet設定、削除バックアップを残します。

専用マーカー内を編集した場合や、MCPマーカーの末尾から次のtableまでに利用者の値を追加した場合は、所属tableを保持するため書込み前に自動解除を停止します。内容を確認してから手動でPrunlet部分だけを解除してください。復元が必要なら、保存された記録の`target`、`backup`、`existed`を確認し、現在の変更を保全して元ファイルを戻します。記録は連携の検証と復元の必要がなくなった時点で清掃できます。
