#!/bin/bash
# Apple Silicon MacへPrunletを導入する。R2（https://prunlet.kagayoi.com）の署名付きマニフェストを固定の公開鍵で
# 検証し（GitHubのAPI・Release・タグは使わない）、それが指す署名・公証済みの配布物を取得して、
# サイズ・SHA-256・Developer ID・公証を照合してから `prunlet --install-macos` で配置する。
# --repository は互換のために受け付けるが、公式（1llum1n4t1s/Prunlet）以外はマニフェストと一致しないので導入しない。
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
ja	Can only run on an Apple Silicon Mac (Darwin arm64).	Apple Silicon Mac (Darwin arm64) でのみ実行できます。
ja	Specify the install directory as an absolute path.	導入先は絶対パスで指定してください。
ja	The repository format is invalid.	repositoryの形式が正しくありません。
ja	Specify the tag in the form vX.Y.Z.	tagは vX.Y.Z の形式で指定してください。
ja	Already installed: {root}	既に導入済みです: {root}
ja	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	更新はMCPの起動時自動更新が行います。このスクリプトは既存の導入先を変更しません。
ja	Could not get the release manifest from {url}.	{url} からリリースのマニフェストを取得できませんでした。
ja	The release manifest was rejected ({reason}).	リリースのマニフェストを拒否しました（{reason}）。
ja	(--dry-run: nothing is downloaded or installed)	(--dry-run: ダウンロードも導入も行いません)
ja	Could not download the package.	配布物をダウンロードできませんでした。
ja	The size or SHA-256 of the downloaded package does not match the release manifest.	ダウンロードした配布物のサイズ・SHA-256がリリースのマニフェストと一致しません。
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
zh-CN	Can only run on an Apple Silicon Mac (Darwin arm64).	只能在 Apple Silicon Mac (Darwin arm64) 上运行。
zh-CN	Specify the install directory as an absolute path.	请以绝对路径指定安装目录。
zh-CN	The repository format is invalid.	repository 的格式不正确。
zh-CN	Specify the tag in the form vX.Y.Z.	请以 vX.Y.Z 的格式指定 tag。
zh-CN	Already installed: {root}	已经安装：{root}
zh-CN	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	更新由 MCP 的启动时自动更新完成。此脚本不会更改现有安装。
zh-CN	Could not get the release manifest from {url}.	无法从 {url} 获取发布清单。
zh-CN	The release manifest was rejected ({reason}).	已拒绝发布清单（{reason}）。
zh-CN	(--dry-run: nothing is downloaded or installed)	(--dry-run：不下载也不安装)
zh-CN	Could not download the package.	无法下载软件包。
zh-CN	The size or SHA-256 of the downloaded package does not match the release manifest.	下载的软件包的大小或 SHA-256 与发布清单不一致。
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
zh-TW	Can only run on an Apple Silicon Mac (Darwin arm64).	只能在 Apple Silicon Mac (Darwin arm64) 上執行。
zh-TW	Specify the install directory as an absolute path.	請以絕對路徑指定安裝目錄。
zh-TW	The repository format is invalid.	repository 的格式不正確。
zh-TW	Specify the tag in the form vX.Y.Z.	請以 vX.Y.Z 的格式指定 tag。
zh-TW	Already installed: {root}	已經安裝：{root}
zh-TW	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	更新由 MCP 的啟動時自動更新完成。此指令碼不會變更現有的安裝。
zh-TW	Could not get the release manifest from {url}.	無法從 {url} 取得發行資訊清單。
zh-TW	The release manifest was rejected ({reason}).	已拒絕發行資訊清單（{reason}）。
zh-TW	(--dry-run: nothing is downloaded or installed)	(--dry-run：不下載也不安裝)
zh-TW	Could not download the package.	無法下載套件。
zh-TW	The size or SHA-256 of the downloaded package does not match the release manifest.	下載的套件大小或 SHA-256 與發行資訊清單不一致。
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
ko	Can only run on an Apple Silicon Mac (Darwin arm64).	Apple Silicon Mac (Darwin arm64)에서만 실행할 수 있습니다.
ko	Specify the install directory as an absolute path.	설치 디렉터리를 절대 경로로 지정하십시오.
ko	The repository format is invalid.	repository 형식이 올바르지 않습니다.
ko	Specify the tag in the form vX.Y.Z.	tag는 vX.Y.Z 형식으로 지정하십시오.
ko	Already installed: {root}	이미 설치되어 있습니다: {root}
ko	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	업데이트는 MCP 시작 시 자동 업데이트가 수행합니다. 이 스크립트는 기존 설치를 변경하지 않습니다.
ko	Could not get the release manifest from {url}.	{url}에서 릴리스 매니페스트를 가져올 수 없습니다.
ko	The release manifest was rejected ({reason}).	릴리스 매니페스트를 거부했습니다({reason}).
ko	(--dry-run: nothing is downloaded or installed)	(--dry-run: 다운로드도 설치도 하지 않습니다)
ko	Could not download the package.	패키지를 다운로드할 수 없습니다.
ko	The size or SHA-256 of the downloaded package does not match the release manifest.	다운로드한 패키지의 크기 또는 SHA-256이 릴리스 매니페스트와 일치하지 않습니다.
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
es	Can only run on an Apple Silicon Mac (Darwin arm64).	Solo se puede ejecutar en un Mac con Apple Silicon (Darwin arm64).
es	Specify the install directory as an absolute path.	Indique el directorio de instalación como ruta absoluta.
es	The repository format is invalid.	El formato de repository no es válido.
es	Specify the tag in the form vX.Y.Z.	Indique el tag con el formato vX.Y.Z.
es	Already installed: {root}	Ya está instalado: {root}
es	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	Las actualizaciones las aplica la actualización automática al iniciar el MCP. Este script no cambia una instalación existente.
es	Could not get the release manifest from {url}.	No se pudo obtener el manifiesto de la versión desde {url}.
es	The release manifest was rejected ({reason}).	Se rechazó el manifiesto de la versión ({reason}).
es	(--dry-run: nothing is downloaded or installed)	(--dry-run: no se descarga ni se instala nada)
es	Could not download the package.	No se pudo descargar el paquete.
es	The size or SHA-256 of the downloaded package does not match the release manifest.	El tamaño o el SHA-256 del paquete descargado no coincide con el manifiesto de la versión.
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
fr	Can only run on an Apple Silicon Mac (Darwin arm64).	Ne peut s'exécuter que sur un Mac Apple Silicon (Darwin arm64).
fr	Specify the install directory as an absolute path.	Indiquez le répertoire d'installation sous forme de chemin absolu.
fr	The repository format is invalid.	Le format de repository n'est pas valide.
fr	Specify the tag in the form vX.Y.Z.	Indiquez le tag au format vX.Y.Z.
fr	Already installed: {root}	Déjà installé : {root}
fr	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	Les mises à jour sont appliquées par la mise à jour automatique au démarrage du MCP. Ce script ne modifie pas une installation existante.
fr	Could not get the release manifest from {url}.	Impossible de récupérer le manifeste de la version depuis {url}.
fr	The release manifest was rejected ({reason}).	Le manifeste de la version a été refusé ({reason}).
fr	(--dry-run: nothing is downloaded or installed)	(--dry-run : rien n'est téléchargé ni installé)
fr	Could not download the package.	Impossible de télécharger le paquet.
fr	The size or SHA-256 of the downloaded package does not match the release manifest.	La taille ou le SHA-256 du paquet téléchargé ne correspond pas au manifeste de la version.
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
de	Can only run on an Apple Silicon Mac (Darwin arm64).	Kann nur auf einem Apple-Silicon-Mac (Darwin arm64) ausgeführt werden.
de	Specify the install directory as an absolute path.	Geben Sie das Installationsverzeichnis als absoluten Pfad an.
de	The repository format is invalid.	Das Format von repository ist ungültig.
de	Specify the tag in the form vX.Y.Z.	Geben Sie den Tag im Format vX.Y.Z an.
de	Already installed: {root}	Bereits installiert: {root}
de	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	Aktualisierungen übernimmt die automatische Aktualisierung beim Start des MCP. Dieses Skript ändert keine vorhandene Installation.
de	Could not get the release manifest from {url}.	Das Release-Manifest konnte nicht von {url} abgerufen werden.
de	The release manifest was rejected ({reason}).	Das Release-Manifest wurde abgelehnt ({reason}).
de	(--dry-run: nothing is downloaded or installed)	(--dry-run: es wird nichts heruntergeladen oder installiert)
de	Could not download the package.	Das Paket konnte nicht heruntergeladen werden.
de	The size or SHA-256 of the downloaded package does not match the release manifest.	Größe oder SHA-256 des heruntergeladenen Pakets stimmen nicht mit dem Release-Manifest überein.
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
pt-BR	Can only run on an Apple Silicon Mac (Darwin arm64).	Só pode ser executado em um Mac com Apple Silicon (Darwin arm64).
pt-BR	Specify the install directory as an absolute path.	Informe o diretório de instalação como caminho absoluto.
pt-BR	The repository format is invalid.	O formato de repository é inválido.
pt-BR	Specify the tag in the form vX.Y.Z.	Informe a tag no formato vX.Y.Z.
pt-BR	Already installed: {root}	Já instalado: {root}
pt-BR	Updates are applied by the MCP startup auto-update. This script does not change an existing installation.	As atualizações são aplicadas pela atualização automática na inicialização do MCP. Este script não altera uma instalação existente.
pt-BR	Could not get the release manifest from {url}.	Não foi possível obter o manifesto da versão em {url}.
pt-BR	The release manifest was rejected ({reason}).	O manifesto da versão foi rejeitado ({reason}).
pt-BR	(--dry-run: nothing is downloaded or installed)	(--dry-run: nada é baixado nem instalado)
pt-BR	Could not download the package.	Não foi possível baixar o pacote.
pt-BR	The size or SHA-256 of the downloaded package does not match the release manifest.	O tamanho ou o SHA-256 do pacote baixado não corresponde ao manifesto da versão.
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

# BEGIN PRUNLET MANIFEST VERIFY
# 署名付きマニフェスト（配信の信頼の基点）の取得と検証。GitHubのAPI・Release・タグは使わない。
# R2（https://prunlet.kagayoi.com）の封筒 {"schema":1,"keyId":..,"payload":"<base64>","signature":"<base64 DER>"} を、
# 固定の公開鍵と /usr/bin/openssl（macOS標準。追加ツール不要）で検証する。署名対象はpayloadを復号した生バイト、
# ECDSA P-256 + SHA-256、署名はRFC 3279のDER。1つでも外れたら導入しない（fail-closed）。
# JSONの解釈はjq・python3に頼らず、配信側が書く正規形（UTF-8・compact・キー順固定・末尾改行なし）そのものを
# 全体一致の正規表現で照合し、照合と値の取り出しを兼ねる（重複キー・追加キー・順序違い・空白は一致しない）。
# 鍵整合の関門（scripts/Test-PrunletReleaseKeyGate.ps1）は次の行を抽出する。定義はこのファイルでこの1か所だけにする。
PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64='MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEMIbQQg1ZUrL1G3V5sKqnQm74bz087XUrB5+wnCXOfBnP8kREgm960J5b9S/fT0rUgopgPODpO9/PINkkCFhJbA=='
release_key_id='prunlet-release-1'
release_origin='https://prunlet.kagayoi.com'
release_repository='1llum1n4t1s/Prunlet'
release_runtime='osx-arm64'
release_max_bytes=67108864
# 検証に使うopensslは固定パス（環境変数・PATHで差し替えられる形にしない＝検証を緩める入口を作らない）。
openssl_bin='/usr/bin/openssl'

# マニフェストの拒否。理由は固定語彙だけを出し、取得した本文は表示しない。
manifest_reject() { fail "$(fill "$(t 'The release manifest was rejected ({reason}).')" reason "$1")"; }

# ファイルの内容を変数へ読み、バイト数がファイルと一致すること（末尾改行・NULを含まないこと）を確かめる。
# 使い方: read_exact <ファイル> <変数名>
read_exact() {
    local content size
    content="$(cat "$1"; printf x)"
    content="${content%x}"
    size="$(wc -c <"$1" | tr -d ' ')"
    [ "${#content}" = "$size" ] || return 1
    printf -v "$2" '%s' "$content"
}

# base64（標準・パディング付き）を復号し、再エンコードが元の文字列と一致する正規形だけを受け付ける。
# 使い方: decode_canonical <base64文字列> <出力ファイル>
decode_canonical() {
    local again
    printf '%s' "$1" >"$2.b64"
    "$openssl_bin" base64 -d -A -in "$2.b64" -out "$2" 2>/dev/null || return 1
    again="$("$openssl_bin" base64 -A -in "$2")" || return 1
    [ "$again" = "$1" ]
}

# DER署名の構造を、バイト値（10進）の並びで確かめる。使い方: der_check <ファイル> <バイト数>
der_check() {
    local bytes offset part length
    # od の出力を空白区切りの10進へ（bash 3.2 でも動く配列）。
    bytes=($(od -An -v -tu1 "$1"))
    [ "${#bytes[@]}" = "$2" ] && [ "${bytes[0]}" = 48 ] && [ "${bytes[1]}" = "$(( $2 - 2 ))" ] || return 1
    offset=2
    for part in 1 2; do
        [ $((offset + 2)) -le "$2" ] && [ "${bytes[$offset]}" = 2 ] || return 1
        length="${bytes[$((offset + 1))]}"
        [ "$length" -ge 1 ] && [ "$length" -le 33 ] || return 1
        offset=$((offset + 2 + length))
    done
    [ "$offset" = "$2" ]
}

# 封筒ファイルを検証し、payloadの値を manifest_version・manifest_commit・manifest_key・manifest_bytes・manifest_sha へ入れる。
# 使い方: verify_manifest <封筒ファイル> <作業ディレクトリ> <要求する版（空なら問わない）>
verify_manifest() {
    local envelope_file="$1" dir="$2" wanted="$3" envelope payload payload_b64 signature_b64 first size key requested
    local LC_ALL=C
    size="$(wc -c <"$envelope_file" | tr -d ' ')"
    [ "$size" -ge 2 ] && [ "$size" -le 16384 ] || manifest_reject 'envelope-size'
    read_exact "$envelope_file" envelope || manifest_reject 'envelope-malformed'
    [[ "$envelope" =~ ^\{\"schema\":1,\"keyId\":\"([^\"]*)\",\"payload\":\"([A-Za-z0-9+/]+={0,2})\",\"signature\":\"([A-Za-z0-9+/]+={0,2})\"\}$ ]] \
        || manifest_reject 'envelope-not-canonical'
    [ "${BASH_REMATCH[1]}" = "$release_key_id" ] || manifest_reject 'unknown-key-id'
    payload_b64="${BASH_REMATCH[2]}"
    signature_b64="${BASH_REMATCH[3]}"
    decode_canonical "$payload_b64" "$dir/payload.bin" || manifest_reject 'invalid-base64'
    decode_canonical "$signature_b64" "$dir/signature.der" || manifest_reject 'invalid-base64'
    # 署名はDER（SEQUENCE{INTEGER r, INTEGER s}）だけ。r||sの64バイト形式は形の段階で拒否する。
    # P-256では8〜72バイトで、SEQUENCEの長さが全体と一致し、2つのINTEGERが1〜33バイトで隙間なく並ぶ。
    size="$(wc -c <"$dir/signature.der" | tr -d ' ')"
    [ "$size" -ge 8 ] && [ "$size" -le 72 ] || manifest_reject 'signature-format'
    der_check "$dir/signature.der" "$size" || manifest_reject 'signature-format'
    # 公開鍵はPEMにして渡す（64文字で折り返す。LibreSSL・OpenSSLのどちらでも読める形）。
    { printf '%s\n' '-----BEGIN PUBLIC KEY-----'; printf '%s' "$PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64" | fold -w 64; printf '\n%s\n' '-----END PUBLIC KEY-----'; } >"$dir/release-public.pem"
    "$openssl_bin" dgst -sha256 -verify "$dir/release-public.pem" -signature "$dir/signature.der" "$dir/payload.bin" >/dev/null 2>&1 \
        || manifest_reject 'signature-verification-failed'
    read_exact "$dir/payload.bin" payload || manifest_reject 'payload-malformed'
    [[ "$payload" =~ ^\{\"schema\":1,\"product\":\"([^\"]*)\",\"repository\":\"([^\"]*)\",\"runtime\":\"([^\"]*)\",\"version\":\"([^\"]*)\",\"commit\":\"([^\"]*)\",\"defaultBranch\":\"([^\"]*)\",\"asset\":\{\"name\":\"([^\"]*)\",\"key\":\"([^\"]*)\",\"bytes\":([0-9]+),\"sha256\":\"([^\"]*)\"\}\}$ ]] \
        || manifest_reject 'payload-not-canonical'
    # 後の [[ =~ ]] で BASH_REMATCH が上書きされるので、先に全項目を取り出す。
    local product="${BASH_REMATCH[1]}" payload_repository="${BASH_REMATCH[2]}" payload_runtime="${BASH_REMATCH[3]}"
    local branch="${BASH_REMATCH[6]}" name="${BASH_REMATCH[7]}"
    manifest_version="${BASH_REMATCH[4]}"
    manifest_commit="${BASH_REMATCH[5]}"
    key="${BASH_REMATCH[8]}"
    manifest_bytes="${BASH_REMATCH[9]}"
    manifest_sha="${BASH_REMATCH[10]}"
    [ "$product" = 'Prunlet' ] || manifest_reject 'product-mismatch'
    # 公式以外のrepositoryは、指定されても配信されないので不一致で止める（指定の大文字小文字は区別しない）。
    requested="$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')"
    [ "$payload_repository" = "$release_repository" ] && [ "$requested" = "$release_repository_lower" ] || manifest_reject 'repository-mismatch'
    [ "$payload_runtime" = "$release_runtime" ] || manifest_reject 'runtime-mismatch'
    [ "$name" = "$asset" ] || manifest_reject 'asset-name-mismatch'
    [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$branch" != *..* ]] && [[ "$branch" != /* ]] && [[ "$branch" != */ ]] || manifest_reject 'invalid-branch'
    [[ "$manifest_version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || manifest_reject 'invalid-version'
    [ -z "$wanted" ] || [ "$manifest_version" = "$wanted" ] || manifest_reject 'version-mismatch'
    [[ "$manifest_commit" =~ ^[0-9a-f]{40}$ ]] || manifest_reject 'invalid-commit'
    [[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]] || manifest_reject 'invalid-sha256'
    # 長さは先頭0なしの10進で、1以上・上限以下（桁数を先に絞ってから数値比較する）。
    [[ "$manifest_bytes" =~ ^[1-9][0-9]{0,8}$ ]] && [ "$manifest_bytes" -le "$release_max_bytes" ] || manifest_reject 'asset-length'
    # 配布物のキーは自分で組み立てた値と完全一致すること（任意のURLへ誘導されない）。
    manifest_key="releases/$release_repository_lower/$manifest_commit/$release_runtime/$manifest_sha.zip"
    [ "$key" = "$manifest_key" ] || manifest_reject 'asset-key-mismatch'
}
release_repository_lower="$(printf '%s' "$release_repository" | tr '[:upper:]' '[:lower:]')"

# R2の公開オブジェクトを取得する。リダイレクトは追わず（-L なし・--max-redirs 0）、HTTP 200以外は失敗にする。
# 使い方: fetch_release_object <URL> <出力ファイル> <最大バイト数> <期限秒>
fetch_release_object() {
    local status
    status="$(curl --disable -sS --proto '=https' --tlsv1.2 --max-redirs 0 --max-time "$4" --max-filesize "$3" \
        -H 'User-Agent: Prunlet-Latest-Installer' -w '%{http_code}' -o "$2" -- "$1")" || return 1
    [ "$status" = '200' ]
}
# END PRUNLET MANIFEST VERIFY
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

# 版の指定（--tag vX.Y.Z）があれば版マニフェスト manifests/<版>/osx-arm64.json、なければ最新ポインタ
# latest/osx-arm64.json を取得する。どちらも同じ署名付き封筒で、検証は verify_manifest が行う。
if [ -n "$tag" ]; then
    wanted_version="${tag#v}"
    manifest_url="$release_origin/manifests/$wanted_version/$release_runtime.json"
else
    wanted_version=''
    manifest_url="$release_origin/latest/$release_runtime.json"
fi
fetch_release_object "$manifest_url" "$work/manifest.json" 16384 60 \
    || fail "$(fill "$(t 'Could not get the release manifest from {url}.')" url "$manifest_url")"
mkdir "$work/manifest"
verify_manifest "$work/manifest.json" "$work/manifest" "$wanted_version"
url="$release_origin/$manifest_key"
size="$manifest_bytes"
expected_sha="$manifest_sha"

printf 'repository : %s\nrelease    : v%s (%s)\nasset      : %s (%s bytes)\nsha256     : %s\ninstall dir: %s\n' \
    "$release_repository" "$manifest_version" "$manifest_commit" "$asset" "$size" "$expected_sha" "$root"
if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' "$(t '(--dry-run: nothing is downloaded or installed)')"
    exit 0
fi

# 配布物は署名済みマニフェストが指すR2の不変キーから、リダイレクトなしで取得し、長さとSHA-256で照合する。
fetch_release_object "$url" "$work/$asset" "$size" 300 || fail "$(t 'Could not download the package.')"
actual_size="$(stat -f %z "$work/$asset")"
actual_sha="$(/usr/bin/shasum -a 256 "$work/$asset" | awk '{print $1}')"
[ "$actual_size" = "$size" ] && [ "$actual_sha" = "$expected_sha" ] || fail "$(t 'The size or SHA-256 of the downloaded package does not match the release manifest.')"

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
