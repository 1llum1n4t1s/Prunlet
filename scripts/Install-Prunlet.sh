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

# 人が読む案内・エラーを利用者の言語で出す（D:\Dev\APP-DISTRIBUTION.md「8. ローカライズ」と同じ規則）。
# 言語は PRUNLET_LANGUAGE → LC_ALL → LC_MESSAGES → LANG（空・C・POSIX は飛ばす）→ macOS の AppleLanguages の先頭
# → 英語の順で決める。キーは英語の原文で、英語・未対応の言語・辞書に無いキーでは原文をそのまま出す。
# macOS 標準の bash 3.2 で動くよう、連想配列を使わずに下の表を順に引く。
prunlet_language_tag() {
    local base rest
    local upper='ABCDEFGHIJKLMNOPQRSTUVWXYZ' lower='abcdefghijklmnopqrstuvwxyz' prefix char index
    # ASCII の英字だけを小文字にする（bash 3.2 には ${var,,} が無く、子プロセスも起動しない）。
    base=''
    for ((index = 0; index < ${#1}; index++)); do
        char="${1:index:1}"
        case "$char" in
            [ABCDEFGHIJKLMNOPQRSTUVWXYZ]) prefix="${upper%%"$char"*}"; char="${lower:${#prefix}:1}" ;;
        esac
        base+="$char"
    done
    base="${base%%.*}"
    base="${base%%@*}"
    base="${base//_/-}"
    base="${base#"${base%%[![:space:]]*}"}"
    base="${base%"${base##*[![:space:]]}"}"
    case "$base" in
        ''|c|posix) return 1 ;;
    esac
    case "$base" in
        ja|ja-*|japanese*) printf 'ja' ;;
        zh|zh-*)
            rest="${base#zh}-"
            case "$rest" in
                *-hant-*) printf 'zh-TW' ;;
                *-hans-*) printf 'zh-CN' ;;
                *-tw-*|*-hk-*|*-mo-*) printf 'zh-TW' ;;
                *) printf 'zh-CN' ;;
            esac ;;
        chinese*)
            case "$base" in
                *traditional*|*taiwan*|*hong\ kong*|*macao*|*macau*) printf 'zh-TW' ;;
                *) printf 'zh-CN' ;;
            esac ;;
        ko|ko-*|korean*) printf 'ko' ;;
        es|es-*|spanish*) printf 'es' ;;
        fr|fr-*|french*) printf 'fr' ;;
        de|de-*|german*) printf 'de' ;;
        pt|pt-*|portuguese*) printf 'pt-BR' ;;
        *) printf 'en' ;;
    esac
}

prunlet_detect_language() {
    local value found
    for value in "${PRUNLET_LANGUAGE:-}" "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
        if found="$(prunlet_language_tag "$value")"; then printf '%s' "$found"; return; fi
    done
    # GUI から起動された端末などでは LANG が無いことがあるため、OS の言語順の先頭を読む。
    value="$(/usr/bin/defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ",' || true)"
    if found="$(prunlet_language_tag "$value")"; then printf '%s' "$found"; return; fi
    printf 'en'
}

ui_language="$(prunlet_detect_language)"

