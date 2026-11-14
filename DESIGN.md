# Prunletの設計

Prunletは、AIエージェントに許可されたファイル・フォルダー削除をCLIとMCPへ集約し、共通の検証経路で処理する。Windows x64・ARM64、Apple Silicon Mac、Linux x64・ARM64では、通常のファイル削除をOSのゴミ箱へ委ね、Prunletの復元用記録を残さない。Windowsは条件を限定したファイルの永久削除と、snapshot・トランザクションを使うレジストリ削除・復元も扱う。利用手順は[README](README.md)、連携は[Windows](docs/integration.md)・[macOS](docs/macos.md)・[Linux](docs/linux.md)の導入手順、検証は[検証手順](docs/verification.md)を参照する。

## 構成と責務

製品コードは`src/rust`のRust実装で、ワークスペースの正本は[`Cargo.toml`](Cargo.toml)である。[MSVCターゲットの設定](.cargo/config.toml)でCランタイムを静的リンクし、Windowsの製品exeの実行に.NETランタイムやVCランタイムの追加導入を求めない。

- `service::Runtime`がCLIとMCPの共通実行境界となり、ファイルを`files`、レジストリと明示移行を`registry`、起動時更新の内部要求を`update`へ渡す。旧ファイルの明示移行は`registry::migration`から`migration`へ委譲する。
- `cli`はCLIの入力検証とJSON出力、`protocol::mcp`はstdio JSON-RPCを担当する。MCPは各OSで`delete_files`を公開し、Windowsでは`delete_registry`・`restore_registry`・`reconcile_registry`・`list_operations`も公開する。`--config <path> mcp`として起動した場合は、起動前・引数検証の例外もstderrへ出してプロトコルstdoutを保つ。他のCLIでは例外をstdoutのJSONで返し、値名などの引数に`mcp`が含まれるだけでは出力先を変えない。
- `protocol::hook`は認識した直接削除を検査・拒否し、配置済みCLIを案内する。Windowsの専用入口`prunlet-hook.exe`はCLIと同じバイナリを別名で配置する。macOSとLinuxは`prunlet --config <path> hook`で同じ実行ファイルを使う。ホストの承認・管理ポリシーを維持し、削除の自動代行や自動昇格を行わない。
- `prunlet-maintenance.exe`は同じCoreをGUI subsystemで発行した定期保守入口で、`--config <path> maintain --apply`だけを受け付ける。コンソールを作らずにレジストリ復元データを整理する。
- `platform::windows`がパス・実体・ACLの照合やWindows Shellとの接続を担当する。ゴミ箱からの復元と保持期間の管理はWindowsに委ねる。Prunletはファイル復元APIや通常の履歴圧縮入口を提供しない。
- `platform::macos`がファイルパスと実体の照合、FoundationのTrash呼び出し、Mach IPCによる待機キュー、署名済み実行ファイルの導入と起動時更新を担当する。
- `platform::linux`がfdを使ったパスと実体の検証、freedesktopのホームTrashへの同期移動、単一実行ファイルの起動時更新を担当する。macOSとLinuxはGitHub Releaseの候補選定と取得を`update::github`で共有する。
- Windows向けの`integration/`のPowerShellスクリプトはCodex登録、MCP起動時更新の調停、定期保守タスクの登録を担当する。製品Coreの削除処理は持たない。

