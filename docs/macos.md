# macOSのビルドと初回導入

macOS版はRustのCLI・stdio MCP・hookと、macOSのネイティブなファイル削除処理を使用する。Windowsのレジストリ、native Windows session、タスクスケジューラの登録は提供しない。Windowsの公開更新ZIPとmacOSのビルド成果物は別の形式であり、相互に導入しない。

| 機能 | Windows | macOS |
| --- | --- | --- |
| ファイル操作のCLI・MCP・hook | 提供 | NSFileManagerのTrash操作を使用 |
| シンボリックリンク・Finder alias | Windowsの契約に従う | leafのentryを処理し、リンク先・alias targetは解決しない |
| 保護metadata・設定 | Windowsのprivate ACL | owner・private mode・既存extended ACLを検査 |
| 明示的な削除待機キュー | Windowsの共有違反・実体照合 | 協調する`flock`待機・実体照合 |
| レジストリ削除・復元・native session | 提供 | Windows専用として拒否 |
| 既存の公開ZIPによる起動時更新 | 提供 | 未提供 |
| 導入スクリプト | 既存導入の更新と保全に対応 | 新しいprivateディレクトリへの初回導入のみ |

## ファイル操作と保護の境界

CLI・MCP・hookは同じRust Coreを使用する。ファイルの元実体を`dev`・`ino`と保持したdescriptorで照合し、NSFileManagerから返されたTrash内のURLを元実体と照合する。照合できない結果は`ambiguous`として後続を停止する。永久削除・独自退避へのfallbackや、不明な処理の自動再送は行わない。

NSFileManagerのパスAPIは、ファイルIDを条件にした原子的なrenameを提供しない。最終確認とOS操作の間に、協調しない同じUIDのプロセスが名前を差し替える競合を完全には阻止できない。保持したdescriptorと返却URLの照合によって、確認できなかった操作を成功にしない。この制約を、あらゆるrename競合を原子的に排除する保証と読み替えない。

leafのシンボリックリンクはリンクentry自身をTrashへ移し、リンク先を走査しない。祖先のシンボリックリンクは拒否する。macOSの`/tmp`・`/var`・`/etc`は既知の実体への対応を明示検証した場合だけ祖先として解決する。Finder aliasは通常のファイルentryとして扱い、alias targetを開かない。

非公開ACLの検査は設定の親、metadata root、lock、作成する制御ファイルの境界へ適用する。既存の未知または空でないextended ACLを、権限を書き換えることで通過させない。利用者のpayload一般のACLを書き換えたり、一律に拒否したりする規則ではない。

通常の再帰削除は指定rootと親を固定し、子の個数を4096件で制限しない。削除待機キューは子と祖先をまとめて保持するため、descriptor数を`RLIMIT_NOFILE`と照合してから受付する。必要なdescriptorを確保できない場合は削除を開始しない。

## CLI・MCP・hookを使用する

所有する検証用ファイルのdry-runは次の形で実行する。通常の削除は`--dry-run`を除く。空白やUnicodeを含む複数対象はUTF-8のJSON配列を`--paths-file <絶対パス>`で渡せる。

```bash
/Users/example/.local/share/Prunlet/bin/prunlet \
  --config /Users/example/.local/share/Prunlet/config.json \
  delete --dry-run -- /Users/example/prunlet-fixture/example.txt
```

ディレクトリの再帰処理は`delete --recursive -- <絶対パス>`、待機キューは`delete-queue [--recursive] -- <絶対パス>`を使用する。受付結果の`jobId`を使い、`delete-queue-status <jobId>`で最終結果まで確認する。`delete-queue-cancel <jobId>`は`pending`の間だけ受理する。

macOSで待機するのは、Prunletと同じ協調的な`flock`を保持する処理である。通常の`open`や`mmap`でファイルを利用しているだけのプロセスを待つ保証はない。キューは1要求256パス、入力1 MiB、対象と祖先・全子の固定合計4096、同じUIDのAqua・SSHを通じて8枠を上限とし、結果を1時間保持する。プロセスやIPCを失った後の`unavailable`は結果不明を意味し、同じ削除を自動で再送しない。

stdio MCPは同じCLIへ`--config <絶対設定パス> mcp`を渡す。`delete_files`の例は次のとおり。登録の形は後述する。

```json
{"name":"delete_files","arguments":{"paths":["/Users/example/prunlet-fixture/example.txt"],"dryRun":true}}
```

hookは`prunlet-hook --config <絶対設定パス> hook --cli-executable <絶対CLIパス>`へホストのhook JSONを標準入力で渡し、出力JSONの判断をホストが使用する。検査するコマンド文字列を別のshellで実行しない。次の例はJSONをhookへ渡すだけである。

```bash
printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"rm /Users/example/prunlet-fixture/example.txt"}}' | \
  /Users/example/.local/share/Prunlet/bin/prunlet-hook \
  --config /Users/example/.local/share/Prunlet/config.json \
  hook --cli-executable /Users/example/.local/share/Prunlet/bin/prunlet
```

