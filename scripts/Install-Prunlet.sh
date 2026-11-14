#!/bin/bash
# Apple Silicon MacへPrunletを導入する。最新の安定版Releaseから署名・公証済みの配布物を取得し、
# サイズ・SHA-256・Developer ID・公証を照合してから `prunlet --install-macos` で配置する。
# 既に導入済みの場合は何も変更しない（更新はMCPの起動時自動更新が行う）。MCPホストへの登録は行わず、
# 登録に使う設定行だけを表示する（設定ファイルの書換えは利用者が判断する）。
set -euo pipefail
umask 077

repository='1llum1n4t1s/Prunlet'
root="$HOME/.local/share/Prunlet"
tag=''
dry_run=0
asset='prunlet-update-osx-arm64.zip'
team_id='SL228Y8UUR'

usage() {
    cat <<'EOF'
Usage: Install-Prunlet.sh [--install-dir <absolute path>] [--tag vX.Y.Z] [--repository owner/repo] [--dry-run]

  --install-dir  導入先（既定: $HOME/.local/share/Prunlet。存在しないディレクトリだけ使える）
  --tag          導入する版（既定: 最新の安定版）
  --dry-run      取得元・版・配布物を確認して表示し、ダウンロードも導入もしない
環境変数 GH_TOKEN があれば、GitHub APIの認証に使う（未認証の呼出し枠が尽きた場合）。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-dir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; root="$2"; shift 2 ;;
        --tag) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; tag="$2"; shift 2 ;;
        --repository) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; repository="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

fail() { printf 'Install-Prunlet: %s\n' "$1" >&2; exit 1; }

[ "$(uname -sm)" = 'Darwin arm64' ] || fail 'Apple Silicon Mac (Darwin arm64) でのみ実行できます。'
case "$root" in
    /*) ;;
    *) fail '導入先は絶対パスで指定してください。' ;;
esac
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'repositoryの形式が正しくありません。'
if [ -n "$tag" ] && [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then fail 'tagは vX.Y.Z の形式で指定してください。'; fi

if [ -e "$root" ] || [ -L "$root" ]; then
    printf '既に導入済みです: %s\n' "$root"
    printf '更新はMCPの起動時自動更新が行います。このスクリプトは既存の導入先を変更しません。\n'
    exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/prunlet-install.XXXXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

if [ -n "$tag" ]; then endpoint="releases/tags/$tag"; else endpoint='releases/latest'; fi
curl_api=(curl -fsS --proto '=https' --tlsv1.2 --max-time 60 -H 'Accept: application/vnd.github+json')
if [ -n "${GH_TOKEN:-}" ]; then curl_api+=(-H "Authorization: Bearer $GH_TOKEN"); fi
"${curl_api[@]}" "https://api.github.com/repos/$repository/$endpoint" -o "$work/release.json" \
    || fail 'GitHub APIからReleaseを取得できませんでした（未認証の枠切れなら GH_TOKEN を設定してください）。'

# JSONはmacOS標準のJavaScript for Automationで読む（追加ツール不要）。
parsed="$(/usr/bin/osascript -l JavaScript -e '
ObjC.import("Foundation");
function run(argv) {
  var text = $.NSString.stringWithContentsOfFileEncodingError($(argv[0]), $.NSUTF8StringEncoding, null).js;
  var r = JSON.parse(text);
  var matches = (r.assets || []).filter(function (a) { return a.name === argv[1]; });
  if (matches.length !== 1) { throw new Error("asset count " + matches.length); }
  var a = matches[0];
  return [r.tag_name, r.draft, r.prerelease, a.browser_download_url, a.size, a.digest].join("\t");
}' "$work/release.json" "$asset" 2>/dev/null)" || fail "Releaseに ${asset} が1つだけ添付されていることを確認できませんでした。"

IFS=$'\t' read -r release_tag draft prerelease url size digest <<<"$parsed"
[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Releaseのtagが想定した形式ではありません。'
[ "$draft" = 'false' ] && [ "$prerelease" = 'false' ] || fail '安定版として公開されたReleaseではありません。'
[ -z "$tag" ] || [ "$tag" = "$release_tag" ] || fail '指定したtagとReleaseのtagが一致しません。'
[[ "$url" == "https://github.com/$repository/releases/download/$release_tag/$asset" ]] || fail '配布物のURLが想定した形式ではありません。'
[[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && [ "$size" -le 67108864 ] || fail '配布物のサイズが想定の範囲外です。'
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'GitHubが返した配布物のSHA-256を確認できません。'
expected_sha="${digest#sha256:}"

printf 'repository : %s\nrelease    : %s\nasset      : %s (%s bytes)\nsha256     : %s\ninstall dir: %s\n' \
    "$repository" "$release_tag" "$asset" "$size" "$expected_sha" "$root"
if [ "$dry_run" -eq 1 ]; then
    printf '(--dry-run: ダウンロードも導入も行いません)\n'
    exit 0
fi

curl -fsSL --proto '=https' --tlsv1.2 --max-time 300 --max-filesize "$size" "$url" -o "$work/$asset" \
    || fail '配布物をダウンロードできませんでした。'
actual_size="$(stat -f %z "$work/$asset")"
actual_sha="$(/usr/bin/shasum -a 256 "$work/$asset" | awk '{print $1}')"
[ "$actual_size" = "$size" ] && [ "$actual_sha" = "$expected_sha" ] || fail 'ダウンロードした配布物のサイズ・SHA-256がGitHubの記録と一致しません。'

mkdir "$work/extracted"
/usr/bin/ditto -x -k "$work/$asset" "$work/extracted"
exe="$work/extracted/prunlet"
[ -f "$exe" ] && [ ! -L "$exe" ] || fail '配布物に prunlet が含まれていません。'
chmod 700 "$exe"
[ "$(/usr/bin/lipo -archs "$exe")" = 'arm64' ] || fail '実行ファイルがarm64ではありません。'
requirement="=anchor apple generic and identifier \"com.kagayoi.prunlet\" and certificate leaf[subject.OU] = \"$team_id\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and notarized"
# 初回は公証チケットが端末にまだ無く、`notarized` の要件が一度失敗することがある。spctlの照会でAppleから
# チケットを取得してから再検証する。要件は緩めず、3回続けて満たせなければ導入しない。
verified=0
for attempt in 1 2 3; do
    if /usr/bin/codesign --verify --strict -R "$requirement" "$exe" 2>/dev/null; then verified=1; break; fi
    /usr/sbin/spctl -a -vv -t install "$exe" >/dev/null 2>&1 || true
    sleep 3
done
[ "$verified" -eq 1 ] || fail 'Developer ID署名・公証の検証に失敗しました（ネットワークでAppleの公証チケットを取得できるか確認してください）。'

mkdir -p "$(dirname "$root")"
"$exe" --install-macos "$root"

cat <<EOF

導入しました: $root
MCPホストに登録する場合は、次の設定を使います（このスクリプトは設定ファイルを変更しません）。

[Codex の config.toml]
[mcp_servers.prunlet]
command = "$root/bin/prunlet"
args = ["--config", "$root/config.json", "mcp"]
startup_timeout_sec = 90

[CLIの例]
"$root/bin/prunlet" --config "$root/config.json" delete --dry-run -- <所有するファイルの絶対パス>
EOF