権限の境界はホストのsandbox承認、Windowsの実トークン、Prunlet Coreの対象検証に分かれる。Prunlet自身は自動昇格しないが、許可された削除についてエージェントが明示的に管理者CMDを起動し、同じ配置済みCLIと設定を使う連携は別の責務である。起動成功だけを削除成功とは扱わず、拒否・結果不明を昇格で迂回しない。起動と結果確認の手順は[連携手順](docs/integration.md#sandboxとゴミ箱へのアクセス)に集約する。

`protocol::bounded_input`はhookとstdio MCPで入力のUTF-8とUTF-16コード単位数の上限を検査する。hookは不正なUTF-8や上限超過を検出した時点で拒否し、入力の終了を待たない。MCPは有効なUnicode空白だけの行を上限超過時も読み飛ばし、次の要求を処理する。不正なUTF-8の行は区切りまで消費し、`id`が`null`のparse error（-32700）で拒否して継続する。この種別は入力検査由来の`InvalidData`だけで、stdin読取り自体の失敗は従来どおりMCPを終了する。

### フックのshell解析境界

`protocol::hook`は`Bash`・`exec_command`・`functions.exec_command`のコマンド文字列を検査する。`exec_command`系の明示的な`tool_input.shell`がPowerShellまたはCMDなら、その文字列規則を選択する。shell未指定・未知・Posix系の指定、および`Bash`ではCMD・PowerShell・Posixの複数規則で検査する。未知shellをCMDで実行するWindowsホストがあるため、tool名やshell名だけからPosix実行とは推測しない。静的なshell wrapperのコマンド本文も再帰検査し、認識したPowerShell・CMDのwrapperには対応する規則を使う。

拒否理由の検知情報と解析中のshell規則は`protocol::hook`の要求ごとの`Inspector`に保持する。検知した命令・オプションと、その検知に使ったshell解釈を応答へ含め、検査不能な入力には原因を返す。shell未指定・未知の場合は候補の解釈であることを明示し、ローカル削除と断定しない。検索文字列やリモートスクリプトの引用も別shellでは命令になり得るため、CLI案内は許可されたホストOS上の対象に限定する。応答形式と利用時の扱いは[連携手順](docs/integration.md#hookの検査範囲)を参照する。

CMD規則では`#`をコメントとして扱わず、後続のコマンド区切り以降も検査する。静的な`IF`は`/i`・`not`、`exist`・`defined`・`errorlevel`・`cmdextversion`、`==`と`EQU/NEQ/LSS/LEQ/GTR/GEQ`の条件直後のコマンドを検査する。条件の真偽は評価せず、比較値や`echo`の引数を削除コマンドとは扱わない。wrapper本文の再構成では、引用内の`==`と引用外の比較演算子、空の引用文字列を区別して保つ。`cmd`のswitchは先頭`/`の重複（Git Bashの`//c`等）と大文字小文字を正規化し、`/C`・`/K`・`/R`、連結形、switchに直結した本文を本文として再検査する。本文より前の未知switchは検査不能として拒否する。括弧なしで`do`・`else`の直後に続くコマンドも`IF`と同様に検査する。静的wrapperの入れ子が深さ上限を超えた場合は、shell規則によらず拒否する。

削除と無関係な定型構文は、検査不能として一律に拒否せず、データと確定できる範囲だけを読み飛ばす。POSIX規則では、終端語を引用したヒアドキュメントの本文のうち、受け取る文が静的なパスへ書き出す`cat`、またはoptionだけを付けたインタプリタ起動の場合に限り、本文をdataとして扱う。パイプ・同じ行の後続文・入れ子の展開・shell起動・終端語を引用しない本文は、従来どおり文として検査する。PowerShellのEncodedCommandでは、変数・プロパティ参照・数値添字だけの`"$(...)"`と、静的な`.ps1`を`-File`で実行するpwshだけを通す。コマンド位置の`.`はdot-sourcingとして拒否するが、同じ行で直前のコマンドへ引数として渡す単独の`.`（`rg x .`・`git grep x -- .`）は、文境界・キーワード直後・動的な語の後を除いて通す。検知していない拒否は、原因と書き換え方だけを短く返す。

PowerShellの`Start-Process`は原則拒否し、共通指示が定める管理者CMD起動の固定形だけを許可リストで照合して通す。起動先は静的な`cmd.exe`、引数は配置済みCLI・同じ設定・限定文字の引数・`.json`出力先に全体一致する単一の文字列とし、CMDの演算子・引用・展開を持ち込めない形にして、引数文字列のCMD再解析による解釈差を避ける。これは起動制御だけの例外であり、実削除は起動先CMD内の配置済みCLIが行う。固定形の詳細は[連携手順](docs/integration.md#sandboxとゴミ箱へのアクセス)に集約する。

PowerShellのヒアストリングは行頭の終端までを文字列として読み、終端前後のローカルコマンドを検査する。代入右辺、`return`・`throw`・`exit`の後続、dot呼出しの実行名は、EncodedCommandの限定検査に限らずPowerShell規則全体でコマンドとして検査する。Codexの実ホストは`exec_command`を`Bash`として渡し、実行shellをフック入力に含めない。同じ文字列がshellによって実行コードにもデータにもなるため、shell不明のままPowerShellとは決め打ちしない。単独の静的な`pwsh -NoProfile -EncodedCommand <canonical UTF-16LE Base64>`は復号してPowerShellとして限定検査し、未対応の動的呼出し・展開・別shell等は拒否する。復号本文の完全な単引用リテラルを使った`&`呼出しは実行名へ戻して同じ削除・wrapper検査へ渡し、引数や前後のローカル処理の検査を続ける。認識した省略形やwrapperは限定形式として扱わず、不正・未終端のヒアストリングも拒否する。SSHの存在や接続先による素通し例外は設けない。未認識の外部wrapper、外部scriptの内容・動的なコマンド名・他言語のAPIまで検査する保証はない。利用時の書き方は[連携手順](docs/integration.md)、解析の実プロセス検証は[検証手順](docs/verification.md#通常e2eの検証範囲)を参照する。

## 削除と復元のデータフロー

Windowsでは、入力パスを正規化し、対象・祖先・保護領域・リンクを検証する。全対象のpreflightを終えてからWindowsゴミ箱へ移す。末尾名がWindows予約名の実在する通常ファイル（非ディレクトリ・非reparse）だけは、追加確認やShell試行をせず固定ハンドルで永久削除する。予約名の祖先・ディレクトリ・リンクはこの例外に含めない。通常名の対象は、Windowsが対象を大きすぎると明示した場合、またはゴミ箱利用不可を返し対象ボリュームの即時削除設定を確認できた場合で、生成先や別原因の失敗がなく、保持した元実体と再固定した名前・親・属性が一致した場合だけ、同じ要求内で対象名を永久削除する。即時削除設定は、Shell応答が0x80270036で生成先や別原因の失敗がなく、実効ユーザーSIDと対象ボリュームGUIDに対応するNukeOnDeleteがDWORDの1で、user/machineのNoRecycleFilesポリシー値が存在しない場合だけ受理する。設定はShell前後と各固定削除直前に再照合し、不明・不一致は保全する。NukeOnDeleteは公開API契約ではなく、設定を原子的に固定できないため、確認直後の変更やABA競合は排除できない。フォルダーの進捗通知は失敗と扱わない。その他の失敗・不明状態からは永久削除へ切り替えない。再帰指定のない非空フォルダーは拒否し、リンク先を走査しない。独自退避・別ボリュームへのコピー・自動昇格は行わない。

Shellが削除元を8.3短縮名で返した場合、非reparseの対象だけを`platform::windows::path::resolve`で解決し、入力の正規名と大小文字を含めて完全一致する場合に受理する。親・元実体・属性の再照合も続ける。同じFile IDの別ハードリンク名を誤って受理しないため、IDの一致だけには緩和しない。受理した別名はFileFailure通知の照合にも正規名と並べて使うが、通知の物理パスとの完全一致だけを認め、食い違えば結果不明へ倒す。パス検査で拒否する制御文字はNULとU+0001〜U+001Fに限り、DELとC1制御文字はWin32で正当な名前になり得るため受理する。

新規ファイル削除では、操作ID・PIDL・File ID・内容hash・size・ACL snapshotを復元用に永続化しない。manifest・monitor・index・retirement・復元stageも作成しない。処理中の安全確認に使う情報と永続的な操作記録を区別する。共通の`maintenance.lock`は排他制御用の固定ファイルであり、操作記録ではない。

互換入力の`volumeRecoveryDirectories`は、各エントリの値を保護領域として評価する。値のドライブrootが存在しないと確認できた（Win32 2・3）エントリだけは、その上に今回の対象が存在し得ないため評価から除外し、結果の`warnings`へ出す。ドライブ未準備（21）・不正な形・権限などで確認できない失敗は従来どおり検証失敗（fail-closed）とし、値が存在するボリューム上にありキーが別ボリュームを指す設定も拒否する。取り外したドライブの設定が無関係なボリューム上の削除まで止めないための扱いで、`migrate`のstore位置判定は変えず、存在しない値を従来どおり利用不可として扱う。

再帰永久削除の子の照合では、列挙値のFile ID・属性を開いた実体と照合し、時刻の基準は保持handleから取得する。NTFSのハードリンクでは列挙情報に古い時刻が残るため、列挙時刻との差だけで変更とは判定しない。各フォルダーの全ての子のhandleと基準時刻を捕捉してから子の削除へ進み、兄弟の処理中に生じた変更も検出する。照合失敗は子の絶対パスと識別情報・時刻の診断を返して停止する。

予約名ファイル・サイズ超過・確認済み即時削除設定時の固定削除は、共有inspectionで元実体を保持し、DELETE非共有のhandleで親・名前・ID・属性を再照合して、そのhandleへ削除を設定する。フォルダーは固定した親から子を列挙し、各実体を検証してから再帰的に削除する。Shellの全結果を受けてから固定削除を開始し、同じbatch内の同じFile IDをopen前からclose・確認まで排他する。独立した実体はworker上限内で並列に処理し、限られた排他枠が重なる場合は一時待機する。予約名ファイルは削除設定を試みる前の照合失敗なら`failed`、試行開始後の失敗や名前消失を確認できない場合は`ambiguous`で止める。サイズ超過と即時削除設定の経路は既にShellを試行しているため、固定削除前の照合失敗も`ambiguous`とする。

同じ実体の別名を複数扱う場合は、確認した変更時刻と一時handleを保持し、可能な場合は通常ストリームと既存のADSへの書込みを抑止する。guardには実行または読取のアクセス権が必要で、取得できない場合は同じroot内の従来処理を維持し、別rootへの引継ぎは停止する。Shellでゴミ箱へ移った無関係な実体には固定削除用guardを取得しない。guardや時刻の確認は外部プロセスによる属性・ACL・ストリームのあらゆる変更を排除する保証ではなく、確認できない状態からは推測して再送しない。

Shellがゴミ箱への移動を成功と返した場合は、返却項目だけを一時的に開き、保持した元実体のFile IDと照合する。識別できない場合や不一致は`ambiguous`とし、記録やゴミ箱全体の走査は行わない。この照合は事後の検出であり、Shell直前の名前差し替えによって別実体がゴミ箱へ移ること自体は防げない。

`files::recordless`の同期削除結果は、`dryRun`・`items`・`warnings`を持つ。項目は`path`・`kind`・`status`・任意の`error`だけであり、状態は`recycled`・`permanently_deleted`・`would_recycle`・`would_permanently_delete`・`already_absent`・`failed`・`ambiguous`である。`permanently_deleted`は対象の元名をゴミ箱へ移さず削除したことを示し、別ハードリンクやバックアップの消去は保証しない。dry-runは予約名の通常ファイルをwould_permanently_deleteで示し、それ以外はWindowsの最終判定を予測できないことを警告する。事前検査で失敗した項目の`kind`は、リンク先を辿らず開き直して種別を判定できた場合だけ実際の種別（`directory`など）にし、判定できない場合は既定の`file`のままにする。`failed`・`ambiguous`はCLIの非ゼロ終了とMCPの`isError`へ反映する。結果不明時は同じ削除を再送せず、元対象とWindowsのゴミ箱を確認する。

復元と保持期間の管理はWindowsのゴミ箱で行う。Windowsが完全削除した実体をPrunletが復元できるとは扱わない。ハードリンクの別名は実体を共有し、生存する外部別名からの書込みがゴミ箱内にも反映される。通常属性・ADS・case-sensitiveな名前とACLはWindowsが移す同じオブジェクトの状態であり、Prunletが保存時点の不変コピーやACL再適用を提供するものではない。

対象のclaim取得順・process共通worker上限・重複/親子の排他・全preflight完了後の実行を維持する。ハードリンクの共有を検出した場合は排他的な実行へ切り替える。MCP要求枠とfile worker枠を分け、registry privilege変更をfile workerと並行させない。

共通ロックの待機・取得を`files::coordination`が進捗として通知し、`service::Runtime`がstderrへ診断を出す。`protocol::mcp`は要求に`progressToken`がある場合だけ`notifications/progress`も返し、処理終了時に通知を無効化して最終応答後の通知と別要求への混入を防ぐ。

`files::recordless`は失敗した各項目の`error`を組み立て、必要に応じて`platform::windows::diagnostics`へ保持元を照会する。再帰固定削除では`FailureEntry`で失敗箇所を保持し、元のエラーチェーンも診断に使う。結果DTOの`path`と診断の`Target`は要求rootのまま、`Failure entry`に失敗entryの絶対パスを表示し、保持元の照会もそのentryを対象とする。これにより、要求単位の結果を保ちながら失敗箇所を診断できる。共有・ロック違反と削除元へのアクセス拒否では保持元を観測し、dry-runではプロセス照会を行わない。アクセス拒否だけで保持元や原因を断定しない。診断は失敗後の現在値であり、診断不能でも元の削除結果を維持する。保持元の特定を削除の再試行やプロセス停止へ結び付けない。照会方法と観測範囲の制約は[連携手順](docs/integration.md#使用中のファイルと同時実行)を参照する。

ロード済みモジュールの照会は、一時的なToolhelp process snapshotから自分を含め最大32プロセスの起動元チェーンを先に並べ、残りのプロセスを従来順で一度ずつ調べる。親関係は照会順にだけ使い、保持元の判定には実モジュールパスの一致を必要とする。snapshot取得に失敗した場合は従来順へ戻し、10秒・8件の上限と、全保持元を特定できない場合の注記を維持する。

固定削除の設定は、ハードリンクguardの有無にかかわらずPOSIX削除（`FILE_DISPOSITION_POSIX_SEMANTICS`）を要求する。ウイルス対策・インデクサー・ディレクトリ監視などの外部プロセスが共有削除許可付きのhandleを保持していても、Prunletの削除handleを閉じた時点で元名が名前空間から外れ、名前の消失を確認でき、再帰削除の親も空になる。従来の削除設定では元名がdelete-pendingで残り、名前確認がWin32 5で`ambiguous`となって再帰削除が途中で止まっていた。guardの経路はPOSIX削除を必須とする。それ以外は、ファイルシステムがPOSIX削除を非対応として設定自体を拒否した場合（Win32 1・50・87）だけ、同じhandleへ従来の削除設定を要求する。拒否された設定は削除を開始していないため、結果不明な削除の再送には当たらない。

固定実体への永久削除要求が受理された後、削除handleを解放してから名前の確認に失敗した場合は、その到達段階と確認できなかったentryをエラーへ含める。Win32 5はACLの制限や削除待ちなど複数の理由で返り得るため、番号だけでは原因を決めない。確認不能は引き続き`ambiguous`として扱い、名前の消失や削除完了を推測しない。

### 明示的な削除待機キュー

Windowsでは通常の同期削除とは別に、CLIの`delete-queue`・`delete-queue-status`・`delete-queue-cancel`で明示的な待機ジョブを扱う。MCPは既存の`delete_files`の`action`に`enqueue`・`status`・`cancel`を追加し、5ツールを維持する。拒否や不明な削除結果からの自動再送には使わない。

同じexeのジョブ専用一時workerとユーザー限定IPCを使い、ジョブ・実体照合情報・結果をメモリーだけに保持する。SID・Windows sessionごとのnamed Mutexで完了保持中を含め最大8 workerに制限する。1要求1〜256パス・親を含む照合情報4096項目・IPC入力1 MiBを上限とする。対象・親・再帰対象の子を削除前に固定して事前probeのWin32 32/33だけを1秒間隔で期限なく待ち、実体や再帰範囲の変更を検出したら中止する。全対象が削除可能になってから既存Coreの削除経路を一度だけ呼び、削除開始後は再送しない。取消は開始判定と同じlockで`pending`の間だけ受理する。

状態は`pending`・`running`・`completed`・`failed`・`ambiguous`・`cancelled`・`unavailable`。最終結果は1時間保持し、`expiresUtc`で期限を返す。照会不能・worker終了・期限切れは`unavailable`として結果不明を示す。受付済みなら呼出元のstdio切断後も継続し、workerが初期ACKを返せなければ削除を開始しない。登録MCPでは通常の子をlauncher終了時に停止し、明示キューworkerは受付前にlauncherのWindows jobからの離脱を照合する。Microsoft Store版（MSIX）のPowerShellが起動した子は親のjobを継承しないため、MCPは起動直後に名前で渡されたlauncherのjobがKILL_ON_JOB_CLOSEを持つことを確かめて自分を入れ、開いたhandleはすぐ閉じる（持ち続けるとlauncher終了でjobが閉じない）。入れない場合も起動は続け、キューの受付だけを所属確認で拒否する。 起動時更新の直後に旧launcherの終了時強制終了jobから新しいexeを起動した場合、キューを受け付ける前に再接続を案内する。

待機ジョブIDは復元用操作IDではなく、manifest・snapshot・恒久キュー・操作履歴を作らない。OSやworkerの消失時は結果不明として扱い、再起動後に同じ削除を再開しない。既存の同期削除・保護領域・ゴミ箱移動と永久削除の条件は維持する。

### macOSのファイル削除

CLIとstdio MCPの`delete_files`は同じTrash処理を使う。絶対UTF-8パスを受け取り、既知のOS別名を照合し、任意のシンボリックリンク祖先を拒否する。末尾のリンクはリンク自体を扱う。設定、配置ルート、metadata、キューの予約領域、互換の旧復元領域をパスと実体で保護し、対象の重複も拒否する。privateなmetadataの`maintenance.lock`で要求を直列化し、全対象の事前検査を終えてから入力順に処理する。dry-runは対象を移さず、`would_recycle`は事前検査の結果を示す。

同期処理は親と対象のFDを保持し、`recursive`を指定したフォルダーも最上位の項目を移す。子を個別に固定しないため、大きなツリーでも子の数に応じたFDを消費しない。`NSFileManager`にパスを渡す直前に実体を再照合し、返却されたTrashのパスが同じ実体を指し、元名の消失を確認できた場合に`recycled`を返す。OSへのパス指定と事前確認は一体の原子操作ではない。移動後の照合ができなければ`ambiguous`として後続対象を保全し、再送や永久削除への切替を行わない。`NSFileManager`がエラーを返した場合も、元の名前が移動前と同じ実体（device・inode・mode）のまま残っていると確認できたときだけ`failed`とし、元名が無い・別の実体・確認自体の失敗では`ambiguous`にする（Linuxの失敗後照合と同じ方針）。`ambiguous`は文言ではなく専用のエラー型で判定する。OSが復元と保持を管理し、Prunletのファイル操作記録は作らない。

待機キューは同じCLIコマンドと`delete_files`の`action`を使い、再帰対象では子もFDで固定する。最大256パス、親を含む最大4096項目と利用可能なFD数の範囲で事前検査する。協調的な`flock`の競合だけを待ち、全ロックの取得後に同じTrash経路で実体を再照合する。取消は`pending`の間だけ受理する。固定のMachサービス枠は実効ユーザーごとに最大8件で、カーネルの監査トークンで相手を確認し、照会先はPIDとその世代も照合する。workerは開始許可を受け取ってから実行できる。許可送信後に応答を失った場合はジョブIDで照会し、自動再送しない。受付後はstdio切断と独立して実行し、結果はworkerのメモリーに1時間保持する。

### Linuxのファイル削除

CLIとstdio MCPの`delete_files`は同じ同期処理を使う。絶対パスの親をシンボリックリンクを辿らずに開き、末尾のリンクはリンク自体を扱う。設定・復元領域・実行ファイル・管理済み配置・Trashとのパスの重なりと、保護対象と同じ実体を拒否する。対象と親のマウントIDをホームTrashと照合し、再帰対象では子も検査して別マウントや保護実体を含むツリーを拒否する。マウントIDを使うため、デバイス番号が同じbind mountも区別する。全対象を事前検査し、失敗があれば移動しない。dry-runではTrashのディレクトリも作成しない。

ホームTrashのディレクトリfdの`flock`で、同じTrashに対するPrunletの移動を設定間でも直列化する。`.trashinfo`を先に作成・同期し、保持した親と対象の実体を再照合して`renameat2(RENAME_NOREPLACE)`で`files`へ移す。フォルダーは最上位の項目を移す。名前の検査とrenameは別操作のため、移動先の実体、元名の消失、`.trashinfo`の実体を移動後に照合し、ディレクトリを同期してから`recycled`を返す。renameの失敗後は元実体の保持と移動先を確認し、安全に回収できる今回の`.trashinfo`だけを片付ける。結果を確認できなければ`ambiguous`を返し、要求の残りを保全する。別マウントへのコピーや永久削除には切り替えない。`.trashinfo`はファイルマネージャーが復元に使うTrashの情報であり、Prunletの復元用記録は作らない。

## 保存領域と保護

`backupDirectory`は保護されたmetadataの基点である。Windowsのmanifestの`MetadataRoot`は従来の共通基点を維持する。レジストリの通常記録は`<backupDirectory>/.registry-records-v1/<operationId>`へ分離し、通常の一覧・保守・復元はそのnamespaceを対象にする。

旧flat記録・旧schema 4のボリューム専用領域・旧schema 6の制御領域は、移行が終わるまで保護する。通常のファイル削除・一覧・保守が、旧ファイルの操作ディレクトリを探索・監視・再評価する経路は持たない。新しいファイル削除のためにボリューム専用領域を作らない。

手動`init`は設定だけを作り、明示`migrate --apply`が専用namespaceと全体のレジストリ準備を確定する。準備前の通常レジストリ削除・一覧・保守は`migration_required`で軽量拒否する。既知IDのrestore/reconcileによる個別旧記録の移行は、全体の準備完了とは扱わない。ファイル削除はレジストリ準備を要求しない。

## レジストリの削除と復元

この機能は指定したキー・値のトランザクション削除と復元を扱い、Windows管理情報の意味や参照関係を修復する機能ではない。AppContainer profileやAppx packageのライフサイクル処理を汎用削除へ付け替えない。`DeleteAppContainerProfile`は失敗時の状態が不定になり得て、Prunletの完全退避・原子的commit・非上書き復元の契約に組み込めていない。StateRepository・AppxAllUserStore・CloudStore・AppCompatCache・BagMRU等の混在データも、形式・版・参照整合を検証する専用処理がないため、製品名の文字列一致だけで清掃対象を決めない。これはこれらのパスをCoreが一律に識別・拒否するという意味ではなく、呼出し元が安全な単独削除を確認できない対象を要求しないための境界である。

レジストリ操作も`Core`へ集約する。CLIは`registry-delete --view <32|64> [--access-mode <normal|backupRestore>] [--value-name <literal-name> | --value-name=] [--recursive] [--dry-run] -- <single-key-path>`、MCPは`delete_registry`と`restore_registry`を提供する。CLIの`restore`と`registry-restore`は`<operation-id> [--access-mode <normal|backupRestore>]`を受け取り、MCPの`restore_registry`とともにレジストリ専用である。削除要求はview必須、値名省略はキー、空文字は既定値であり、値削除の再帰指定を拒否する。

キー名内のcolonはリテラル文字として受理する。`C:#...`や`C:%5C...`もキー名の一部であり、ドライブパスやURLとして解釈・展開しない。相対パス・空segment・wildcardの拒否は維持する。

アクセス方式は要求ごとの`normal`（既定）または明示`backupRestore`で選ぶ。`backupRestore`は64bit OS・64bitプロセス・view 64に限定し、view 32は原本・privilege・transactionを開く前に拒否する。バックアップ／復元オプションがaccess maskとともにWOW64 view指定を無視するため、64bitプロセスの既定viewだけを使用し、32bitパスを合成しない。復元時の記録がview 32の場合も同じ制約で停止する。後者は実効呼出し元の`SeBackupPrivilege`・`SeRestorePrivilege`を一時有効にし、既存キーのnative openに`REG_OPTION_BACKUP_RESTORE`を加える。ローカル実行では実効呼出し元tokenの複製を専用スレッドに設定し、native sessionでは認証した呼出し元の要求別tokenを使う。process tokenを強めたまま後続要求へ持ち越さず、privilege復元の失敗と対象transactionのcommit結果は別に報告する。通常・rawリンク検査・同一オブジェクトのtransaction接続・再帰子・復元で同じ方式を使い、`OBJ_DONT_REPARSE`とリンク検査を維持する。ACL・Ownerを書き換えてアクセスを得ず、権限不足から自動切替しない。方式は退避データのidentityではないためschema 5は変えず、復元時も毎回明示選択する。記録から自動的に強い権限を有効化しない。dry-runでも実削除に必要な実効権限・transaction接続を確認し、stage・commit・対象変更を行わない。

schema 5の`registry-manifest`・snapshot・intent・receiptで、未知の値型も含め型のuint値と生バイト列、キーごとのOwner・Group・DACL・SACL（Mandatory Labelを含む）を保持する。実削除は非トランザクションの対象または親HKEYを保持し、その同じオブジェクトをRootDirectory・空の相対名で`NtOpenKeyTransactedEx`に渡す。まず削除をトランザクション内へstageし、外部には元データが見える状態で、保持した非トランザクションHKEYからsnapshotを取得する。snapshot・manifest・intentのflushとハッシュ検証を済ませてからcommitし、完了receiptを永続化する。したがって外部に削除が確定する前に保全データが永続化される。

dry-runは`registry::native::delete_snapshot`の事前検査経路で実削除と同じ原本オブジェクト・アクセス権・再帰範囲を使い、各対象のtransaction接続を確認してsnapshotを読み、保持した名前の一致も確認する。削除のstage・書込み・commitは行わない。transaction非対応のviewを読取りだけで通過させて`would_delete`とすることを防ぐが、その後の外部変更や実削除の成功までは保証しない。

snapshotを先に読んでから削除をstageすると、その間の外部書込みが成功したまま失われるおそれがあるため、この順序へ戻さない。先行stage後も非トランザクションの外部書込みが受理される場合はあるが、競合したcommitは失敗し、外部の新データを含む元対象を保全する。KTM非対応時の非トランザクション削除は行わない。完全なキーACL取得には`SeSecurityPrivilege`が必要であり、現在のトークンに存在する場合のみ一時有効化し、自動昇格しない。権限不足やsnapshot失敗ではcommitせずロールバックする。値には独立ACLがなく、親ACLを変更しない。

schema 5の原文bytesはpendingファイルの最初の書込み時点から、Ownerを現在のユーザーSID、アクセス主体を現在のユーザーSIDとSYSTEMだけとするprotected DACLを指定してatomicに作成する。操作ディレクトリ・metadata・ロックも同じ非公開ACLで作成し、後からACLを締める公開期間を設けない。読取り・復元・整理でもACLを検証し、改変を検出した記録は処理せず保持する。

manifest・snapshot・intent・receiptの公開は`registry::storage`が担当する。snapshotは容量予約に使った確定済みUTF-8 bytesを公開にも使い、公開のための再JSON化を避ける。manifestとreceiptは既存ownerの作成時刻を反映してからJSON化する。空のpendingを作成し、親と本文のidentity・公開先名・長さ・hashを結び付けた所有予約をflushしてから本文を書き、flush・検証後に同じhandleで正式名へrenameする。未公開本文を正式receiptへ昇格してcommit結果を推測しない。正式callerが原本とACLを再検証し、予約した完全bytesと既存prefixが一致した場合だけ書込みを再開できる。公開済み本文のidentity・長さ・hashを確認できれば所有予約を清掃できるが、pendingと正式名の共存、所有不明、改変は保全する。正式名へのrenameと本文の再検証が済んだ後の所有予約の削除失敗は公開の成否を変えず、warningとして返す。残った予約は読取り時に本文照合つきで受理され、後続のcleanupが整理する。

正式な削除intentの公開前に失敗・中断した記録は、正式receiptが1つもないことから未commit確定（`not_committed`）と分類する。現行版も旧版も正式intentの公開後にだけcommitするためであり、pendingのintent本文や公開予約を正式intentへ昇格せず、現在のキーの有無からcommitを推測しない。snapshotは既知容量として数えて後続の削除を止めず、明示`purge --apply`と保持期限・予算による整理の対象にする。このpurgeはreceipt・terminalを作らず、snapshot・manifest・lock・ディレクトリを既存の固定handle経路で消し、receiptの公開予約が残ればmetadataを保全する。`registry-reconcile`と`operations`は`not_committed`を返し、restoreは拒否する。正式manifestの公開前に止まった記録は、snapshotの所有予約の長さ（予約が無い正式snapshotは実サイズ）を容量に数えて本文を保全し、lockだけの記録だけを整理する。receiptの予約や未知memberを持つ記録は容量不明として保全し、正式intentの公開後の失敗は従来どおり`ambiguous`とする。delete・restoreが失敗したときのwarningは、プロセス内のcommit済みフラグだけでなく保存済みの記録を読み直し、正式manifest・intent・completeの有無で決める。正式intentのrename後に失敗した記録は`ambiguous`として保全し、`purge`で除去できるとは案内しない。complete公開後の失敗は完了済みとして示し、読み直せない場合は結果を推測せず保全を伝える。この読み直しは分類だけに使い、intentを消して`not_committed`へ戻すことはしない。公開後の所有予約の削除失敗は非致命とし、commitの直前に残っている予約がすべて検証できること（`verify_reservations`）を確認して、検証できない予約はcommit前に止める（intent公開後に止めた記録は`ambiguous`として保全する）。外部プロセスが予約を共有READなしで保持して検証の読取りも失敗する場合は、安全側に止まり、保持の解放後に`registry-reconcile`で状態を確認する（未検証のままcommitしない）。

キーの生セキュリティ記述子は`BACKUP_SECURITY_INFORMATION`（0x10000）で取得し、Owner・Group・DACL・SACLとMandatory Labelを含めて保持する。Owner/Group/DACL/SACLだけの取得フラグ（0xF）ではMandatory Label ACEが欠落するため使用しない。復元時は完全な記述子を指定して全キーを作成してから、必要なauto-inherited bitだけを要求するsetterを適用し、同じ完全取得方法で再読して生bytesを完全一致で比較する。親のsetterを子の作成前に適用すると、SACL実体がない子のauto-inherited bitが失われるため、この順序を維持する。比較を緩和せず、保持できない場合はロールバックしてsnapshotを保全する。

復元はトランザクション内で新規作成だけを許し、既存キー・値・空の既定値を上書きもマージもしない。値復元は先に書込みをstageしてから、保持した非トランザクション親HKEYで同名値の不存在を確認する。既存値ならロールバックし、競合する外部書込みがあればcommitを失敗させて外部値を保全する。Owner/SACLの適用権限不足もロールバックしsnapshotを保全する。commitとreceipt永続化の間の中断は`ambiguous`としてpayloadを保持し、推測した復元・自動整理を拒否する。complete receiptの公開後にsnapshotの消費だけが失敗した場合は`restored`のままwarningで返し、後続の`maintain --apply`が回収する。キーのclassも保存するが、最終書込み時刻は復元せず、volatileキーも非volatileキーとして復元する。

対象はローカルHKCU/HKLM/HKUの絶対キーで、`Registry::`およびmodule prefixを許容する。PowerShell形式の`HKCU:\`・`HKLM:\`・`HKU:\`も受け付ける。ルート自体、mergedなHKCR/HKCC、remote、relative、レジストリリンク、未知のschema・metadataや検証できない復元記録は拒否する。例外は実効ユーザーの`HKCU\Software\Classes`（同じSIDを明記したHKUも含む）が祖先にある要求だけで、native名、REG_LINK型と`\Registry\User\<実効SID>_Classes`のUTF-16生bytes完全一致を検証する。その既知aliasだけ読み取り専用でOSに解決させ、期待する宛先のnative名と解決前後のalias bytesを照合する。REG_LINK値を持つ通常key、別ユーザー・任意の宛先・宛先側や下位のリンク、Classes自身への要求は拒否する。OS解決で得たhandleを変更に使わず、固定User anchorから宛先を1 segmentずつnofollowで開き、snapshotには要求の論理pathを保つ。保持条件と整理の責務は[復元データの自動整理](#復元データの自動整理)にまとめる。

REG_LINK型の値の欠落だけを通常keyの証明にはしない。通常のnative openは`OBJ_DONT_REPARSE`を指定し、保持rawリンクからの相対参照も再解析を拒否する。既知alias以外の全segment・解決先SID_Classes・再帰列挙の子は、同じview・transactionで`OBJ_DONT_REPARSE`かつ`OBJ_OPENLINK`なしでも開き、raw keyとのnative名一致とREG_LINK型の値がないことを確認する。確認で得た通常keyのhandleを以降の探索・snapshot・変更の正本にし、古いraw handleへ戻さない。値を失った実リンクなど、raw keyが存在するのに通常keyとして開けない場合は不存在の成功扱いにせず停止する。通常keyの構造はREG_LINK値の追加だけでは実リンクへ変わらない。未知のリンクを追う確認は行わず、followを明示するのは型・bytes・native名を検証済みの既知Classes aliasの読み取り証明だけである。

aliasの読み取り接続だけでは最終確認後の外部更新と競合しないため、実削除と復元ではalias自身も同じtransactionへ空の相対名で接続し、元のREG_LINK値を同じ型・同じbytesでstageしてwrite guardを得る。先にaliasのSetValue権限・transaction接続と宛先accessを確認し、stage後に非transactionの保持aliasから元bytesを再確認する。aliasと宛先のhandle・native名・bytesを保持し、commit前に再検証する。外部のalias更新が受理されてもtransactionのcommitが競合で失敗するため、対象変更とalias guardは一緒にrollbackされる。dry-runは同じSetValue権限と接続を要求するが、aliasを含む書込みをstageしない。追加権限とcommitによるaliasのlast-write時刻変更の可能性を結果warningsで知らせる。aliasの型・bytesとACLを変更せず、guardを設定できなければ停止し、ACL変更・非transaction操作への切替は行わない。

MSIX由来の仮想viewでtransactionが利用できない場合も、非transaction操作へ切り替えない。通常Windows側の操作には、通常デスクトップの期限付きnative sessionを用意し、`registryScope=nativeWindows`と専用接続情報を明示選択したCLI・MCPから同じCoreへ委任する。検証では`Verify-RegistrySession.ps1`のPrepareで固定したscopeと入力に限り、`Start -AssertNativeWindows`からdesktop Explorerの通常起動とWindowsの`runas`で起動できる。管理者起動の同意はOSのUACポリシーに従い、エージェントは同意を代行しない。入力のread handle・hash、nonce、原子的な開始claim、親の生存・期限、通常/管理者の実token、両者のreadyとRun permitを照合し、遅延起動や曖昧な開始を拒否する。手動のdesktop起動は診断互換として残す。job・silo制約を転送する方式ではなく、通常Windows scopeへの明示委任であり、汎用コマンドbroker・サービス・タスク登録・仮想viewからのfallbackは追加しない。要求ごとのeffective tokenを使用し、session固有の権限を呼出元へ貸さない。sessionはlocal・同じログオン・同じexeに限定し、期限後は新規受付を停止するが進行中のCoreを強制終了しない。

native scopeの識別はmanifestとsnapshotのhash内に保存し、machine・SID・viewの一致を復元前に確認する。scope欠落の旧記録をnativeと推定せず、異なるscopeからの復元を拒否する。restoreのIPC分岐は共通ロックの取得前に行い、server側だけでCoreの共通ロックを取得する。deleteのoperationIdはclientで先に決め、応答喪失時は同じ削除を再送せず、read-onlyの`registry-reconcile`で記録を確認する。接続・scope・認証の不一致は元対象と復元データを保持して停止する。起動・設定の手順は[連携手順](docs/integration.md#通常windowsのレジストリを明示して操作する)を参照する。

purge intentがありsnapshotもcomplete receiptもない記録（snapshot消費後にcompleteの公開が失敗した中断）は、`maintain --apply`の走査が共通ロックの排他下でpurge completeを公開して閉じる。復元のcomplete後に残ったsnapshotの回収と同じ責務である。走査は1件の名前確認の失敗でmaintain全体を止めず、その項目を容量不明のwarningとして保全し、他の記録の整理を続ける（確認が失敗する実OSの条件は特定しておらず、保護を弱めない予防である）。消費するmetadata（snapshot・receipt・空ディレクトリ）の削除はPOSIX削除を先に要求し、外部の`FILE_SHARE_DELETE`付きhandleが残っても名前が消えるようにする。非対応のファイルシステムだけが従来の削除設定へ戻り、ハードリンクguardの前提には触れない。storage状態（`storage-migration-v1.json`）が書込み途中の空・途中終了の場合は`migration_required:`として`migrate --apply`での再作成を示し、束縛不一致や改変の拒否とは区別する。

## 旧ファイル復元データの明示移行

旧ファイルの復元互換を維持せず、Coreの明示`migrate`で所有確認済みの旧退避データ・操作記録をWindowsのゴミ箱へ破棄する。旧schema 1〜4/6のdecode・内容hash・ACL snapshot・コピー・bundle・sidecar・file restoreは実装しない。既存のWindowsゴミ箱項目を走査・再移動しない。

volume側は8 KiB以内のstore markerでSID・metadata root・StoreKey・volume・root identityとprivate ACLを検証した専用StoreKey/restore rootだけを扱う。privateBase・custom設定dir・他StoreKeyを丸ごと処分しない。中央GUID操作は直下の正規file marker名で分類し、本文が破損・未完了でも処分できる。registry manifest・pending・publication・namespace/controlのsignalは先に保護する。typed file rootは正規layout、既存bundle/journalは予約prefixとprivate metadata所有範囲で限定し、本文の任意Pathへ削除範囲を広げない。

所有inventoryのpinを解放してからdispatchし、直前にpath・root identity・marker・非reparseを再確認する。元実体の共有handleをShell処理中も保持し、返却項目が同じ実体と確認できなければ`ambiguous`で止めてgateを残す。通常削除と同じ`platform::windows::recycle::recycle`を使い、永久削除・copy fallback・任意対象の保護解除フラグを追加しない。結果はPathと`recycled`・`would_recycle`・`would_permanently_delete`・`already_absent`・`retained`・`failed`・`ambiguous`であり、file操作ID・復元記録を新設しない。

移行全体で固定のprivate空ファイル`.legacy-file-discard-in-progress`を1個だけ使う。これは対象Path・ID・hash・ACL本文を持たない実行gateであり、CreateNew・Flush・検証後にdispatchし、確認済み成功時だけ除去する。存在または不正形はfile discardだけを停止し、registry処理は続ける。installerは解除せず、元フォルダーとWindowsゴミ箱の確認後の`migrate --apply --retry-legacy-discard`だけが、正規の空private gateを解除して再評価する。dry-runとif-neededにackを組み合わせない。

registryの旧記録は専用namespaceへ移し、ID・snapshot・完全ACL・scope・共通MetadataRootを保持する。file処理の未完了はRegistryReadyから分離する。policy version 2は未指定0の旧stateを読める形で保存し、installerの`--apply --if-needed`では中央旧GUID走査を省略する。オンラインvolumeの所有済みstore/restore rootの少数存在・小marker検査は更新時に続け、後から接続された領域を回収する。通常file delete/list/maintainへ旧領域走査を加えない。移行開始後は旧binaryへrollbackせず、新exe・設定・登録を保持する。

## 復元データの自動整理

保持制御はレジストリschema 5専用で、既定7日・合計1 GiBである。事前容量走査・整理前後の再走査・共通ロック・単一超過時だけの予算を維持する。Windowsゴミ箱のファイル実体と移行待ちの旧ファイルは容量・期限・purgeの対象に含めない。

レジストリ削除前・明示`maintain`・非表示の定期保守でレジストリ復元データを整理する。ファイル削除はレジストリの容量保守や旧root走査を起動しない。`operations`とMCPの`list_operations`はレジストリ一覧、`purge`と`maintain`もレジストリ専用である。手動整理はCLIの明示適用だけとし、MCPへpurgeを追加しない。

検証できないACL・snapshot・未確定commitは保全し、自動整理で捨てない。`maintain --audit-records`の完全監査と通常容量走査を区別する。旧ファイルの型別index・終了履歴・外部不在判定を、新しいファイル通常経路の管理機構として復活させない。

レジストリの復元・purge完了後は、snapshotが消費済みで正式完了receiptがある記録から、残存memberのidentity・security bytes・長さ・hashを束縛する`<id>.terminal.json`を作る。完了時点から保持期間を過ぎた記録だけを整理し、先にterminalのhashに結び付けた`<id>.terminal-cleanup.json`を永続化する。途中でmanifestが消えても保存済みinventoryで残存memberを検証して再開し、未知memberや差替えは保全する。これらはレジストリ専用であり、ファイルの終了履歴を作る機構ではない。

移行・terminal・terminal-cleanupの制御記録の公開は`registry::storage`が扱う。中断したpendingの再公開には、呼出元が同じ記録の証拠から本文を再構成し、既存prefixとの一致を検証する必要がある。pending本文だけを権威にせず、正式名との共存や不一致は保全する。この再構成方式はsnapshot・receiptの公開には一般化しない。

### 容量上限の一度だけの移行

latest導入時に`capacityDefaultMigrationVersion`が欠落または1未満の既存設定だけを対象に、`maxRecoveryBytes`を1 GiB、移行印を1へ一度だけ更新する。移行済み印と移行後の利用者変更を尊重し、未知の設定・ACLを保持する。設定読込やdry-runへ設定書込みを持ち込まない。詳細の動作検証は[導入検証](docs/verification.md#latestインストーラー)を参照する。

## 不変条件と設計判断

拒否された削除を別shell・別API・別exeへ付け替えない。処理が不明な場合は元のパスとOSのゴミ箱を確認し、自動再送しない。Windowsでは明示的なサイズ超過と確認済み即時削除設定だけをゴミ箱失敗後の永久削除条件とする。保護領域・祖先・リンク先を通常削除で破壊しない。レジストリの完全ACL・raw bytes・transaction・非上書き復元を維持する。

## 導入と検証の境界

Windowsの利用者向け導入はソースをビルドせず、公開済み最新releaseの署名済み更新ZIP（`prunlet-update-<runtime>.zip`）を配置する。releaseの解決と取得は起動時自動更新と同じ条件（安定版・タグのcommitが既定ブランチ上・runtimeのassetが一意でdigestとsizeを持つ・公開URLから取得してdigestとsizeを照合）で行う。展開前に固定のentry集合・リンクなし・サイズ上限、`package.json`の取得元・既定ブランチ・release commit・runtime・各hash/長さを照合し、展開後に実体hash・CLIとhookの同一性・PEのmachine・Authenticode（Valid・署名者・タイムスタンプ）を確認する。いずれかが不一致、またはassetが未添付なら配置先・設定・タスク・登録へ書き込む前に止まる。`source-info.json`は起動時更新と同じ10項目（`downloadUrl`はreleaseのasset API、`archiveSha256`はZIP全体）で記録し、次回以降の自動更新は、導入済み`source-info.json`のbytes（整形・改行）ではなく内容（commitと各hash）を基準に引き継ぐ。インストーラーは更新状態とstageを変更しない。開発クローン・ローカルビルドをlatest導入の代用にしない。設定の検証には`validate-config`を使い、設定読込とservice構築だけで走査・変更しない。共通指示の生成元は`integration/PRUNLET.md`で、配置済み共通指示の更新とソース変更は別の結果として扱う。

インストーラーの`-UseGitHubCliAuthentication`は、APIの未認証枠を使えない場合などに、既存のGitHub CLIへAPI取得を委ねる明示選択である。release解決の契約は変えず、`gh api --hostname github.com --method GET`を直接起動する。トークンを抽出せず、対話とデバッグ出力を抑止し、認証関連のstderrを記録へ転載しない。ghの導入・ログイン・cloneへの切替は行わず、失敗時は停止する。

手動導入の`-UpdateManagedInstallation`は、Gitの祖先配下にある既存の管理済み配置を更新するための限定的なパス検査例外である。既存設定・取得元情報と全製品hashを照合し、Git追跡対象を含まず、Git除外または実効CodexHomeの正規CLI登録で所有を確認できる配置だけを扱う。作業先・更新バックアップ・ソース・Codex内部へのガードを維持し、既存の復元先を保持する。配置と移行の直前にも再確認するが、ディレクトリ実体の原子的固定は提供しない。登録guideは検証済み本文との改行差だけを許容し、旧更新stageは保全する。`-ExpectedCommitSha`は取得した最新releaseのcommitとの一致を要求し、不一致なら導入を止める。詳細な条件は[連携手順](docs/integration.md#手動の設定準備)を参照する。

### 起動時自動更新

PrunletはAIツールに付属しない単独のアプリとして導入し、WindowsのMCPはどのMCPホスト（Codex・Toolport・Claude Codeなど）からも`integration/start-prunlet-mcp.ps1`をPowerShell 7で起動する。`-CodexHome`は任意で、省略時は実効のCodexHome（`CODEX_HOME`、なければ`%USERPROFILE%\.codex`）を判定対象にする。インストーラーは`-RegisterCodex`を明示した場合だけCodexの設定へ書き込み、既定のバックアップ・作業場所もCodex名義の場所を使わない（`%LOCALAPPDATA%\Prunlet\Backups`・`%TEMP%\Prunlet`）。launcherがGitHubへの照会と更新手順の調停を行い、`update::coordinator`が製品・登録・移行の状態遷移を、`update::package`・`update::download`がパッケージ検証と取得を、`update::budget`・`update::slot`・`update::rotation`が容量と再利用を担当する。`update::gate`は通常CLI・MCP・保守の開始前に更新状態を検査する。hook専用の`prunlet-hook.exe`はこのgateを通らず、削除を実行するCLIのパスを受け取って案内する。

Windowsの起動時照会は未認証で始める。HTTP 403で`X-RateLimit-Remaining`が`0`、かつ`Retry-After`がない場合だけ主レート上限と判断し、その起動中の読取りを既存の`gh`認証によるGETへ切り替える。認証は`gh`の内部で使い、対話を抑止する。照会に失敗した場合は更新を延期し、更新状態が`idle`なら現行版で起動する。

MCP起動時に公開済みlatestを確認し、既存版の子孫で更新protocolと保管形式が互換の候補だけを準備する。既存の製品・登録の所有とhashを確認し、旧CLI/MCPと保守exeを同時にwrite排他できなければ変更せず延期する。hookは独立exeとして継続し、旧プロセスを終了させない。固定の更新状態は製品切替・登録・移行の再開と更新cacheの所有確認・再利用に限り、ファイル操作履歴には使わない。途中状態では通常CLI/MCPと保守を止め、候補からレジストリ移行を再開する。移行開始後は旧exeへrollbackせず、registryが利用可能になってからsource-infoとidleを確定する。書込みや置換が不明なときは保全して自動再送せず、確定したregistryの利用とは分離する。

MCPホストがMCPを起動しないPCでも追従させるため、インストーラーは更新タスク（`Prunlet-Update-<識別子>`）を登録する。タスクは`conhost.exe --headless`から`pwsh -NoProfile -NonInteractive -File bin\start-prunlet-mcp.ps1 -UpdateOnly`を窓なしで起動し、MCPを起動せずに上と同じ照会・延期・切替だけを行う。最新・延期・通信不能は正常終了とし、更新状態をidleへ戻せない場合だけ非0で終わる（conhostは終了コードを中継しないため、タスクの結果欄では区別できない）。`Global\Prunlet-Startup-`のmutexでMCP起動時の更新と直列化する。保守タスク（03:00・ログオン直後）と重なると製品exeの使用中判定で毎回延期するため、毎日12:30とログオン10分後に実行する。pwshはPATHから解決し、所有判定は所有印・利用者・conhostのExecで行う。Codex登録の保護は、MCP起動・更新タスクのどちらでも起動ごとにCodexHomeの実物から判定する（MCP起動だからCodex登録ありとはみなさない）。Prunletの所有block・hook・共通指示が一つでもあれば従来どおり登録の変更を要する候補を延期し、痕跡がない場合だけ登録の照合を省く（タスク引数の切替にはしない）。インストーラーは、`-RegisterCodex`を指定した場合かCodexHomeにPrunletの登録が残っている場合だけ、更新タスクへ`-CodexHome`を渡す。自動更新では所有済みの既存タスクの引数だけを移行して新規には作らず、既存タスクの`-CodexHome`の有無と値を引き継ぐ（起動元のMCPホストによって変えない）。切替後の連携で所有確認に失敗すると更新状態がidleへ戻らないため、候補の判定時（idleのうち）に候補の`maintenance-task.ps1`で更新タスクの所有を確認し、他者・編集済みなら切り替えずに延期する（保守タスクは従来どおり連携時の確認だけで、idle前の確認との間の編集は同じ非原子的な扱い）。インストーラーは配布物の補助ファイルが対応する場合だけ登録する。明示的な定期実行の解除（`uninstall-maintenance.ps1`）は保守タスクと更新タスクの両方を外す。

登録の検証では、登録済み`PRUNLET.md`のバイト列が候補と異なる場合に、両方を厳密なUTF-8として読み、CRLFをLFにそろえて本文を照合する。一致すれば既存ファイルのバイト列を保持したまま進める。登録への書込みが必要な候補は保留する。この同一性判定は登録済みガイドの読取り検証に限り、配布物のSHA-256照合は元のバイト列で行う。

stageは再帰削除せず、完了した世代の正規製品とmetadataをhashと実体で照合して主streamだけを再利用する。正常な次回更新を、stageが存在するだけで止めない。適用済みstageの再利用は、導入済み来歴との一致を求めず、stateが記録したstage自身の`source-info.json`のhashとcommit、全製品・補助製品のhash、所有印の内容、previous来歴のcommitと原本との一致で所有を確認する（`prior_stage_commit`にもstage自身のcommitを記録する）。そのため手動導入（インストーラーの再実行）で導入済み来歴が変わっても次回の更新を止めない。旧来歴は、stateの記録hashと一致した`source-info.json`（stage側、次に導入済み側）だけを使い、どちらも一致しない場合は旧hashでの上書きを許可しない。未切替の候補に対して同じcommitで再開する場合、手動導入で導入済み来歴が変わっていれば、導入mutex下で基準hashを記録し直して警告し、切替時に従来どおり再照合する。`stage_cleanup: pending`は、stateが所有する恒久cacheがある状態を意味する。照合するのは書込み対象の固定名とstateが記録した名前だけで、未知の項目は変更せずに容量へ含めて保持し（更新は止めない）、未確定の切替・移行は先に同じ候補で再開する。

切替前のidleで候補実行・移行・登録確定・rotation・補助製品の置換がない未適用stageは、取得失敗・中断・適用済み来歴（`prior_*`）付き・基準（`cacheBaseline`）付きのどの状態からでも、次の候補向けに基準を作り直して更新を続ける。stageは削除しない固定cacheなので、上書きしてよい基準は導入済み来歴から導き直さず、stage自身の記録を起点にする。書込み対象の固定14パス（owner・`source-info.json`・3製品・9補助製品）だけを照合し、現物のhashが、記録済みの旧基準（`cacheBaseline`、なければ`prior_*`から内容で確認できた来歴、新品なら存在しないこと）、置き換わる候補（stateがreadyと記録し、認証済みのhash・長さと現物が一致するZIPの製品表と、その内容に一致する`source-info.json`）、進行中の`stage_write`記録のold/newのいずれかに一致する場合に限って認める。認めたパスの現物hash（存在しなければ空文字）を、照合に使った同じ読取りから任意stateの`cacheBaseline`へ先に固定してからownerを切り替え、中断時は同じbaselineで再開する。記録のない名前・どの記録とも一致しない内容・書込み途中の現物・ADS・リンク・所有印の不一致は変更せず保持して拒否する。`prior_*`と補助製品の退避hash・slot・ZIPの名前と状態は引き継ぎ、`cacheBaseline`と共存できる（`prior_*`が完全であることだけを求め、孤立した`prior_*`は拒否する。同じcommitを指す来歴のhashの一致は求めない。適用済みstageと同じcommitのreleaseがassetを差し替えて再公開されると候補側の`source-info.json`だけが変わり、一致を求めると次のreleaseでstateを書けず停止するため）。`cacheBaseline`の空文字はそのパスが存在しないことを表す。`prior_previous_info_sha256`は、切替の準備が中断してprevious来歴だけが先に書かれていた場合に限り、記録済みの旧hashまたは準備時の導入済みhashと一致した現物のhashへ更新する。基準はprepareと置換だけが使うので、`phase`が`switching`へ移る書込みで消す（この形式のstateは旧版が読めないため、候補が未適用の期間に限る）。これはstage主streamの更新だけに用い、previousへの退避と製品rotationは現在のinstalled来歴を基準にする。

配布元は公開済みGitHub Releaseとする。`.github/workflows/prunlet-release-package.yml`が公開タグからwin-x64・win-arm64を1つのjobでビルドし、Sigilune（Certum SimplySignのクラウド鍵）で`scripts/Sign-PrunletBuild.ps1`が両runtimeの実行ファイルをまとめて署名してから、`scripts/Package-PrunletUpdate.ps1`でZIPを作成する。署名用Secretsはブランチ制限付きのEnvironment `release`（承認者なし）に置き、署名stepだけへ渡す。CLIを署名してからhookへ複製し、両者の同一hashを保つ。公開前に`Verify-ReleasePackage.ps1 -RequireSignature`がentryの過不足・重複、metadataの取得元・commit・runtime等、全同梱ファイルの長さ・SHA-256を今回のpublish出力・sourceと照合し、各実行ファイルの署名・署名者・タイムスタンプを確認する。検証済みZIP全体のSHA-256をアップロード直前にも再確認し、同じreleaseへ添付する。既存assetは上書きしない。署名処理は`scripts/Signing.Common.ps1`に集約する。

取得側はタグが既定ブランチ上のcommitを指すことと、パッケージ内のcommit・runtime・製品hashを検証する。通常の起動時更新では、照会済みタグと実行体のruntimeからGitHubの公開ZIP URLを組み立て、REST API枠を使わずにZIPを取得する。タグを渡さない旧launcherからの要求ではasset IDによるAPI取得を維持する。どちらの取得経路でも、APIが返したサイズとSHA-256で転送内容を照合する。ソースとビルドの対応は発行者への信頼に依存する。Actionsの期限付きartifactを更新の必須条件としない。

更新用cacheはレジストリ復元領域とは別に合計2 GiBを上限とする。公開ZIP・stage・製品slot・固定candidate/previous・保全した異常世代・各ディレクトリのADS・更新管理ファイルを容量に含め、確保前と完了後に検査する。slotはcache専用で、実行・移動・削除しない。正規hash・長さ・単一linkを同じ排他handleで確認し、通常streamだけをin-place更新する。候補へはそのhandleの通常streamだけをCreateNewコピーする。stateが書込み前に記録した名前の書込み中（`writing`）の配布ZIPと製品slotは、記録済みの部分書込みとして同じ名前（slotは同じgeneration）のまま先頭から上書きする（単一link・代替ストリームなしで、長さがこれから書く長さ以下の場合に限る。記録名のファイルが失われていれば同じ名前で作り直し、slotは検証済みの再利用にせず必ず書き直す）。記録のないもの・記録と異なるもの（`ready`なのに内容が変わっている、記録のない`package.zip`、ADSあり等）は上書きせず、保持して別の名前を使う。予算不足を自動削除で回避しない。stateの公開は、読取り中のCLI・MCPによる共有違反（32）・置換不可（1175）だけを短い間隔で数回再試行する。最後まで公開できない場合は、作成時のFile ID・単一link・ADSなし・内容を照合できた一時ファイルだけを同じhandleで削除し、結果が不明な失敗（1176・1177など）では新しいstateの唯一の写しとして保持する。インストーラーは更新状態の`phase`が`idle`以外なら、製品・更新状態を変えずに導入を拒否する。launcherは、更新準備のCLIが拒否した場合に標準出力の`error`本文を延期の文言へ含め、恒久的な拒否と一時的な延期を区別できるようにする。

導入mutexの鍵は、出荷済みのlauncher・インストーラー（`ToLowerInvariant()`・UTF-8・SHA-256）と互換を保つ。Rust側は.NETと同じ1文字単位の小文字化（U+0130は変えず、語末のΣもσにする）で作り、全コードポイントをPowerShell出力との総当たりで照合する。照合したのは.NET 11（PowerShell 7.7）だけで、別の.NETやICUの版では未検証である（.NET 11より新しいUnicode版で追加された大文字は.NETが変えないため変えない）。既知の制約として、導入先の綴り（8.3短縮名・`\\?\`・subst）がRustの正規化後の最終パスと異なる起動では、PowerShell側の鍵が一致せず排他が成立しない。排他が成立しない窓は、インストーラーが製品をコピーしている間に限る。launcherが所有印の`installRoot`を`-ine`で照合する処理も同じ綴りの違いで一致せず、その場合は更新を安全側に延期する（恒久的に延期しても製品は変わらない）。両者の鍵と正規化を新旧で変えると出荷済みの鍵との互換が崩れるため、PowerShell側は変更しない。

既存のWindowsクライアント向けにも、同一ZIPをR2へ配置してからGitHub Releaseへ添付する。固定配信先・資格情報・順序は[配布手順](docs/distribution.md)を参照する。

### macOSの起動時自動更新

導入はDeveloper ID署名と公証を確認した単一実行ファイルから行う。新規のprivateな配置を別名で用意し、同じ親の下へ上書きなしで公開する。管理対象のCLI・MCP・hook・キューworkerは配置ルートの`.prunlet-macos-update.lock`を共有する。配置済みの設定で起動したMCPだけが更新を試み、排他を取得できなければ更新を延期する。共用ロック取得後に世代を再照合し、入れ替わっていれば現行の実行ファイルへ引き継ぐ。

macOSとLinuxは`update::github`で同じGitHub Releaseを照合する。導入版より新しい安定版で、導入済みコミットの子孫かつ`main`に含まれるものを対象とし、配布assetの長さとSHA-256を確認する。macOSの配布ZIPは64 MiB以下で、`manifest.json`と`prunlet`の2項目、単一arm64 Mach-Oと実行ファイルのhashを照合する。候補を同じ`bin`ディレクトリに新規作成し、Developer ID・公証・実行ファイルが報告する版とコミットなどを確認してから、実体を再照合して名前を原子的に置換する。実行ファイルだけを交換できるため、設定・復元領域・Codex登録の切替を伴わない。取得・候補検証に失敗した場合は標準エラーへ理由を出し、現行のMCPを起動する。

### Linuxの起動時自動更新

管理済み配置のCLI・MCP・hookは配置ルートの`.prunlet-linux-update.lock`を共有する。公式実行ファイルを配置ルートの`config.json`でMCP起動したときにだけ、排他取得を試みる。別プロセスが配置を使用中なら更新を延期する。排他取得後も配置と実行ファイルの実体を照合する。

同じCPU向けのtar.gzは展開先のパスを作らずに解析し、`prunlet`・`manifest.json`の2項目、各上限、実行体の長さ・SHA-256・ELFのCPUを照合する。同じ`bin`に新しいinodeを作成し、同期した候補から版・コミット・CPUを読み返す。配置と新旧の実体を再照合して実行ファイルの名前を原子的に置き換える。共用ロックの取得後に世代が変わっていた入口は現行の実行体を起動する。取得・候補検証に失敗した場合は標準エラーへ理由を出し、現行のMCPを起動する。置換対象を実行ファイルだけに絞り、設定・復元領域・Codex登録を保持する。

## 製品と検証の境界

`Publish-Prunlet.ps1`は入力とCargo設定のビルド前後の一致を検査し、`build-manifest.json`に入力の指紋、toolchain、target、製品のSHA-256を記録する。検証ビルドでは同じ入力からCoreのlibtestプローブを生成し、別crateの`tools/prunlet-fixtures`と`tools/prunlet-support`がfixture DLLと補助CLIを供給する。これらのhashもmanifestに記録し、候補を検証時に照合する。障害注入はテスト用のCoreに限定し、製品exe・配布ZIPには検証入口やツールを含めない。Core境界の結果は製品CLI・MCP・hookの実プロセス検証と区別する。

Apple Siliconの配布ZIPは、実機で`Publish-PrunletMac.sh`が対象コミットからビルドし、Developer ID署名と公証を経てGitHub Releaseへ添付する。macOSのMach IPC・競合注入と更新用のGitHub応答置換は専用デバッグビルドに分離し、配布用には含めない。配布先と生成経路は[配布手順](docs/distribution.md)を参照する。

ビルドと検証の必須コマンドは[AGENTS.md](AGENTS.md#ビルドと検証)、検証範囲とfixtureの保持・清掃は[検証手順](docs/verification.md)を参照する。

## 依存更新の境界

`.github/dependabot.yml`はGitHub ActionsとCargoの更新を毎週月曜09:00（日本時間）に確認し、minor・patchをまとめ、majorは個別PRにする。`.github/workflows/dependency-validation.yml`はDependabotのPRまたは手動起動を対象に、Windows x64向けの検証ビルドを作り、`Verify-RecordlessFiles.ps1`へ製品exe・Coreプローブ・manifest・そのSHA-256を渡す。対象は記録なしファイル削除のCLI・MCP・hookと同じビルドのCoreケースである。レジストリ・移行・導入などの個別検証は別に行う。出力はrunnerの一時領域へ分離し、checkoutの認証情報を保持せず、権限はcontentsの読取りに限定する。