レジストリの削除・復元・Windows native sessionとWindows公開更新プロトコルはmacOSでは非対応として失敗を返す。Windows用ツールが成功したような応答を返す互換stubは使用しない。

## 必要な環境

macOS、Xcode Command Line Tools、`rust-toolchain.toml`指定のRust、Python 3.9以降を使用する。Rustの対象はApple Siliconが`aarch64-apple-darwin`、Intelが`x86_64-apple-darwin`である。必要なRust targetは事前に導入する。スクリプトはシステムのPATH、キーチェーン、ログイン項目、実際のCodex設定を変更しない。

`osx-arm64`と`osx-x64`はこのビルドスクリプトの選択値であり、Windows更新manifestのruntimeへ追加した値ではない。クロスビルドができても、対象CPUでの実行確認を代替しない。

## ソースからビルドする

ソースを読み取れる場所と、ソース・Codex homeの外にある新しい絶対出力先を指定する。出力先と祖先のシンボリックリンクは拒否する。

```bash
bash scripts/Publish-PrunletMac.sh \
  --output-directory "$HOME/prunlet-build-20261103" \
  --runtime osx-arm64
```

成果物は`<出力先>/publish/prunlet`、`prunlet-maintenance`、`prunlet-hook`である。hookはCLIの同じバイナリをコピーし、SHA-256の一致とMach-OのCPU種別を検査する。Cargo targetと一時出力も出力先へ隔離する。共有する外部Cargo cacheを指定する場合は`--target-directory <絶対パス>`を使う。`CARGO_HOME`と`RUSTUP_HOME`は既存の環境を使用する。

`--source-commit <40桁SHA>`は呼出元が確認したビルド元を渡す引数であり、未コミットの作業ツリーがそのSHAそのものであることを証明しない。配布用の署名・公証・アップロードをこのスクリプトで自動実行しない。

## GitHub既定ブランチの最新HEADを初回導入する

未使用の導入先と作業先を指定する。既定のリポジトリは`1llum1n4t1s/Prunlet`である。

```bash
bash scripts/Install-PrunletMac.sh \
  --install-directory "$HOME/.local/share/Prunlet" \
  --work-directory "$HOME/prunlet-install-20261103" \
  --runtime osx-arm64
```

この経路はGitHub APIで既定ブランチとHEADを解決し、そのコミットのソースZIPを取得してビルドする。ローカルクローンをlatest導入の代用にしない。ZIPは全エントリのパス・重複・リンク・個数・容量を確認してから展開する。`source-info.json`へリポジトリ、ブランチ、コミット、取得URL、ソースZIP全体と3製品のSHA-256、runtimeを保存する。

導入先は新規でなければ拒否する。既存の設定・ACL・製品を上書きしない。設定は実際の候補CLIの`init`で検証・作成し、privateな導入先の`config.json`を使用する。既定のmetadataは`<導入先>/recovery`である。別のprivateディレクトリを使用する場合は`--backup-directory <絶対パス>`を指定する。

ビルド・導入スクリプトも新規ディレクトリは0700、制御ファイルは0600と空ACL・継承遮断を作成時に指定し、実行製品だけ0700で作る。既存の作業・targetディレクトリは所有者、private mode、extended ACLを検査し、未知のACLを変更して利用しない。ソース入力も所有者、他者による書込み、リンクとextended ACLを検査してから候補を実行する。通常のホームディレクトリ祖先にある継承されないdeny-delete ACLを、新規private leafのACLと混同しない。

privateなleafだけでは共有親からの名前差替えを防げないため、スクリプトは使用するsource・出力・target・導入・制御ファイルの祖先もrootから検査する。祖先の所有者はrootまたは実効UIDに限定し、他者の書込み可能な親やallow・未知のextended ACLは拒否する。既知の非継承deny ACEは権限を増やさないため祖先でのみ許可する。sticky親の例外は、その親と直下の子がrootまたは実効UID所有で、ACLによる追加権限がない場合に限る。協調しない同じUIDやrootによる変更を排除する保証ではない。

公開HEADにmacOSのRust用manifest・スクリプトがまだ含まれない場合は、導入可能なソースではないとして停止する。作業ツリーのfixtureでの成功と、公開HEADからの導入成功は別の検証結果である。失敗した作業先は診断のため保持し、自動で清掃・再利用しない。別の未使用作業先で再実行する。

MCP登録を行う場合は、クライアントに次の内容を明示的に設定する。パスを実際の導入先へ置き換える。

```json
{
  "mcpServers": {
    "prunlet": {
      "command": "/Users/example/.local/share/Prunlet/bin/prunlet",
      "args": ["--config", "/Users/example/.local/share/Prunlet/config.json", "mcp"]
    }
  }
}
```

## 既存macOS導入を残して次の版へ切り替える

macOSの自動更新と既存導入先への上書き更新は未提供である。次の候補は別の新しい導入先、または別のビルド出力先へ作る。候補CLIに既存設定の絶対パスを明示して、所有する検証用ファイルへのdry-runとMCP接続を確認する。