# 英語の原文キーを現在の言語の文言へ変える。表は「言語タグ<TAB>英語の原文<TAB>訳文」の1行1件で、
# tests/localization.rs がキー集合・プレースホルダー・コードが参照するキーを照合する。
t() {
    local entry_language entry_key entry_value
    if [ "$ui_language" != en ]; then
        while IFS=$'\t' read -r entry_language entry_key entry_value; do
            if [ "$entry_language" = "$ui_language" ] && [ "$entry_key" = "$1" ]; then
                printf '%s' "$entry_value"
                return
            fi
        done <<'PRUNLET_MESSAGES'
ja	  --install-dir  Install directory (default: $HOME/.local/share/Prunlet; only a directory that does not exist yet can be used)	  --install-dir  導入先（既定: $HOME/.local/share/Prunlet。存在しないディレクトリだけ使える）
ja	  --tag          Version to install (default: the latest stable release)	  --tag          導入する版（既定: 最新の安定版）
ja	  --dry-run      Check and show the source, version and package without downloading or installing	  --dry-run      取得元・版・配布物を確認して表示し、ダウンロードも導入もしない
ja	If the GH_TOKEN environment variable is set, it is used to authenticate GitHub API requests (when the unauthenticated rate limit is exhausted).	環境変数 GH_TOKEN があれば、GitHub APIの認証に使う（未認証の呼出し枠が尽きた場合）。
ja	Can only run on an Apple Silicon Mac (Darwin arm64).	Apple Silicon Mac (Darwin arm64) でのみ実行できます。
ja	Specify the install directory as an absolute path.	導入先は絶対パスで指定してください。
ja	The repository format is invalid.	repositoryの形式が正しくありません。
ja	Specify the tag in the form vX.Y.Z.	tagは vX.Y.Z の形式で指定してください。
ja	Already installed: {root}	既に導入済みです: {root}
ja	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	更新はMCPの起動時自動更新が行います。このスクリプトは既存の導入先を変更しません。
ja	Could not get the release from the GitHub API (if the unauthenticated rate limit is exhausted, set GH_TOKEN).	GitHub APIからReleaseを取得できませんでした（未認証の枠切れなら GH_TOKEN を設定してください）。
ja	Could not confirm that exactly one {asset} is attached to the release.	Releaseに {asset} が1つだけ添付されていることを確認できませんでした。
ja	The release tag is not in the expected format.	Releaseのtagが想定した形式ではありません。
ja	The release is not published as a stable release.	安定版として公開されたReleaseではありません。
ja	The specified tag does not match the release tag.	指定したtagとReleaseのtagが一致しません。
ja	The package URL is not in the expected format.	配布物のURLが想定した形式ではありません。
ja	The package size is outside the expected range.	配布物のサイズが想定の範囲外です。
ja	Could not confirm the package SHA-256 returned by GitHub.	GitHubが返した配布物のSHA-256を確認できません。
ja	(--dry-run: nothing is downloaded or installed)	(--dry-run: ダウンロードも導入も行いません)
ja	Could not download the package.	配布物をダウンロードできませんでした。
ja	The size or SHA-256 of the downloaded package does not match the GitHub record.	ダウンロードした配布物のサイズ・SHA-256がGitHubの記録と一致しません。
ja	The package does not contain prunlet.	配布物に prunlet が含まれていません。
ja	The executable is not arm64.	実行ファイルがarm64ではありません。
ja	Developer ID signature and notarization verification failed (check that the Apple notarization ticket can be fetched over the network).	Developer ID署名・公証の検証に失敗しました（ネットワークでAppleの公証チケットを取得できるか確認してください）。
ja	Installed: {root}	導入しました: {root}
ja	To register it with an MCP host, use the following settings (this script does not change configuration files).	MCPホストに登録する場合は、次の設定を使います（このスクリプトは設定ファイルを変更しません）。
ja	[Codex config.toml]	[Codex の config.toml]
ja	[CLI example]	[CLIの例]
ja	<absolute path of a file you own>	<所有するファイルの絶対パス>
zh-CN	  --install-dir  Install directory (default: $HOME/.local/share/Prunlet; only a directory that does not exist yet can be used)	  --install-dir  安装目录（默认：$HOME/.local/share/Prunlet；只能使用尚不存在的目录）
zh-CN	  --tag          Version to install (default: the latest stable release)	  --tag          要安装的版本（默认：最新稳定版）
zh-CN	  --dry-run      Check and show the source, version and package without downloading or installing	  --dry-run      检查并显示来源、版本和软件包，不下载也不安装
zh-CN	If the GH_TOKEN environment variable is set, it is used to authenticate GitHub API requests (when the unauthenticated rate limit is exhausted).	如果设置了环境变量 GH_TOKEN，则用于 GitHub API 认证（在未认证的调用额度用尽时）。
zh-CN	Can only run on an Apple Silicon Mac (Darwin arm64).	只能在 Apple Silicon Mac (Darwin arm64) 上运行。
zh-CN	Specify the install directory as an absolute path.	请以绝对路径指定安装目录。
zh-CN	The repository format is invalid.	repository 的格式不正确。
zh-CN	Specify the tag in the form vX.Y.Z.	请以 vX.Y.Z 的格式指定 tag。
zh-CN	Already installed: {root}	已经安装：{root}
zh-CN	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	更新由 MCP 的启动时自动更新完成。此脚本不会更改现有安装。
zh-CN	Could not get the release from the GitHub API (if the unauthenticated rate limit is exhausted, set GH_TOKEN).	无法从 GitHub API 获取 Release（如果是未认证额度用尽，请设置 GH_TOKEN）。
zh-CN	Could not confirm that exactly one {asset} is attached to the release.	无法确认 Release 中只附加了一个 {asset}。
zh-CN	The release tag is not in the expected format.	Release 的 tag 不是预期的格式。
zh-CN	The release is not published as a stable release.	该 Release 不是以稳定版发布的。
zh-CN	The specified tag does not match the release tag.	指定的 tag 与 Release 的 tag 不一致。
zh-CN	The package URL is not in the expected format.	软件包的 URL 不是预期的格式。
zh-CN	The package size is outside the expected range.	软件包的大小超出预期范围。
zh-CN	Could not confirm the package SHA-256 returned by GitHub.	无法确认 GitHub 返回的软件包 SHA-256。
zh-CN	(--dry-run: nothing is downloaded or installed)	(--dry-run：不下载也不安装)
zh-CN	Could not download the package.	无法下载软件包。
zh-CN	The size or SHA-256 of the downloaded package does not match the GitHub record.	下载的软件包的大小或 SHA-256 与 GitHub 的记录不一致。
zh-CN	The package does not contain prunlet.	软件包中不包含 prunlet。
zh-CN	The executable is not arm64.	可执行文件不是 arm64。
zh-CN	Developer ID signature and notarization verification failed (check that the Apple notarization ticket can be fetched over the network).	Developer ID 签名和公证验证失败（请确认能否通过网络获取 Apple 的公证票据）。
zh-CN	Installed: {root}	已安装：{root}
zh-CN	To register it with an MCP host, use the following settings (this script does not change configuration files).	如需注册到 MCP 主机，请使用以下设置（此脚本不会更改配置文件）。
zh-CN	[Codex config.toml]	[Codex 的 config.toml]
zh-CN	[CLI example]	[CLI 示例]
zh-CN	<absolute path of a file you own>	<你拥有的文件的绝对路径>
zh-TW	  --install-dir  Install directory (default: $HOME/.local/share/Prunlet; only a directory that does not exist yet can be used)	  --install-dir  安裝目錄（預設：$HOME/.local/share/Prunlet；只能使用尚不存在的目錄）
zh-TW	  --tag          Version to install (default: the latest stable release)	  --tag          要安裝的版本（預設：最新穩定版）
zh-TW	  --dry-run      Check and show the source, version and package without downloading or installing	  --dry-run      檢查並顯示來源、版本和套件，不下載也不安裝
zh-TW	If the GH_TOKEN environment variable is set, it is used to authenticate GitHub API requests (when the unauthenticated rate limit is exhausted).	若設定了環境變數 GH_TOKEN，則用於 GitHub API 驗證（在未驗證的呼叫額度用盡時）。
zh-TW	Can only run on an Apple Silicon Mac (Darwin arm64).	只能在 Apple Silicon Mac (Darwin arm64) 上執行。
zh-TW	Specify the install directory as an absolute path.	請以絕對路徑指定安裝目錄。
zh-TW	The repository format is invalid.	repository 的格式不正確。
zh-TW	Specify the tag in the form vX.Y.Z.	請以 vX.Y.Z 的格式指定 tag。
zh-TW	Already installed: {root}	已經安裝：{root}
zh-TW	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	更新由 MCP 的啟動時自動更新完成。此指令碼不會變更現有的安裝。
zh-TW	Could not get the release from the GitHub API (if the unauthenticated rate limit is exhausted, set GH_TOKEN).	無法從 GitHub API 取得 Release（若是未驗證額度用盡，請設定 GH_TOKEN）。
zh-TW	Could not confirm that exactly one {asset} is attached to the release.	無法確認 Release 中只附加了一個 {asset}。
zh-TW	The release tag is not in the expected format.	Release 的 tag 不是預期的格式。
zh-TW	The release is not published as a stable release.	該 Release 不是以穩定版發布的。
zh-TW	The specified tag does not match the release tag.	指定的 tag 與 Release 的 tag 不一致。
zh-TW	The package URL is not in the expected format.	套件的 URL 不是預期的格式。
zh-TW	The package size is outside the expected range.	套件的大小超出預期範圍。
zh-TW	Could not confirm the package SHA-256 returned by GitHub.	無法確認 GitHub 傳回的套件 SHA-256。
zh-TW	(--dry-run: nothing is downloaded or installed)	(--dry-run：不下載也不安裝)
zh-TW	Could not download the package.	無法下載套件。
zh-TW	The size or SHA-256 of the downloaded package does not match the GitHub record.	下載的套件的大小或 SHA-256 與 GitHub 的紀錄不一致。
zh-TW	The package does not contain prunlet.	套件中不包含 prunlet。
zh-TW	The executable is not arm64.	執行檔不是 arm64。
zh-TW	Developer ID signature and notarization verification failed (check that the Apple notarization ticket can be fetched over the network).	Developer ID 簽署與公證驗證失敗（請確認能否透過網路取得 Apple 的公證票證）。
zh-TW	Installed: {root}	已安裝：{root}
zh-TW	To register it with an MCP host, use the following settings (this script does not change configuration files).	若要註冊到 MCP 主機，請使用以下設定（此指令碼不會變更設定檔）。
zh-TW	[Codex config.toml]	[Codex 的 config.toml]
zh-TW	[CLI example]	[CLI 範例]
zh-TW	<absolute path of a file you own>	<您擁有的檔案的絕對路徑>
ko	  --install-dir  Install directory (default: $HOME/.local/share/Prunlet; only a directory that does not exist yet can be used)	  --install-dir  설치 디렉터리(기본값: $HOME/.local/share/Prunlet. 아직 존재하지 않는 디렉터리만 사용 가능)
ko	  --tag          Version to install (default: the latest stable release)	  --tag          설치할 버전(기본값: 최신 안정 버전)
ko	  --dry-run      Check and show the source, version and package without downloading or installing	  --dry-run      다운로드나 설치 없이 원본, 버전, 패키지를 확인하여 표시
ko	If the GH_TOKEN environment variable is set, it is used to authenticate GitHub API requests (when the unauthenticated rate limit is exhausted).	환경 변수 GH_TOKEN이 설정되어 있으면 GitHub API 인증에 사용합니다(인증되지 않은 호출 한도를 모두 사용한 경우).
ko	Can only run on an Apple Silicon Mac (Darwin arm64).	Apple Silicon Mac (Darwin arm64)에서만 실행할 수 있습니다.
ko	Specify the install directory as an absolute path.	설치 디렉터리를 절대 경로로 지정하십시오.
ko	The repository format is invalid.	repository 형식이 올바르지 않습니다.
ko	Specify the tag in the form vX.Y.Z.	tag는 vX.Y.Z 형식으로 지정하십시오.
ko	Already installed: {root}	이미 설치되어 있습니다: {root}
ko	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	업데이트는 MCP 시작 시 자동 업데이트가 수행합니다. 이 스크립트는 기존 설치를 변경하지 않습니다.
ko	Could not get the release from the GitHub API (if the unauthenticated rate limit is exhausted, set GH_TOKEN).	GitHub API에서 Release를 가져올 수 없습니다(인증되지 않은 한도를 모두 사용했다면 GH_TOKEN을 설정하십시오).
ko	Could not confirm that exactly one {asset} is attached to the release.	Release에 {asset}이(가) 하나만 첨부되어 있는지 확인할 수 없습니다.
ko	The release tag is not in the expected format.	Release의 tag가 예상한 형식이 아닙니다.
ko	The release is not published as a stable release.	안정 버전으로 게시된 Release가 아닙니다.
ko	The specified tag does not match the release tag.	지정한 tag와 Release의 tag가 일치하지 않습니다.
ko	The package URL is not in the expected format.	패키지 URL이 예상한 형식이 아닙니다.
ko	The package size is outside the expected range.	패키지 크기가 예상 범위를 벗어났습니다.
ko	Could not confirm the package SHA-256 returned by GitHub.	GitHub가 반환한 패키지의 SHA-256을 확인할 수 없습니다.
ko	(--dry-run: nothing is downloaded or installed)	(--dry-run: 다운로드도 설치도 하지 않습니다)
ko	Could not download the package.	패키지를 다운로드할 수 없습니다.
ko	The size or SHA-256 of the downloaded package does not match the GitHub record.	다운로드한 패키지의 크기 또는 SHA-256이 GitHub 기록과 일치하지 않습니다.
ko	The package does not contain prunlet.	패키지에 prunlet이 포함되어 있지 않습니다.
ko	The executable is not arm64.	실행 파일이 arm64가 아닙니다.
ko	Developer ID signature and notarization verification failed (check that the Apple notarization ticket can be fetched over the network).	Developer ID 서명 및 공증 확인에 실패했습니다(네트워크로 Apple 공증 티켓을 가져올 수 있는지 확인하십시오).
ko	Installed: {root}	설치했습니다: {root}
ko	To register it with an MCP host, use the following settings (this script does not change configuration files).	MCP 호스트에 등록하려면 다음 설정을 사용하십시오(이 스크립트는 구성 파일을 변경하지 않습니다).
ko	[Codex config.toml]	[Codex config.toml]
ko	[CLI example]	[CLI 예시]
ko	<absolute path of a file you own>	<소유한 파일의 절대 경로>
es	  --install-dir  Install directory (default: $HOME/.local/share/Prunlet; only a directory that does not exist yet can be used)	  --install-dir  Directorio de instalación (predeterminado: $HOME/.local/share/Prunlet; solo se puede usar un directorio que aún no exista)
es	  --tag          Version to install (default: the latest stable release)	  --tag          Versión que se instalará (predeterminado: la release estable más reciente)
es	  --dry-run      Check and show the source, version and package without downloading or installing	  --dry-run      Comprueba y muestra el origen, la versión y el paquete sin descargar ni instalar
es	If the GH_TOKEN environment variable is set, it is used to authenticate GitHub API requests (when the unauthenticated rate limit is exhausted).	Si la variable de entorno GH_TOKEN está definida, se usa para autenticar las solicitudes a la API de GitHub (cuando se agota el límite sin autenticación).
es	Can only run on an Apple Silicon Mac (Darwin arm64).	Solo se puede ejecutar en un Mac con Apple Silicon (Darwin arm64).
es	Specify the install directory as an absolute path.	Indique el directorio de instalación como ruta absoluta.
es	The repository format is invalid.	El formato de repository no es válido.
es	Specify the tag in the form vX.Y.Z.	Indique el tag con el formato vX.Y.Z.
es	Already installed: {root}	Ya está instalado: {root}
es	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	Las actualizaciones las aplica la actualización automática al iniciar el MCP. Este script no cambia una instalación existente.
es	Could not get the release from the GitHub API (if the unauthenticated rate limit is exhausted, set GH_TOKEN).	No se pudo obtener la release desde la API de GitHub (si se agotó el límite sin autenticación, defina GH_TOKEN).
es	Could not confirm that exactly one {asset} is attached to the release.	No se pudo confirmar que la release tenga exactamente un {asset} adjunto.
es	The release tag is not in the expected format.	El tag de la release no tiene el formato esperado.
es	The release is not published as a stable release.	La release no está publicada como estable.
es	The specified tag does not match the release tag.	El tag indicado no coincide con el tag de la release.
es	The package URL is not in the expected format.	La URL del paquete no tiene el formato esperado.
es	The package size is outside the expected range.	El tamaño del paquete está fuera del rango esperado.
es	Could not confirm the package SHA-256 returned by GitHub.	No se pudo confirmar el SHA-256 del paquete devuelto por GitHub.
es	(--dry-run: nothing is downloaded or installed)	(--dry-run: no se descarga ni se instala nada)
es	Could not download the package.	No se pudo descargar el paquete.
es	The size or SHA-256 of the downloaded package does not match the GitHub record.	El tamaño o el SHA-256 del paquete descargado no coincide con el registro de GitHub.
es	The package does not contain prunlet.	El paquete no contiene prunlet.
es	The executable is not arm64.	El ejecutable no es arm64.
es	Developer ID signature and notarization verification failed (check that the Apple notarization ticket can be fetched over the network).	Falló la verificación de la firma Developer ID y de la notarización (compruebe que se pueda obtener el ticket de notarización de Apple por la red).
es	Installed: {root}	Instalado: {root}
es	To register it with an MCP host, use the following settings (this script does not change configuration files).	Para registrarlo en un host MCP, use la siguiente configuración (este script no cambia archivos de configuración).
es	[Codex config.toml]	[config.toml de Codex]
es	[CLI example]	[Ejemplo de CLI]
es	<absolute path of a file you own>	<ruta absoluta de un archivo propio>
fr	  --install-dir  Install directory (default: $HOME/.local/share/Prunlet; only a directory that does not exist yet can be used)	  --install-dir  Répertoire d'installation (par défaut : $HOME/.local/share/Prunlet ; seul un répertoire qui n'existe pas encore peut être utilisé)
fr	  --tag          Version to install (default: the latest stable release)	  --tag          Version à installer (par défaut : la dernière release stable)
fr	  --dry-run      Check and show the source, version and package without downloading or installing	  --dry-run      Vérifie et affiche la source, la version et le paquet sans rien télécharger ni installer
fr	If the GH_TOKEN environment variable is set, it is used to authenticate GitHub API requests (when the unauthenticated rate limit is exhausted).	Si la variable d'environnement GH_TOKEN est définie, elle sert à authentifier les requêtes à l'API GitHub (lorsque la limite non authentifiée est épuisée).
fr	Can only run on an Apple Silicon Mac (Darwin arm64).	Ne peut s'exécuter que sur un Mac Apple Silicon (Darwin arm64).
fr	Specify the install directory as an absolute path.	Indiquez le répertoire d'installation sous forme de chemin absolu.
fr	The repository format is invalid.	Le format de repository n'est pas valide.
fr	Specify the tag in the form vX.Y.Z.	Indiquez le tag au format vX.Y.Z.
fr	Already installed: {root}	Déjà installé : {root}
fr	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	Les mises à jour sont appliquées par la mise à jour automatique au démarrage du MCP. Ce script ne modifie pas une installation existante.
fr	Could not get the release from the GitHub API (if the unauthenticated rate limit is exhausted, set GH_TOKEN).	Impossible d'obtenir la release depuis l'API GitHub (si la limite non authentifiée est épuisée, définissez GH_TOKEN).
fr	Could not confirm that exactly one {asset} is attached to the release.	Impossible de confirmer qu'un seul {asset} est joint à la release.
fr	The release tag is not in the expected format.	Le tag de la release n'a pas le format attendu.
fr	The release is not published as a stable release.	La release n'est pas publiée comme version stable.
fr	The specified tag does not match the release tag.	Le tag indiqué ne correspond pas au tag de la release.
fr	The package URL is not in the expected format.	L'URL du paquet n'a pas le format attendu.
fr	The package size is outside the expected range.	La taille du paquet est hors de la plage attendue.
fr	Could not confirm the package SHA-256 returned by GitHub.	Impossible de confirmer le SHA-256 du paquet renvoyé par GitHub.
fr	(--dry-run: nothing is downloaded or installed)	(--dry-run : rien n'est téléchargé ni installé)
fr	Could not download the package.	Impossible de télécharger le paquet.
fr	The size or SHA-256 of the downloaded package does not match the GitHub record.	La taille ou le SHA-256 du paquet téléchargé ne correspond pas à l'enregistrement GitHub.
fr	The package does not contain prunlet.	Le paquet ne contient pas prunlet.
fr	The executable is not arm64.	L'exécutable n'est pas arm64.
fr	Developer ID signature and notarization verification failed (check that the Apple notarization ticket can be fetched over the network).	Échec de la vérification de la signature Developer ID et de la notarisation (vérifiez que le ticket de notarisation Apple peut être obtenu par le réseau).
fr	Installed: {root}	Installé : {root}
fr	To register it with an MCP host, use the following settings (this script does not change configuration files).	Pour l'enregistrer dans un hôte MCP, utilisez les paramètres suivants (ce script ne modifie pas les fichiers de configuration).
fr	[Codex config.toml]	[config.toml de Codex]
fr	[CLI example]	[Exemple de CLI]
fr	<absolute path of a file you own>	<chemin absolu d'un fichier qui vous appartient>
de	  --install-dir  Install directory (default: $HOME/.local/share/Prunlet; only a directory that does not exist yet can be used)	  --install-dir  Installationsverzeichnis (Standard: $HOME/.local/share/Prunlet; nur ein noch nicht vorhandenes Verzeichnis kann verwendet werden)
de	  --tag          Version to install (default: the latest stable release)	  --tag          Zu installierende Version (Standard: das neueste stabile Release)
de	  --dry-run      Check and show the source, version and package without downloading or installing	  --dry-run      Quelle, Version und Paket prüfen und anzeigen, ohne herunterzuladen oder zu installieren
de	If the GH_TOKEN environment variable is set, it is used to authenticate GitHub API requests (when the unauthenticated rate limit is exhausted).	Ist die Umgebungsvariable GH_TOKEN gesetzt, wird sie zur Authentifizierung von GitHub-API-Anfragen verwendet (wenn das Limit ohne Authentifizierung erschöpft ist).
de	Can only run on an Apple Silicon Mac (Darwin arm64).	Kann nur auf einem Apple-Silicon-Mac (Darwin arm64) ausgeführt werden.
de	Specify the install directory as an absolute path.	Geben Sie das Installationsverzeichnis als absoluten Pfad an.
de	The repository format is invalid.	Das Format von repository ist ungültig.
de	Specify the tag in the form vX.Y.Z.	Geben Sie den Tag im Format vX.Y.Z an.
de	Already installed: {root}	Bereits installiert: {root}
de	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	Aktualisierungen übernimmt die automatische Aktualisierung beim Start des MCP. Dieses Skript ändert keine vorhandene Installation.
de	Could not get the release from the GitHub API (if the unauthenticated rate limit is exhausted, set GH_TOKEN).	Das Release konnte nicht über die GitHub-API abgerufen werden (wenn das Limit ohne Authentifizierung erschöpft ist, setzen Sie GH_TOKEN).
de	Could not confirm that exactly one {asset} is attached to the release.	Es konnte nicht bestätigt werden, dass genau ein {asset} an das Release angehängt ist.
de	The release tag is not in the expected format.	Der Release-Tag hat nicht das erwartete Format.
de	The release is not published as a stable release.	Das Release ist nicht als stabiles Release veröffentlicht.
de	The specified tag does not match the release tag.	Der angegebene Tag stimmt nicht mit dem Release-Tag überein.
de	The package URL is not in the expected format.	Die Paket-URL hat nicht das erwartete Format.
de	The package size is outside the expected range.	Die Paketgröße liegt außerhalb des erwarteten Bereichs.
de	Could not confirm the package SHA-256 returned by GitHub.	Der von GitHub gemeldete SHA-256 des Pakets konnte nicht bestätigt werden.
de	(--dry-run: nothing is downloaded or installed)	(--dry-run: es wird nichts heruntergeladen oder installiert)
de	Could not download the package.	Das Paket konnte nicht heruntergeladen werden.
de	The size or SHA-256 of the downloaded package does not match the GitHub record.	Größe oder SHA-256 des heruntergeladenen Pakets stimmt nicht mit dem GitHub-Eintrag überein.
de	The package does not contain prunlet.	Das Paket enthält kein prunlet.
de	The executable is not arm64.	Die Programmdatei ist nicht arm64.
de	Developer ID signature and notarization verification failed (check that the Apple notarization ticket can be fetched over the network).	Die Prüfung von Developer-ID-Signatur und Notarisierung ist fehlgeschlagen (prüfen Sie, ob das Notarisierungsticket von Apple über das Netzwerk abgerufen werden kann).
de	Installed: {root}	Installiert: {root}
de	To register it with an MCP host, use the following settings (this script does not change configuration files).	Um es bei einem MCP-Host zu registrieren, verwenden Sie die folgenden Einstellungen (dieses Skript ändert keine Konfigurationsdateien).
de	[Codex config.toml]	[Codex config.toml]
de	[CLI example]	[CLI-Beispiel]
de	<absolute path of a file you own>	<absoluter Pfad einer eigenen Datei>
pt-BR	  --install-dir  Install directory (default: $HOME/.local/share/Prunlet; only a directory that does not exist yet can be used)	  --install-dir  Diretório de instalação (padrão: $HOME/.local/share/Prunlet; só é possível usar um diretório que ainda não existe)
pt-BR	  --tag          Version to install (default: the latest stable release)	  --tag          Versão a instalar (padrão: a release estável mais recente)
pt-BR	  --dry-run      Check and show the source, version and package without downloading or installing	  --dry-run      Verifica e mostra a origem, a versão e o pacote sem baixar nem instalar
pt-BR	If the GH_TOKEN environment variable is set, it is used to authenticate GitHub API requests (when the unauthenticated rate limit is exhausted).	Se a variável de ambiente GH_TOKEN estiver definida, ela será usada para autenticar as solicitações à API do GitHub (quando o limite sem autenticação se esgotar).
pt-BR	Can only run on an Apple Silicon Mac (Darwin arm64).	Só pode ser executado em um Mac com Apple Silicon (Darwin arm64).
pt-BR	Specify the install directory as an absolute path.	Informe o diretório de instalação como caminho absoluto.
pt-BR	The repository format is invalid.	O formato de repository é inválido.
pt-BR	Specify the tag in the form vX.Y.Z.	Informe a tag no formato vX.Y.Z.
pt-BR	Already installed: {root}	Já instalado: {root}
pt-BR	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	As atualizações são aplicadas pela atualização automática na inicialização do MCP. Este script não altera uma instalação existente.
pt-BR	Could not get the release from the GitHub API (if the unauthenticated rate limit is exhausted, set GH_TOKEN).	Não foi possível obter a release pela API do GitHub (se o limite sem autenticação se esgotou, defina GH_TOKEN).
pt-BR	Could not confirm that exactly one {asset} is attached to the release.	Não foi possível confirmar que exatamente um {asset} está anexado à release.
pt-BR	The release tag is not in the expected format.	A tag da release não está no formato esperado.
pt-BR	The release is not published as a stable release.	A release não foi publicada como estável.
pt-BR	The specified tag does not match the release tag.	A tag informada não corresponde à tag da release.
pt-BR	The package URL is not in the expected format.	A URL do pacote não está no formato esperado.
pt-BR	The package size is outside the expected range.	O tamanho do pacote está fora do intervalo esperado.
pt-BR	Could not confirm the package SHA-256 returned by GitHub.	Não foi possível confirmar o SHA-256 do pacote retornado pelo GitHub.
pt-BR	(--dry-run: nothing is downloaded or installed)	(--dry-run: nada é baixado nem instalado)
pt-BR	Could not download the package.	Não foi possível baixar o pacote.
pt-BR	The size or SHA-256 of the downloaded package does not match the GitHub record.	O tamanho ou o SHA-256 do pacote baixado não corresponde ao registro do GitHub.
pt-BR	The package does not contain prunlet.	O pacote não contém prunlet.
pt-BR	The executable is not arm64.	O executável não é arm64.
pt-BR	Developer ID signature and notarization verification failed (check that the Apple notarization ticket can be fetched over the network).	Falha na verificação da assinatura Developer ID e da notarização (verifique se o tíquete de notarização da Apple pode ser obtido pela rede).
pt-BR	Installed: {root}	Instalado: {root}
pt-BR	To register it with an MCP host, use the following settings (this script does not change configuration files).	Para registrá-lo em um host MCP, use as configurações a seguir (este script não altera arquivos de configuração).
pt-BR	[Codex config.toml]	[config.toml do Codex]
pt-BR	[CLI example]	[Exemplo de CLI]
pt-BR	<absolute path of a file you own>	<caminho absoluto de um arquivo seu>
PRUNLET_MESSAGES
    fi
    printf '%s' "$1"
}

