# Codexとの連携

PrunletはWindows向けCLIとstdio MCPを同じexeで提供します。Codexの`PreToolUse` hookは同じビルドから配置した独立exeで入力を検査し、認識した直接削除を拒否してCLI手順を案内します。入力の自動置換や削除は実行しません。PowerShellはMCP起動時の更新確認と導入・登録・ビルド・E2Eで使います。

## 準備

通常は[READMEのlatestインストール手順](../README.md#インストールと更新)を使います。GitHubの既定ブランチ最新HEADからソースを取得し、exe・連携スクリプト・共通指示を`%USERPROFILE%\.local\Prunlet\bin`へ配置します。`-RegisterCodex`で下記の共通登録も実行できます。ローカルクローン内のファイルを実行元に登録しません。

登録後のMCP起動時には配置済みの起動スクリプトがlatestを確認します。旧MCP・保守プロセスの使用中は切替を延期し、フック用exeは切替中も独立して動作します。更新状態・候補の所有と互換性を確認できない場合は保全し、自動再送や旧版への無条件な巻戻しを行いません。レジストリの移行が必要な更新では新しいexeで既存の明示移行を完了させ、復元記録を維持します。最初の導入・既存の旧フック定義からの移行にはCodexでのフック信頼が必要です。

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

通常はインストーラーが設定を作成します。手動の初期化は[README](../README.md#初期設定)を参照してください。`backupDirectory`は保護された共通metadata基点で、レジストリ記録を`.registry-records-v1/<operationId>`へ保存します。新しいファイル・フォルダー削除は操作記録やsnapshotを作りません。

ファイル・フォルダーは通常Windowsのゴミ箱へ移し、復元はWindowsの画面で行います。Windowsが対象をゴミ箱に対して大きすぎると判定し、元の実体を再確認できた場合は、元の名前の永久削除を試みます。削除の完了を確認できたときだけ`permanently_deleted`を返します。サイズ超過以外の失敗からは永久削除へ切り替えません。CLIの`restore`（`registry-restore`の別名）とMCPの`restore_registry`はレジストリ専用です。MCPは`delete_files`・`delete_registry`・`restore_registry`・`reconcile_registry`・`list_operations`の5ツールです。`operations`と`list_operations`にもファイル削除を載せません。

旧ファイルデータと旧レジストリ配置を扱うのは`migrate [--dry-run | --apply]`だけです。旧ファイルの復元互換は終了し、所有確認済みの旧退避rootと操作記録を本文の展開・hash・コピー・bundle化なしでWindowsゴミ箱へ破棄します。レジストリの完全保全と非上書き復元は維持します。インストーラーの`migrate --apply --if-needed`はpolicy 2評価済みの中央旧GUID走査を省き、更新時のonline owned store/restore rootの固定位置と小markerだけを確認します。通常削除・一覧・保守に旧ファイル走査を入れません。所有不明・registry signal・offline・拒否は警告して残し、file整理の未完了だけでregistry通常操作を止めません。中断gateは自動解除せず、元フォルダーとWindowsゴミ箱を確認後の`migrate --apply --retry-legacy-discard`だけで明示再評価します。設定検証は無走査・不変更の`validate-config`を使います。移行開始後の導入失敗では新exe・設定・登録を保持します。

## sandboxとゴミ箱へのアクセス

削除元への書込みが許可されても、ホストのsandbox内でWindowsゴミ箱への書込み権限を取得できるとは限りません。`delete --dry-run`はShell移動を行わないため、実処理の権限を保証しません。`COPYENGINE_E_ACCESS_DENIED_SRC`（`0x80270021`）だけから元対象のACL破損と判断せず、実行元のsandbox条件とゴミ箱へのアクセスも切り分けます。

対応するCodexの`exec_command`では、実削除を初回から`sandbox_permissions: "require_escalated"`で申請します。Windowsの管理者起動とは別の条件であり、Prunletの自動昇格や承認ポリシーの無効化はありません。対応しないホストでは正式な承認経路に従います。拒否された対象を別shell・別APIへ付け替えません。

ファイル結果は`recycled`・`permanently_deleted`・`would_recycle`・`already_absent`・`failed`・`ambiguous`です。`permanently_deleted`の元の名前はゴミ箱から復元できません。dry-runはサイズ超過の最終判定を行わず、永久削除になる可能性を警告します。`failed`・`ambiguous`は成功扱いにしません。Shell直前に対象名が差し替わると別実体がゴミ箱へ移る可能性があり、移動後の実体が一致しない場合は`ambiguous`で停止します。`ambiguous`となった削除は、許可取得だけを根拠に再送せず、CLIのJSON・元対象・Windowsのゴミ箱を確認します。ファイルの操作ID・Prunlet復元記録による照合は提供しません。レジストリ切断後は操作IDを使う`registry-reconcile`で照合し、同じ削除を再送しません。

退避先の保護では、設定された各ボリュームの保存先も実体とボリュームの対応を確認します。別ボリュームの設定先でも、権限不足や不正なリンクなどで確認できない場合は、対象外の保存先を誤って削除しないよう削除とdry-runを停止し、該当する設定パスと理由を返します。

## 使用中のファイルと同時実行

共通排他が必要な操作は`maintenance.lock`が解放されるまで待ち、取得後に続行します。この固定ロックは操作記録ではなく、競合解消のために削除しません。60秒を超える待機でも、時間だけを理由に失敗せず、待機中は元対象と復元データを保全します。保持プロセスが終了するとOSがロックを解放します。

1秒以上の待機はstderrへ経過時間を出し、以後5秒おきと取得時に通知します。CLIのstdoutは最終JSON専用です。MCPの`tools/call`に`params._meta.progressToken`を指定すると`notifications/progress`で受け取れます。最終応答後は通知を送りません。

独立したファイル対象はprocess共通のworker上限内で処理します。同一対象・親子の競合と、同じ要求内で共有するハードリンクの固定削除は排他します。別の要求やprocessに含まれる別名は、この要求内のFile ID排他の対象ではありません。MCP要求の並行数とfile worker数を区別し、registry privilege変更をfile workerと並行させません。

使用中のDLLやファイルはWindowsが移動を拒否する場合があります。Prunletはコピー・属性やACLの変更・利用プロセスの終了で拒否を回避しません。失敗や不明状態は元対象とゴミ箱を確認してください。

.NETの一時領域はビルド完了後に清掃します。標準ビルドは`-p:UseSharedCompilation=false`を指定します。共有ビルドサーバーを停止する場合は他のビルドへの影響を確認します。

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

`exec_command`系で`tool_input.shell`が`pwsh`・`powershell`・`cmd`（`.exe`や絶対パスを含む）と明示された場合は、その文字列規則を使います。`Bash`への追加property、shell未指定・未知・`bash`等の指定だけでは実行器を推測せず、複数の規則で安全側に検査します。Windowsのホストには未知shellをCMDで実行するものがあるためです。

Codexの`exec_command`はフックへ`Bash`とコマンド文字列を渡し、実行shellを渡しません。`shell: "pwsh"`だけではPowerShellと別shellを区別できないため、そのままのヒアストリングは安全側に拒否されることがあります。SSHの存在や接続先の名前を使った削除の素通し例外は設けません。

Mac等へ送るシェルスクリプトを単引用ヒアストリングに入れた**ローカルPowerShellスクリプト全体**は、shellを起動せずにUTF-16LE Base64へ変換し、単独の`pwsh -NoProfile -EncodedCommand <base64>`として渡します。たとえばCodexのJavaScript実行環境では次の形です。`script`は実際に使うローカルPowerShellスクリプトへ置き換えます。

```javascript
const script = "# Prunlet\n" + "$remote = @'\nprintf 'hello from Mac\\n'\n'@\n& 'C:\\Program Files\\Git\\usr\\bin\\ssh.exe' mac $remote";
const bytes = new Uint8Array(script.length * 2);
for (let i = 0; i < script.length; i++) {
  const unit = script.charCodeAt(i);
  bytes[i * 2] = unit & 255;
  bytes[i * 2 + 1] = unit >>> 8;
}
const encoded = bytes.toBase64();
const result = await tools.exec_command({ cmd: `pwsh -NoProfile -EncodedCommand ${encoded}`, shell: "pwsh", login: false });
text(result.output);
```

先頭のASCIIコメントはGit Bashによる先頭スラッシュのパス変換を避けます。Base64は暗号化ではないため、秘密をコマンドやログへ埋め込まないでください。フックはこの単独・無引用の形式だけを厳密に復号し、PowerShellの文字列とローカルの直接削除を検査します。認識した省略形やwrapper、動的な引数、追加コマンド、不正なBase64・UTF-16は拒否します。復号本文では、`& 'C:\Program Files\Git\usr\bin\ssh.exe'`のような完全な単引用リテラルの実行名も検査します。同じ構文でのローカル削除、`reg`、別shellや`Start-Process`の呼び出しは拒否します。引用した`reg`は動的な動詞やネイティブ引数の解釈を保証できないため、照会も含めて従来どおり拒否します。SSHへの単引用文字列・単引用ヒアストリングの引数はデータとして扱い、その前後のローカルコマンドは引き続き検査します。未対応構文（展開文字列の`$()`、ブロックコメント、ハッシュ表、スマート引用符、Unicode escape、変数・式・部分引用を使う動的な実行名、末尾に空白やドットのある実行名など）は安全側に拒否します。shell不明の元コマンドをSSH名だけで許可する例外はありません。未認識の外部wrapper・動的生成・外部スクリプト・他言語APIを含むすべての削除を検出する保証はありません。

登録するWindows hookコマンドは`<Systemのcmd.exe絶対パス> /d /c call "<exe>" --config "<config>" hook`です。Codexは環境の既定シェルをフックへ引き継ぐため、CMDを明示して`call`をCMD内で実行します。登録パスにCMD再展開文字やPowerShellの展開文字（ドル記号・バッククォート）が含まれる場合は、書込み前に自動登録を拒否します。旧`--hook-script <script>`は互換引数として受理するだけで、PowerShell backendを起動しません。更新で配置済み旧backendを退役させる際は、製品バックアップを保全してCoreによるWindowsゴミ箱への削除を使います。

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

拒否時は配置済みexe・設定で、ファイルには`delete --paths-file <absolute-json-file>`、レジストリには`registry-delete --view <32|64> [--value-name <literal-name> | --value-name=] [--recursive] -- <single-key-path>`を最初からCMDで使う手順を案内します。レジストリで成功した`operationId`を保持し、`registry-restore <operationId>`（`restore`もレジストリ専用の別名）で非上書き復元します。ファイル・フォルダーは操作IDを保存せず、`recycled`の項目だけをWindowsのゴミ箱で復元できます。MCP代替入口は`delete_registry`・`restore_registry`です。view必須、既定値の空文字、完全ACLの権限とKTMの境界は[README](../README.md#レジストリの削除復元)を参照してください。削除許可とホスト承認を維持し、拒否対象を別経路で再試行しません。hook自身は削除・自動置換・PowerShell backend起動を行いません。

MCPの1行とhookの入力全体は、UTF-16の文字数で1,048,576文字まで受理します。MCPは空白だけの行を従来どおり無視します。それ以外の超過行は残りを改行まで読み捨ててエラーを返し、次の要求を処理します。hookは上限超過を検出するとEOFを待たず拒否します。読み取り中も保持する入力をこの上限までに抑えます。

このhookは任意コードの全削除を検出する境界ではありません。動的なコマンド名、独自alias、.NETのファイルAPI、他言語のコード、外部スクリプト、エンコード済みコマンド、対話型shellへ後から送る入力などは検出対象外です。Prunletのローカル絶対パス検査・復元データ保存先の保護はCLIとMCPの入口で別途適用されます。通常の削除例とJSON一覧の制限は[README](../README.md#削除復元)を参照してください。

## レジストリの6801と起動コンテキスト

`Win32 6801`（`ERROR_RM_NOT_ACTIVE`）は、その実行コンテキストでレジストリのtransaction resource managerを利用できないことを示します。MSIX等から継承した仮想viewでも発生し得るため、番号だけでhiveの破損と判断しません。仮想view内のtransactionが利用できない場合は停止し、非transaction削除へfallbackしません。通常Windowsのレジストリを操作する場合は、以下の明示セッションを最初から選びます。

`registry-delete --dry-run`とMCPの`delete_registry`の`dryRun`も、実削除と同じ原本キー・権限・再帰範囲でtransactionへの接続を確認します。値やキーの削除をstageせず、書込み・commitは行いません。接続できない場合は`would_delete`を返さず失敗します。dry-run後の外部変更や、その後の実削除の成功までは保証しません。

切分けは次の読取りだけで行います。

1. 失敗した起動元・親process列・SID・hive・32/64 view・対象の正確な名前とnative pathを記録します。predefined hive handle、`APPMODEL_ERROR_NO_PACKAGE`、`TokenIsAppSilo=false`やtokenのvirtualization無効だけでは継承viewを区別できません。
2. 同じ起動コンテキストで対象の存在と識別情報を読み、transactional openのnative errorとrollback結果を記録します。読取りprobeには削除・修復を含めません。
3. 承認済みの独立した起動コンテキストがある場合は、同じSID・hive・view・正確な対象名で読取りを比較します。同じ文字列が別のキーを指したり不存在になったりするため、別コンテキストでの不存在を元対象の清掃成功と扱いません。識別が一致しなければ対象を同定できるまで停止します。

この切分けのためにOSのRMをresetしたり、ホストのpolicyをoverrideしたり、自動のTask Scheduler brokerを追加したりしません。起動フラグの変更でも解消しない場合があり、具体的な観測と検証範囲は[検証手順](verification.md#レジストリの削除と復元)に記録します。

## 通常Windowsのレジストリを明示して操作する

この方式は、通常Windows側のレジストリへの操作を明示して委任するためのものです。呼出元のjob・siloの制約をセッションへ引き継ぐ方式ではありません。通常デスクトップから同じexeを起動し、CLI・MCPと同じ専用設定を使います。検証用セッションは後述の固定入力による起動を使えます。サービスやタスクは登録しません。

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

起動元はパッケージ外のプロセスであることも必要です。Store版PowerShellはtransactionに接続できてもpackage identityを持つため、このセッションの起動条件を満たしません。`pwsh`という名前だけに頼らず、使用するPowerShell 7の実行ファイルを絶対パスで指定します。絶対パスやpackage identityの不在だけでnativeと判断せず、Softwareの実体とtransaction接続の検査も維持します。

検証では`scripts/Verify-RegistrySession.ps1`の`Prepare`で作った新しい隔離scopeに対し、Codexから`Start -AssertNativeWindows`を実行します。desktop ExplorerのSID・ログオンID・実tokenを確認し、hashとread handleで固定したPowerShellと検証スクリプトだけを通常・管理者の別プロセスで起動します。管理者側はWindowsの`runas`を使い、UACが表示された場合の同意は利用者が行います。表示の有無はOSのポリシーに従い、設定変更や同意の自動操作はしません。両セッションの実token・期限・nonceを照合して開始を確定し、同じscopeの`Run`が出すpermitまではfixtureを作成しません。期限切れ・取消・親の終了・二重開始・入力改変では停止し、遅れて起動したプロセスも同じ検査を受けます。手順と確認項目は[検証手順](verification.md#レジストリの削除と復元)を参照してください。手動desktop起動コマンドは診断互換として残します。

セッションはlocal接続・同じログオン・同じexeに限定し、要求ごとに呼出元をimpersonateします。管理者側は専用の管理者clientから接続します。管理者セッションへ通常clientが接続した場合も、要求はそのclientのtokenで実行し、不足する権限を補いません。UACで別のログオン識別子になったプロセスは、同じSIDでも接続を拒否します。完全ACLの保全・復元に必要な権限が呼出元になければ拒否し、セッション自身の権限を貸しません。期限後は新しい要求を受け付けず、処理中のCoreは安全に完了またはrollbackして終了します。未接続・期限切れ・設定やscopeの不一致では停止し、呼出元の仮想viewへ切り替えません。

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