```bash
/Users/example/prunlet-next/publish/prunlet \
  --config /Users/example/.local/share/Prunlet/config.json \
  delete --dry-run -- /Users/example/prunlet-fixture/example.txt
```

確認後にMCPの`command`を候補CLIの絶対パスへ変更し、`--config`は既存の設定へ向けたままにする。既存設定をコピー・変換・上書きせず、同じmetadataを明示的に参照する。旧CLIを使用するMCPや待機workerが残る場合はクライアント側の通常の停止・再接続手順で終了を確認する。旧導入先は復帰できるよう保持し、この切替手順から削除しない。


## ネイティブ検証の4経路

次の3本のPython runnerとRust libtestを分けて実行する。すべて同じ不変更ソースに対応するartifactの絶対パスと、祖先にもリンクがない新しい外部出力先を使う。Python runnerの共通必須引数は `--executable <artifact>`・`--source-root <不変更source>`・`--output-directory <未使用の絶対path>`で、結果は各出力先の`report.json`へ保存する。`failed == 0`だけでなく、`passed == cases.length`・ケースcatalog・artifact SHA・ソースfingerprint・実際のCLI/MCP終了コードを照合する。

| 経路 | 実行するartifactと入力 | 判定する範囲 |
| --- | --- | --- |
| `Verify-MacRecordlessFiles.py` | 通常のrelease CLI。`--artifact-profile release`を明示し、`--race-tests`を付けない | 通常23ケース。実Trash/CLI/MCP/hook。専用cfg文字列を含まないartifactを使う |
| `Verify-MacQueueIpc.py` | `RUSTFLAGS='--cfg prunlet_macos_race_tests'`で作ったdebug CLI | 専用cfgの17ケース。隔離IPC namespace、短縮保持期限、故障注入を使い、通常release結果として扱わない |
| `Verify-MacRaceBoundaries.py` | 同じ専用cfgのdebug CLI | 3つのrace境界。専用cfgの成功は通常CLIの結果と分ける |
| Rust libtest `platform::macos` | 通常cfgの `cargo test --locked --lib --no-run --message-format=json` が返すtest executable | 現行catalogはMach資源6・alias1・directory scan2の9件。以前の資源7件の結果に追加2件を合算せず、最終artifactの実数と成功を確認する |

例えば、ソース・出力先をそれぞれ`$source`・`$work`へ絶対パスで固定した場合、通常artifactは`Publish-PrunletMac.sh --output-directory "$work/ordinary"`で作り、次を実行する。`$work`は既存の外部親ディレクトリ、各子出力先は未使用とする。

```bash
mkdir "$work/temp"
export TMPDIR="$work/temp"
env -u RUSTFLAGS -u CARGO_ENCODED_RUSTFLAGS bash "$source/scripts/Publish-PrunletMac.sh" \
  --output-directory "$work/ordinary" --runtime osx-arm64
python3 "$source/scripts/Verify-MacRecordlessFiles.py" \
  --executable "$work/ordinary/publish/prunlet" --artifact-profile release \
  --source-root "$source" --output-directory "$work/ordinary-e2e"

cd "$source"
env -u CARGO_ENCODED_RUSTFLAGS CARGO_TARGET_DIR="$work/race-target" RUSTFLAGS='--cfg prunlet_macos_race_tests' \
  cargo build --locked --bin prunlet
python3 scripts/Verify-MacQueueIpc.py --executable "$work/race-target/debug/prunlet" \
  --source-root "$source" --output-directory "$work/queue-cfg-e2e"
python3 scripts/Verify-MacRaceBoundaries.py --executable "$work/race-target/debug/prunlet" \
  --source-root "$source" --output-directory "$work/race-cfg-e2e"

env -u RUSTFLAGS -u CARGO_ENCODED_RUSTFLAGS CARGO_TARGET_DIR="$work/libtest-target" cargo test --locked --lib --no-run \
  --message-format=json > "$work/libtest-build.jsonl"
libtest=$(python3 -c 'import json,sys; a=[x["executable"] for line in open(sys.argv[1]) if (x:=json.loads(line)).get("reason")=="compiler-artifact" and x.get("profile",{}).get("test") and "lib" in x.get("target",{}).get("kind",[]) and x.get("executable")]; assert len(a)==1; print(a[0])' "$work/libtest-build.jsonl")
"$libtest" platform::macos --test-threads=1 > "$work/libtest-result.log" 2>&1
```

ビルドのTEMP/TMPまたはTMPDIRも、既存ソースやCodex homeの外へ隔離する。通常buildとlibtestでは`RUSTFLAGS`から専用cfgを外し、targetを分離する。`Verify-MacRecordlessFiles.py --race-tests`は専用cfg artifactを渡す別モードで、上表の通常release検証の代わりにはしない。`--artifact-profile`は申告値であり、runner内の`artifactProfileDeclared`や`runtimeCfg`表記だけからrelease最適化を証明せず、ビルドcommandとartifact SHAも対応付ける。