# {name} を値で置き換える（値の中の文字は展開しない）。使い方: fill <文言> <名前> <値>
fill() {
    local text="$1" pattern="{$2}" result=''
    while [[ "$text" == *"$pattern"* ]]; do
        result+="${text%%"$pattern"*}$3"
        text="${text#*"$pattern"}"
    done
    printf '%s' "$result$text"
}

usage() {
    printf '%s\n\n' 'Usage: Install-Prunlet.sh [--install-dir <absolute path>] [--tag vX.Y.Z] [--repository owner/repo] [--dry-run]'
    printf '%s\n' "$(t '  --install-dir  Install directory (default: $HOME/.local/share/Prunlet; only a directory that does not exist yet can be used)')"
    printf '%s\n' "$(t '  --tag          Version to install (default: the latest stable release)')"
    printf '%s\n' "$(t '  --dry-run      Check and show the source, version and package without downloading or installing')"
    printf '%s\n' "$(t 'If the GH_TOKEN environment variable is set, it is used to authenticate GitHub API requests (when the unauthenticated rate limit is exhausted).')"
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

[ "$(uname -sm)" = 'Darwin arm64' ] || fail "$(t 'Can only run on an Apple Silicon Mac (Darwin arm64).')"
case "$root" in
    /*) ;;
    *) fail "$(t 'Specify the install directory as an absolute path.')" ;;
esac
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "$(t 'The repository format is invalid.')"
if [ -n "$tag" ] && [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then fail "$(t 'Specify the tag in the form vX.Y.Z.')"; fi

if [ -e "$root" ] || [ -L "$root" ]; then
    printf '%s\n' "$(fill "$(t 'Already installed: {root}')" root "$root")"
    printf '%s\n' "$(t 'Updates are applied by the MCP startup auto-update. This script does not change an existing installation.')"
    exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/prunlet-install.XXXXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

if [ -n "$tag" ]; then endpoint="releases/tags/$tag"; else endpoint='releases/latest'; fi
curl_api=(curl -fsS --proto '=https' --tlsv1.2 --max-time 60 -H 'Accept: application/vnd.github+json')
if [ -n "${GH_TOKEN:-}" ]; then curl_api+=(-H "Authorization: Bearer $GH_TOKEN"); fi
"${curl_api[@]}" "https://api.github.com/repos/$repository/$endpoint" -o "$work/release.json" \
    || fail "$(t 'Could not get the release from the GitHub API (if the unauthenticated rate limit is exhausted, set GH_TOKEN).')"

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
}' "$work/release.json" "$asset" 2>/dev/null)" || fail "$(fill "$(t 'Could not confirm that exactly one {asset} is attached to the release.')" asset "$asset")"

IFS=$'\t' read -r release_tag draft prerelease url size digest <<<"$parsed"
[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$(t 'The release tag is not in the expected format.')"
[ "$draft" = 'false' ] && [ "$prerelease" = 'false' ] || fail "$(t 'The release is not published as a stable release.')"
[ -z "$tag" ] || [ "$tag" = "$release_tag" ] || fail "$(t 'The specified tag does not match the release tag.')"
[[ "$url" == "https://github.com/$repository/releases/download/$release_tag/$asset" ]] || fail "$(t 'The package URL is not in the expected format.')"
[[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && [ "$size" -le 67108864 ] || fail "$(t 'The package size is outside the expected range.')"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "$(t 'Could not confirm the package SHA-256 returned by GitHub.')"
expected_sha="${digest#sha256:}"

printf 'repository : %s\nrelease    : %s\nasset      : %s (%s bytes)\nsha256     : %s\ninstall dir: %s\n' \
    "$repository" "$release_tag" "$asset" "$size" "$expected_sha" "$root"
if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' "$(t '(--dry-run: nothing is downloaded or installed)')"
    exit 0
fi

curl -fsSL --proto '=https' --tlsv1.2 --max-time 300 --max-filesize "$size" "$url" -o "$work/$asset" \
    || fail "$(t 'Could not download the package.')"
actual_size="$(stat -f %z "$work/$asset")"
actual_sha="$(/usr/bin/shasum -a 256 "$work/$asset" | awk '{print $1}')"
[ "$actual_size" = "$size" ] && [ "$actual_sha" = "$expected_sha" ] || fail "$(t 'The size or SHA-256 of the downloaded package does not match the GitHub record.')"

mkdir "$work/extracted"
/usr/bin/ditto -x -k "$work/$asset" "$work/extracted"
exe="$work/extracted/prunlet"
[ -f "$exe" ] && [ ! -L "$exe" ] || fail "$(t 'The package does not contain prunlet.')"
chmod 700 "$exe"
[ "$(/usr/bin/lipo -archs "$exe")" = 'arm64' ] || fail "$(t 'The executable is not arm64.')"
requirement="=anchor apple generic and identifier \"com.kagayoi.prunlet\" and certificate leaf[subject.OU] = \"$team_id\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and notarized"
# 初回は公証チケットが端末にまだ無く、`notarized` の要件が一度失敗することがある。spctlの照会でAppleから
# チケットを取得してから再検証する。要件は緩めず、3回続けて満たせなければ導入しない。
verified=0
for attempt in 1 2 3; do
    if /usr/bin/codesign --verify --strict -R "$requirement" "$exe" 2>/dev/null; then verified=1; break; fi
    /usr/sbin/spctl -a -vv -t install "$exe" >/dev/null 2>&1 || true
    sleep 3
done
[ "$verified" -eq 1 ] || fail "$(t 'Developer ID signature and notarization verification failed (check that the Apple notarization ticket can be fetched over the network).')"

mkdir -p "$(dirname "$root")"
"$exe" --install-macos "$root"

# 設定行（TOML とコマンド例）は利用者がそのまま貼る機械可読の部分なので訳さず、見出しと説明だけを訳す。
printf '\n%s\n' "$(fill "$(t 'Installed: {root}')" root "$root")"
printf '%s\n\n' "$(t 'To register it with an MCP host, use the following settings (this script does not change configuration files).')"
printf '%s\n' "$(t '[Codex config.toml]')"
cat <<EOF
[mcp_servers.prunlet]
command = "$root/bin/prunlet"
args = ["--config", "$root/config.json", "mcp"]
startup_timeout_sec = 90

EOF
printf '%s\n' "$(t '[CLI example]')"
printf '"%s/bin/prunlet" --config "%s/config.json" delete --dry-run -- %s\n' "$root" "$root" "$(t '<absolute path of a file you own>')"
