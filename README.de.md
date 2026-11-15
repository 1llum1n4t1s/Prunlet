[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | **Deutsch** | [Português (Brasil)](README.pt-BR.md)

# Prunlet — Anti “blocked by policy”

Prunlet ist ein Werkzeug für Windows, Apple-Silicon-Macs und Linux, das das Löschen von Dateien und Ordnern durch KI-Agenten über eine eigene CLI und einen eigenen MCP-Server leitet, damit Aufräumarbeiten seltener an `blocked by policy` scheitern. Es vereinheitlicht die Nutzung so, dass erlaubte Löschvorgänge von Anfang an Prunlet übergeben werden.

Dateien und Ordner werden normalerweise in den Papierkorb des Betriebssystems verschoben. Prunlet speichert keine Vorgangsprotokolle, Vorgangs-IDs oder Wiederherstellungs-Snapshots für Dateien; die Wiederherstellung aus dem Papierkorb und dessen Aufbewahrung überlässt es dem Betriebssystem. Es gehört zu keinem bestimmten KI-Werkzeug und wird als eigenständige App installiert. MCP-Server, CLI und Hook lassen sich bei Bedarf in jedem KI-Werkzeug registrieren; der Hook prüft und verweigert direkte Löschvorgänge und verweist auf das Vorgehen mit der CLI. Herausgeber ist Kagayoi.

Es verarbeitet Dateien und leere Ordner und löscht einen ganzen Ordner, wenn `--recursive` ausdrücklich angegeben wird. Linkziele werden nie verfolgt. Ein in den Papierkorb verschobener fester Link teilt seinen Inhalt weiterhin mit den verbleibenden Aliasen. Bedingtes endgültiges Löschen sowie [Löschen und Wiederherstellen in der Registrierung](#löschen-und-wiederherstellen-in-der-registrierung) gibt es nur unter Windows.

## Einsatz gegen `blocked by policy`

Wo Aufräumarbeiten oft an von der KI erzeugten Löschbefehlen wie `Remove-Item` oder `rm` hängen bleiben, übergeben Sie erlaubte Löschvorgänge von Anfang an der Prunlet-CLI. Codex auf Apple-Silicon-Macs und Linux verwendet die bei der Installation abgelegte CLI und Konfiguration. [Installation unter macOS](docs/macos.md) · [Installation unter Linux](docs/linux.md)

Unter Windows gehen Sie in dieser Reihenfolge vor:

1. Installieren Sie Prunlet mit dem Befehl unter [Installation und Aktualisierungen](#installation-und-aktualisierungen) als eigenständige App. Die Konfigurationsdateien der KI-Werkzeuge werden nicht angefasst.
2. Registrieren Sie den Startbefehl aus [Registrierung bei einem MCP-Host](#registrierung-bei-einem-mcp-host) in den KI-Werkzeugen (MCP-Hosts), die Sie verwenden. Wenn Sie die CLI direkt aufrufen, tragen Sie die absoluten Pfade der installierten CLI und Konfiguration in die Anweisungen des KI-Werkzeugs ein. Um alles auf einmal in Codex zu registrieren, verwenden Sie [Registrierung bei Codex (optional)](#registrierung-bei-codex-optional).
3. Beauftragen Sie Arbeit und Aufräumen wie gewohnt. Die CLI wird direkt aus CMD (`shell: cmd.exe`, `login: false`) mit den absoluten Pfaden der installierten CLI und Konfiguration aufgerufen. Sie müssen nicht in jedes Repository dieselben Anweisungen einfügen.

Um ausdrücklich ein Aufräumen zu beauftragen, sagen Sie zum Beispiel:

> Räume die diesmal erstellten, nicht mehr benötigten temporären Dateien und Arbeitsordner von Anfang an mit der Prunlet-CLI auf.

Übergeben Sie Pfade mit Leerzeichen, Unicode, lange Pfade oder mehrere Ziele als UTF-8-JSON-Liste mit `--paths-file`, und geben Sie für nicht leere Ordner ausdrücklich `--recursive` an. Die konkreten Befehle und die Wiederherstellung finden Sie unter [Löschen und Wiederherstellen](#löschen-und-wiederherstellen).

Der Hook ist eine Hilfe, die direkte Löschvorgänge erkennt und verweigert und auf das Vorgehen mit der CLI verweist; er wandelt Befehle nicht automatisch um. Um wiederholte Fehlschläge und Wiederholungen zu vermeiden, gilt als Grundsatz, die CLI über die gemeinsamen Anweisungen schon beim ersten Versuch zu verwenden. Berechtigungen, Genehmigungen und Verwaltungsrichtlinien von Host und Betriebssystem gelten weiterhin. Wird der Aufruf von Prunlet selbst verweigert, halten Sie an und versuchen Sie es nicht auf einem anderen Weg erneut. Registrierung und Prüfumfang beschreibt die [Integrationsanleitung](docs/integration.md).

PowerShell-Skripte, die Codex an einen Mac oder anderswohin sendet, müssen in der expliziten Form eines untergeordneten PowerShell übergeben werden, die in der [Hook-Integrationsanleitung](docs/integration.md#hookの検査範囲) beschrieben ist. Die Hook-Eingabe von Codex enthält die ausführende Shell nicht; mit der bloßen Angabe `shell: "pwsh"` lassen sich Löschvorgänge innerhalb eines Here-Strings daher nicht unterscheiden.

## Installation und Aktualisierungen

### Apple-Silicon-Mac

Laden Sie `prunlet-update-osx-arm64.zip` von [GitHub Releases](https://github.com/1llum1n4t1s/Prunlet/releases/latest) herunter. `scripts/Install-Prunlet.sh` erledigt in einem Durchlauf den Download, die Prüfung von Größe und SHA-256, die Prüfung von Signatur und Notarisierung sowie eine Neuinstallation in einen eigenen Ordner (siehe [Installation unter macOS](docs/macos.md)). Registrieren Sie den MCP-Server in Codex oder anderen Hosts selbst mit den angezeigten Konfigurationszeilen. Ein registrierter MCP-Server sucht beim Start nach Aktualisierungen und verschiebt sie auf einen späteren Start, solange er verwendet wird.

### Linux

Laden Sie `prunlet-linux-x64.tar.gz` oder `prunlet-linux-arm64.tar.gz` passend zu Ihrer CPU sowie die gleichnamige `.sha256`-Datei herunter. [GitHub Releases](https://github.com/1llum1n4t1s/Prunlet/releases)

Das Prüfen der Prüfsumme, das Ablegen in einem eigenen Verzeichnis und die Registrierung in Codex beschreibt die [Installation unter Linux](docs/linux.md#初回インストール). Wie beschrieben abgelegt, sucht die offizielle Version beim Start des MCP-Servers nach Aktualisierungen und verschiebt sie auf einen späteren Start, solange sie verwendet wird.

### Windows

Windows x64 und ARM64 werden unterstützt. Das folgende Installationsprogramm lädt das signierte, vorkompilierte Paket (`prunlet-update-<runtime>.zip`) aus dem neuesten Release des [GitHub-Repositorys](https://github.com/1llum1n4t1s/Prunlet) herunter und legt es ab. Es wird nur PowerShell 7 benötigt; Rust, die MSVC-Build-Tools und das Windows SDK sind nicht erforderlich.

| Ziel | Option des Installationsprogramms |
| --- | --- |
| Windows x64 | `-Runtime win-x64` (Standard) |
| Windows ARM64 | `-Runtime win-arm64` |

Unter Windows ARM64 geben Sie `-Runtime` im folgenden Befehl ausdrücklich an. Für die x64-Emulation geben Sie `-Runtime win-x64` an.

```powershell
$installerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Prunlet\bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $installerDirectory | Out-Null
$installer = Join-Path $installerDirectory 'Install-Prunlet.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.ps1' -OutFile $installer
pwsh -NoProfile -File $installer
```

Ist das Limit der GitHub-API ohne Authentifizierung erreicht, fügen Sie dem obigen `pwsh`-Befehl `-UseGitHubCliAuthentication` hinzu, um eine vorhandene, angemeldete GitHub CLI zu verwenden. gh wird weder installiert noch für Sie angemeldet. Diese Option gilt nur für das manuelle Installationsprogramm.

Das Installationsprogramm ruft das neueste stabile Release über die GitHub-API ab und prüft, dass sein Tag auf einen Commit im Standardbranch zeigt und genau ein Paket für die Ziel-Runtime angehängt ist. Bevor es das heruntergeladene ZIP ablegt, prüft es die von GitHub gemeldete Größe und SHA-256, die Liste der enthaltenen Dateien und jeden Hash, Commit und Runtime des Release sowie die Authenticode-Signatur der Programmdateien (Valid, mit erwartetem Signierer und Zeitstempel). Es sind dieselben Prüfungen wie bei der automatischen Aktualisierung beim Start. Ist das Paket kurz nach einem Release noch nicht signiert und angehängt oder schlägt eine Prüfung fehl, hält es an, ohne etwas zu schreiben. Es kompiliert nie aus dem Quellcode und wechselt nie zu einem lokalen Klon.

Das Standard-Installationsverzeichnis ist `%USERPROFILE%\.local\Prunlet`. Es legt `bin\prunlet.exe`, die Registrierungsskripte und die gemeinsamen Anweisungen ab und hält Quelle, Branch, Commit und Paket-Hash in `source-info.json` im selben Format wie die automatische Aktualisierung beim Start fest. Standardmäßig schreibt es nichts in die Konfigurationsdateien oder -ordner von Codex oder anderen KI-Werkzeugen und registriert nur die Wartungsaufgabe und die Aktualisierungsaufgabe.

Die automatische Aktualisierung prüft die vorkompilierten Binärdateien in GitHub Releases, wenn ein MCP-Host den Prunlet-MCP-Server startet, sowie über die vom Installationsprogramm registrierte Aktualisierungsaufgabe (täglich um 12:30 Uhr und 10 Minuten nach der Anmeldung, ohne Fenster), und wechselt, sobald der alte MCP-Server und die Wartungsprozesse beendet sind. Dank der Aktualisierungsaufgabe folgen auch PCs ohne registrierten MCP-Server der neuesten Version. Die automatische Aktualisierung kompiliert nicht neu aus dem Quellcode. Zum Ausführen der Programmdateien muss weder die .NET-Runtime noch die VC-Runtime installiert werden. Während der Nutzung wird nichts beendet; beim nächsten MCP-Start wird erneut geprüft. Ist das Kontingent normaler Anfragen der GitHub-API ohne Authentifizierung aufgebraucht, setzt es die Abfrage automatisch mit der Authentifizierung einer bereits eingerichteten GitHub CLI (`gh`) fort. Schlagen Kommunikation oder Download fehl, verwendet es die aktuelle Version, solange der Zustand vor der Aktualisierung sicher erhalten bleibt.

Die automatische Aktualisierung vertraut dem Herausgeber des GitHub Release und prüft, dass das heruntergeladene Paket übereinstimmt. Funktionsweise der Prüfung und Vertrauensumfang beschreibt das [Design der automatischen Aktualisierung beim Start](DESIGN.md#起動時自動更新).

Aktualisierungsdaten werden innerhalb eines eigenen Kontingents von 2 GiB verwaltet. Geprüfte Bereiche werden wiederverwendet, unbekannte Daten und unterbrochene Ausgaben bleiben erhalten. Bei Platzmangel wird die Aktualisierung verschoben; Wiederherstellungsdaten der Registrierung werden dafür nie bereinigt.

#### Registrierung bei einem MCP-Host

Registrieren Sie bei MCP-Hosts wie Toolport oder Claude Code das installierte Startskript als stdio-Server. Geben Sie PowerShell 7 als `pwsh` an (bei der Microsoft-Store-Version `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`) und verwenden Sie nicht den absoluten Pfad eines mit einem KI-Werkzeug mitgelieferten PowerShell.

```text
command: pwsh
args:    -NoProfile -NonInteractive -File %USERPROFILE%\.local\Prunlet\bin\start-prunlet-mcp.ps1 -ExecutablePath %USERPROFILE%\.local\Prunlet\bin\prunlet.exe -ConfigPath %USERPROFILE%\.local\Prunlet\config.json
```

Ersetzen Sie `%USERPROFILE%` durch den tatsächlichen absoluten Pfad. `-CodexHome` ist nicht nötig. Nur wenn in Codex noch eine frühere Registrierung vorhanden ist, prüft das Startskript sie schreibgeschützt und schützt sie.

#### Registrierung bei Codex (optional)

Nur wenn Sie alles auf einmal in Codex registrieren möchten, fügen Sie dem obigen Installationsprogramm `-RegisterCodex -RegisterAgentInstructions` hinzu. Damit werden der MCP-Server von Codex, der Hook für die native Programmdatei und gemeinsame Anweisungen, die von Anfang an die Prunlet-CLI verwenden, in CodexHome registriert (`CODEX_HOME`, oder `%USERPROFILE%\.codex`, falls nicht gesetzt).

Öffnen Sie nach einer Installation oder Aktualisierung mit `-RegisterCodex` in Codex `/hooks`, prüfen Sie die Definition des Prunlet-Hooks und vertrauen Sie ihm. Das Installationsprogramm ändert keine Vertrauenseinstellungen; `requiresHookTrust` im Ergebnis zeigt an, dass dieser Schritt nötig ist. Starten Sie Codex neu und prüfen Sie, dass MCP-Server, gemeinsame Anweisungen und Hook geladen sind. Registrierung und Abmeldung beschreibt die [Integrationsanleitung](docs/integration.md#登録).

`-RegisterAgentInstructions` ist eine explizite Option, die `PRUNLET.md` im Codex-Home sowie einen eigenen Verweis und die absoluten Pfade der installierten Programmdatei und Konfiguration in der gemeinsamen `AGENTS.md` registriert. Ohne etwas in jedes Repository einzufügen, weist sie Codex an, von Anfang an mit der Prunlet-CLI unter CMD zu löschen. Lässt sich der Pfad der Programmdatei oder der Konfiguration selbst nicht sicher in CMD ausdrücken, wählen Sie vor der Ausführung den MCP-Server, der denselben Kern verwendet. Lassen Sie diese Option weg, wenn die gemeinsamen Anweisungen nicht geändert werden sollen.

Die automatische Aktualisierung wechselt nur zu Kandidaten, deren Registrierungen einschließlich der gemeinsamen Anweisungen keine Änderung benötigen. Unterscheidet sich die registrierte `PRUNLET.md` vom Kandidaten nur durch CRLF- statt LF-Zeilenenden, bleibt die vorhandene Datei unverändert. Müsste eine Registrierung überschrieben werden oder wird eine Änderung einer Registrierung durch den Benutzer erkannt, wird die Aktualisierung zurückgehalten. Geben Sie bei einer manuellen Aktualisierung mit dem Installationsprogramm dasselbe `-RegisterAgentInstructions` an, wenn die gemeinsamen Anweisungen registriert sind. Einzelheiten finden Sie unter [Gemeinsame Agentenanweisungen](docs/integration.md#エージェント共通指示).

Für die erste Aktualisierung von einer alten Version ohne automatische Aktualisierung oder für eine manuelle Aktualisierung laden Sie das neueste Installationsprogramm erneut herunter und führen es aus. Die vorhandene `config.json` bleibt erhalten, abgesehen von einer einmaligen Migration der Aufbewahrungskapazität. Alte Wiederherstellungsdaten werden durch eine [explizite Migration](#migration-alter-dateiwiederherstellungsdaten) behandelt. Zu löschende Ordner müssen nicht vorab registriert werden. Das alte `-AllowedRoot` wird als Kompatibilitätsargument akzeptiert, schränkt aber nicht ein, was gelöscht werden kann. Das Installationsverzeichnis ändern Sie mit `-InstallDirectory`. Der Pfad Ihres Klons wird nie in der Konfiguration der KI-Werkzeuge registriert.

Liegt eine vorhandene verwaltete Installation in einem Git-Repository und bleibt die Aktualisierung bei der normalen Prüfung des Zielorts stehen, können Sie dem erneut heruntergeladenen Installationsprogramm `-UpdateManagedInstallation -InstallDirectory <absoluter Pfad der vorhandenen Installation>` hinzufügen. Es prüft, dass vorhandene Konfiguration, Installationsinformationen und Produkt-Hashes übereinstimmen, und aktualisiert eine Installation ohne von Git nachverfolgte Dateien, die entweder von Git ausgeschlossen ist oder der aktuellen gemeinsamen CLI-Registrierung entspricht. Eine nicht überprüfbare Installation bleibt erhalten, und das Programm hält an. Die Bedingungen beschreibt die [Integrationsanleitung](docs/integration.md#手動の設定準備).

Um die Übereinstimmung mit einem vorab geprüften Release zu verlangen, fügen Sie `-ExpectedCommitSha <40-stelliger SHA>` hinzu. Weicht der Commit des neuesten Release ab, hält es vor der Installation an.

Die heruntergeladenen Bootstrap-Dateien sind temporär. Bereinigen Sie nach Prüfung des Installationsergebnisses nur dieses Bootstrap-Verzeichnis. Nehmen Sie das Installationsverzeichnis der App und die Wiederherstellungsdaten nicht in die Bereinigung auf.

Gibt es Sicherungen der Produkte vor der Aktualisierung oder der Codex-Konfiguration vor der Registrierung, zeigt `updateBackupDirectory` im Installationsergebnis ihren Speicherort. Standard ist `%LOCALAPPDATA%\Prunlet\Backups\install-<ID>`. Nachdem Sie Verhalten und Registrierungen geprüft haben und keine Wiederherstellung mehr nötig ist, bereinigen Sie nur die Sicherung dieser Installation. Die Konfigurationssicherungen der Integrationsskripte beschreibt die [Integrationsanleitung](docs/integration.md).

In einer MSIX-Umgebung, in der AppData an einen anderen Ort umgeleitet wird, können Sie den übergeordneten Ordner der Aktualisierungssicherungen mit `-UpdateBackupRoot <absoluter Pfad des tatsächlichen Orts>` ausdrücklich festlegen. Darunter wird pro Installation ein `install-<ID>` angelegt. Ein Speicherort pro Installation, der sich mit einem Repository, dem Codex-Home, dem Installationsverzeichnis, dem Arbeitsbereich oder den Wiederherstellungsdaten überschneidet, wird abgelehnt. Ist noch ein alter PowerShell-Hook vorhanden, verschiebt das Installationsprogramm ihn mit Prunlet in den Windows-Papierkorb und speichert das Ergebnis in `retired-products.json` derselben Aktualisierungssicherung.

## Ersteinrichtung

Unter macOS und Linux wird die Konfiguration durch das Installationsverfahren des jeweiligen Systems erstellt. Im Folgenden die Ersteinrichtung unter Windows. Wenn Sie das Windows-Installationsprogramm verwendet haben, ist sie bereits initialisiert. Manuell geben Sie an, wo die Wiederherstellungsdaten der Registrierung gespeichert werden. `init` überschreibt keine vorhandene Konfiguration.

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
& $exe --config $config migrate --dry-run
& $exe --config $config migrate --apply
```

`backupDirectory` ist ein geschützter Bereich für Registrierungs-Snapshots und alte Daten aus der Zeit vor der Migration. Er speichert weder Protokolle noch Inhalte neuer Dateilöschungen. Registrierungsprotokolle werden unter dem eigenen `.registry-records-v1` gespeichert. `allowedRoots` in der Konfiguration und das alte `--allowed-root` sind Kompatibilitätseingaben und dienen nicht als Zulassungsliste dafür, was gelöscht werden darf.

Ein manuelles `init` erstellt nur die Konfiguration. Prüfen Sie vor der Nutzung der Registrierung die Ziele mit `migrate --dry-run` und führen Sie `migrate --apply` aus. Ohne Migration halten normale Registrierungsvorgänge mit `migration_required` an und durchsuchen den alten Dateibereich nicht automatisch. Das Löschen von Dateien hängt nicht vom Migrationsstatus der Registrierung ab.

```json
{
  "schema": 1,
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery",
  "retentionDays": 7,
  "maxRecoveryBytes": 1073741824
}
```

## Löschen und Wiederherstellen

### Auf Apple-Silicon-Macs

Verwenden Sie die absoluten Pfade der Programmdatei und der Konfiguration aus dem [macOS-CLI-Beispiel](docs/macos.md). Prüfen Sie die Ziele mit `delete --dry-run -- <absoluter Pfad>` und lassen Sie `--dry-run` zum Ausführen weg. Elemente mit `recycled` lassen sich aus dem Finder-Papierkorb wiederherstellen. Bei `ambiguous` prüfen Sie den ursprünglichen Pfad und den Papierkorb und senden Sie denselben Löschvorgang nicht automatisch erneut.

Um auf die Freigabe eines kooperativen `flock` zu warten, reihen Sie mit `delete-queue -- <absoluter Pfad>` ein und prüfen das Endergebnis mit `delete-queue-status <job-id>`. Abbrechen können Sie mit `delete-queue-cancel <job-id>`, solange der Status `pending` ist.

### Unter Linux

Verwenden Sie die absoluten Pfade der Programmdatei und der Konfiguration aus dem [Linux-CLI-Beispiel](docs/linux.md#初回インストール). Prüfen Sie die Ziele mit `delete --dry-run -- <absoluter Pfad>` und lassen Sie `--dry-run` zum Ausführen weg. Elemente auf demselben Mount wie der Papierkorb im Home-Verzeichnis können verschoben werden. Elemente mit `recycled` lassen sich mit einem Dateimanager wiederherstellen, der den freedesktop-Papierkorb unterstützt. Bei `ambiguous` prüfen Sie den ursprünglichen Pfad und den Papierkorb und senden Sie denselben Löschvorgang nicht automatisch erneut.

### Unter Windows

Auf Codex-Hosts, die formale Sandbox-Berechtigungsanfragen unterstützen und deren effektive Konfiguration eine solche Anfrage verlangt und erlaubt, führen Sie tatsächliche Löschvorgänge schon beim ersten Versuch mit der Anfrage aus. Ein Dry-Run garantiert keine Berechtigung für den Zugriff auf den Papierkorb. Sind Windows-Administratorrechte nötig, startet der Agent im erlaubten Rahmen ein Administrator-CMD und führt mit derselben installierten CLI und Konfiguration aus und prüft das Ergebnis. Ist Ihre UAC-Zustimmung nötig, leitet er Sie durch diesen Schritt. Prunlet erhöht seine Rechte nie automatisch und versucht Verweigerungen oder unbekannte Ergebnisse nicht auf einem anderen Weg erneut. Einzelheiten beschreibt die [Integrationsanleitung](docs/integration.md#sandboxとゴミ箱へのアクセス).

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --dry-run --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --paths-file C:\work\delete-paths.json
```

Ersetzen Sie Programmdatei und Konfiguration durch die absoluten Pfade Ihrer Installation. Geben Sie in Codex `cmd.exe` und `login: false` an. Erweitern Sie Zielpfade mit Leerzeichen, Unicode, vielen Elementen oder langen Pfaden nicht in der Shell, sondern übergeben Sie sie als absolute Pfade in einem UTF-8-JSON-Array. `--paths-file` akzeptiert 1 bis 256 Einträge und bis zu 1 MiB.

```json
["C:\\work\\project\\unused.txt", "C:\\work\\project\\other.txt"]
```

Verwenden Sie für leere Ordner ein normales `delete` und für Ordner mit Inhalt `delete --recursive --paths-file <absoluter JSON-Pfad>`. Einfache Pfade können auch als `delete [--dry-run] [--recursive] -- <absoluter Pfad> [...]` übergeben werden. Platzhalter, Netzwerkpfade und unbekannte Reparse-Tags werden nicht verarbeitet. Bei einem Link wird der Link selbst gelöscht, ohne sein Ziel zu durchlaufen. Eine gewöhnliche Datei mit demselben Namen wie ein reservierter Windows-Name, etwa `NUL` oder `NUL.txt`, wird nach Prüfung ihrer Identität ohne weitere Rückfrage endgültig gelöscht. Sie landet nicht im Papierkorb. Übergeordnete Elemente, Verzeichnisse und Links mit reservierten Namen fallen nicht unter diese Ausnahme. Bei gewöhnlichen Namen wird das endgültige Löschen nach Abgleich des ursprünglichen Elements und Namens nur versucht, wenn Windows meldet, dass das Ziel zu groß für den Papierkorb ist, oder wenn der Papierkorb nicht verfügbar ist und die Einstellung zum sofortigen Löschen des Ziellaufwerks bestätigt wurde.

Das Ergebnis enthält `dryRun`, `items` und `warnings`. Prüfen Sie für jedes Element `path`, `kind`, `status` und das optionale `error`. Die Status sind `recycled`, `permanently_deleted`, `would_recycle`, `would_permanently_delete`, `already_absent`, `failed` und `ambiguous`; Vorgangs-ID, backupPath, Hash oder Größe einer Datei werden nicht zurückgegeben. `permanently_deleted` bedeutet, dass der angegebene ursprüngliche Name gelöscht wurde, ohne ihn in den Papierkorb zu verschieben; es bedeutet nicht, dass andere feste Links oder Sicherungen gelöscht wurden. `failed` und `ambiguous` gelten nicht als Erfolg.

Stellen Sie `recycled`-Elemente aus dem Windows-Papierkorb wieder her. Der ursprüngliche Name eines `permanently_deleted`-Elements lässt sich nicht aus dem Papierkorb wiederherstellen. Prunlet hat keinen Befehl und kein MCP-Werkzeug zur Wiederherstellung von Dateien. Existiert am Wiederherstellungsort des Papierkorbs bereits ein Element, prüfen Sie den Konflikt in der Windows-Oberfläche und überschreiben Sie es nicht.

Kann ein Element nicht verschoben werden, weil es verwendet wird, Berechtigungen fehlen oder Pfadgrenzen erreicht sind, prüfen Sie das Ergebnis. Bei einem Fehler enthält `error` das Ziel und den Fehlercode und gibt bei Verwendung zusätzlich PID, Name und Dateipfad der beobachteten Halter zurück. Beim rekursiven endgültigen Löschen beziehen sich `path` im Ergebnis und `Target` in `error` auf den angegebenen Ordner. Ein vorhandener `Failure entry` gibt den absoluten Pfad des fehlgeschlagenen Eintrags an, und die Halterdiagnose bezieht sich ebenfalls auf diesen Eintrag. Umfang und Grenzen der Diagnose beschreibt die [Integrationsanleitung](docs/integration.md#使用中のファイルと同時実行). Wird der Zielname während der Shell-Verarbeitung ersetzt, kann ein anderes Element in den Papierkorb verschoben werden. Prunlet prüft das verschobene Element und hält mit `ambiguous` an, wenn es nicht übereinstimmt. Bei `ambiguous` prüfen Sie das ursprüngliche Ziel und den Windows-Papierkorb; derselbe Löschvorgang wird nicht automatisch erneut gesendet. Für eine gewöhnliche Datei mit reserviertem Namen liefert ein Dry-Run `would_permanently_delete` und löscht sie nicht tatsächlich. Jedes andere `would_recycle` ist das Ergebnis der Vorabprüfung der Eingabe und kann nicht vorhersagen, ob es bei der Ausführung zu `permanently_deleted` wird oder ob das tatsächliche Verschieben gelingt.

Auch die Zugriffsrechte während des Aufenthalts im Windows-Papierkorb und die Vererbung von Berechtigungen vom übergeordneten Ordner des Wiederherstellungsorts folgen dem Verhalten von Windows. Feste Links teilen nicht nur den Inhalt, sondern auch die ACLs; Berechtigungsänderungen beim Verschieben in den Papierkorb wirken sich daher auch auf die verbleibenden Aliase aus.

### Verwendete Dateien nach Wartezeit löschen

Um unter Windows auf ein verwendetes Ziel zu warten, reihen Sie es vor Beginn des Löschens in die explizite `delete-queue` ein. Ein normales `delete` liefert sein Ergebnis weiterhin synchron.

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-status <job-id>
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-cancel <job-id>
```

Geben Sie nicht leere Ordner mit `delete-queue --recursive --paths-file <absoluter JSON-Pfad>` und einfache Pfade mit `delete-queue [--recursive] -- <absoluter Pfad> [...]` an. Die Antwort auf das Einreihen bedeutet nicht, dass das Löschen abgeschlossen ist. Prüfen Sie Status und Endergebnis mit der zurückgegebenen Auftrags-ID. In MCP geben Sie dem vorhandenen `delete_files` `action: "enqueue"`, `"status"` oder `"cancel"` mit. Einzelheiten beschreibt die [Integrationsanleitung](docs/integration.md#明示的な削除待機キュー).

Vor dem Löschen fixiert die Warteschlange die Identität des Ziels, seines übergeordneten Ordners und bei rekursiven Zielen seiner untergeordneten Elemente und wartet ohne Zeitlimit nur auf Freigabe- und Sperrverletzungen. Ändert sich während des Wartens eine Identität, wird abgebrochen; Fehler oder unbekannte Ergebnisse nach Beginn des Löschens werden nicht erneut gesendet. Bis zu 8 Aufträge pro Benutzer und Windows-Sitzung (einschließlich nach Abschluss aufbewahrter). Ein Auftrag kann nur während des Wartens abgebrochen werden, und das Endergebnis wird eine Stunde lang aufbewahrt. Aufträge existieren nur im Speicher eines eigenen temporären Workers und sind weder Dateivorgangsprotokolle noch Wiederherstellungs-IDs. Lässt sich das Ergebnis nicht bestätigen, weil es abgelaufen ist oder das Betriebssystem oder der Worker beendet wurde, prüfen Sie das ursprüngliche Ziel und den Windows-Papierkorb und senden Sie denselben Löschvorgang nicht automatisch erneut.

## Löschen und Wiederherstellen in der Registrierung

Erlaubte lokale Schlüssel oder Werte unter HKCU, HKLM und HKU lassen sich in einer ausdrücklich angegebenen 32- oder 64-Bit-View sichern und löschen. Geben Sie den Schlüsselpfad als absoluten Pfad an und übergeben Sie genau einen nach `--`. Ohne `--value-name` ist der Schlüssel das Ziel, mit der Option der wörtliche Wertname. Der Standardwert hat einen leeren Namen; verwenden Sie daher `--value-name=`, das PowerShell nicht als leeres Argument verwirft. Das Löschen von Werten lässt sich nicht mit `--recursive` kombinieren. Zum Löschen eines Schlüssels mit Unterschlüsseln ist `--recursive` erforderlich.

Ein Doppelpunkt in einem Schlüsselnamen kann unverändert angegeben werden. So ist etwa das Ende von `HKCU:\Software\Example\C:#Program Files#Fixture.exe` ein einziger Schlüsselname. Namen mit `%5C` und Ähnlichem werden ebenfalls wörtlich genommen, ohne URL-Dekodierung.

```text
prunlet --config <absoluter Pfad> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
prunlet --config <absoluter Pfad> registry-delete --view 64 --recursive -- HKCU:\Software\Example
prunlet --config <absoluter Pfad> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
prunlet --config <absoluter Pfad> registry-restore <operation-id>
```

Sicherungsdaten und Protokolle werden mit Berechtigungen geschützt, auf die nur der aktuelle Benutzer und SYSTEM zugreifen können, und Protokolle mit manipulierten Berechtigungen bleiben erhalten, ohne wiederhergestellt oder bereinigt zu werden. Zum Speichern der Schlüsseldaten und der vollständigen Zugriffsrechte ist `SeSecurityPrivilege` erforderlich. Reichen die Berechtigungen nicht aus oder sind keine Transaktionen verfügbar, hält es vor dem Löschen an und erhöht seine Rechte nie automatisch. Das Wiederherstellen eines Werts ändert die Zugriffsrechte des übergeordneten Schlüssels nicht. Für geschützte Ziele unter 64-Bit-Windows mit einem 64-Bit-Prozess und View 64 kann `--access-mode backupRestore` für jede Löschung, jeden Dry-Run und jede Wiederherstellung ausdrücklich angegeben werden. Dafür sind `SeBackupPrivilege` und `SeRestorePrivilege` im aktuellen effektiven Token nötig, und der Zugriff wird nicht durch Ändern von ACLs oder Besitz erlangt. Standard ist `normal`, ohne automatischen Wechsel. Prüfen Sie auch die [Auswahlbedingungen und Grenzen](docs/integration.md#保護されたレジストリへの明示アクセス). Speicherformat und Transaktionsdesign beschreibt [DESIGN.md](DESIGN.md#レジストリの削除と復元).

Die Wiederherstellung erfolgt in die ursprüngliche View und überschreibt oder vereinigt nie vorhandene Schlüssel oder Werte (einschließlich eines leeren Standardwerts). Reichen die Rechte zum Wiederherstellen von Owner oder SACL nicht aus, wird zurückgesetzt und die Sicherung bleibt erhalten. Der Stamm selbst, HKCR/HKCC, entfernte oder relative Pfade, beliebige Registrierungslinks, unbekannte Schemas, Metadaten und nicht überprüfbare Wiederherstellungsprotokolle werden abgelehnt. Die Klasse des Schlüssels wird ebenfalls gespeichert, der Zeitpunkt des letzten Schreibens wird jedoch nicht wiederhergestellt, und volatile Schlüssel werden als nicht volatile Schlüssel wiederhergestellt. Ein Vorgang, der nach dem Commit, aber vor dem Abschluss seines Protokolls unterbrochen wurde, bleibt als unbekannt erhalten, und automatische Bereinigung und Wiederherstellung werden abgelehnt.

Einträge unter dem Alias `Software\Classes` des effektiven Benutzers werden nach Prüfung des Ziels verarbeitet. Löschen und Wiederherstellen erfordern zusätzliche Schreibberechtigung für den Alias, und der Zeitpunkt des letzten Schreibens des Alias kann sich ändern. Ein Dry-Run schreibt nicht. Classes selbst und andere Links sind keine Ziele. Unterstützte Pfade und Sicherheitsbedingungen beschreibt das [Design](DESIGN.md#レジストリの削除と復元).

Tritt in einer virtuellen View aus MSIX der Fehler 6801 auf, können Sie eine [explizite Sitzung im normalen Windows](docs/integration.md#通常windowsのレジストリを明示して操作する) verwenden. Sie starten auf dem normalen Desktop eine zeitlich begrenzte Sitzung und verbinden sich aus der CLI oder dem MCP mit einer ausgewählten eigenen Konfiguration. Es gibt weder einen automatischen Wechsel aus der virtuellen View noch eine automatische Rechteerhöhung, und Schlüssel in der virtuellen View werden nicht als gleichnamige Schlüssel im normalen Windows behandelt.

Geht die Antwort der Sitzung verloren, bewahren Sie die gemeldete `operationId` auf und prüfen Sie das gespeicherte Ergebnis mit `prunlet --config <absoluter Pfad derselben Konfiguration> registry-reconcile <operation-id>`. Senden Sie denselben Löschvorgang nicht erneut, und schließen Sie nicht aus dem aktuellen Vorhandensein des Schlüssels auf ein unbekanntes Commit-Ergebnis. Eine erfolgreiche Wiederherstellung verbraucht den Snapshot, sodass dieselbe Vorgangs-ID nicht wiederholt wiederhergestellt werden kann.

Ein `--dry-run` der Registrierung prüft auch die Verbindung zur Transaktion mit demselben Ziel, denselben Berechtigungen und derselben Rekursion wie das tatsächliche Löschen und schlägt fehl, wenn keine Verbindung möglich ist. Er schreibt oder löscht keine Daten und garantiert nicht, dass ein anschließendes tatsächliches Löschen gelingt.

## Aufbewahrung und automatische Bereinigung von Wiederherstellungsdaten

`retentionDays` (Standard 7 Tage) und `maxRecoveryBytes` (Standard 1 GiB) gelten nur für Registrierungs-Snapshots. Windows bewahrt den Windows-Papierkorb auf und bereinigt ihn, und Prunlet bezieht ihn weder in Kapazität noch Aufbewahrungsfrist oder purge ein.

Fehlt in einer alten Konfiguration die Markierung der Kapazitätsmigration oder ist sie kleiner als 1, setzt die latest-Installation `maxRecoveryBytes` einmalig auf 1 GiB. Eine vom Benutzer nach der Migration geänderte Kapazität bleibt bei späteren Aktualisierungen erhalten.

`operations` listet die Vorgangs-IDs der Registrierung auf, und `purge <registry-operation-id> [--dry-run | --apply]` sowie `maintain [--dry-run | --apply] [--audit-records]` gelten ebenfalls nur für die Registrierung. Ohne Optionen wird nur geprüft. Vor dem Löschen sowie bei expliziter und geplanter Wartung werden geschützte Protokolle geprüft und die Aufbewahrungsbedingungen angewendet. Unklare Protokolle und nicht überprüfbare Snapshots bleiben erhalten.

## Migration alter Dateiwiederherstellungsdaten

`migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]` bereinigt alte Datei-Sicherungsdaten und Vorgangsprotokolle und verschiebt alte Registrierungsprotokolle in den eigenen Namespace. **Die Wiederherstellungskompatibilität für alte Dateien endet.** Alte Dateibereiche, deren Besitz bestätigt werden kann, werden unverändert in den Windows-Papierkorb gesendet, ohne das Format zu entpacken, Inhalts-Hashes zu prüfen, zu kopieren oder zu bündeln. Dateien, die bereits im Papierkorb liegen, bleiben unter der Verwaltung von Windows. Es werden weder alte Daten für die Wiederherstellung umgewandelt noch Referenzdateien der ursprünglichen Berechtigungen erstellt.

Das Installationsprogramm führt `migrate --apply --if-needed` nach der Registrierung und nach dem Stilllegen des alten Backends aus. Bereits bewertete zentrale alte Bereiche werden nicht erneut durchsucht, und bei einer Aktualisierung werden auch eigene alte Daten auf später verbundenen Laufwerken geprüft. Normales Löschen, Auflisten und Warten von Dateien durchsucht alte Vorgangsverzeichnisse nicht. Das Design von Besitzprüfung und erneuter Durchsuchung beschreibt [DESIGN.md](DESIGN.md#旧ファイル復元データの明示移行).

Bewahrung der Registrierung, vollständige ACLs und nicht überschreibende Wiederherstellung bleiben erhalten. Bereiche mit Registrierungsspuren, Bereiche mit unbestätigtem Besitz sowie Offline-Bereiche oder solche mit unzureichenden Berechtigungen bleiben mit einer Warnung bestehen, und eine unvollständige Dateibereinigung allein hält normale Registrierungsvorgänge nicht an.

Eine unterbrochene Dateibereinigung oder eine mit unbekanntem Ergebnis wird nicht automatisch erneut gesendet und hält an einem festen leeren Gate an. Erst nachdem Sie den ursprünglichen Ordner und den Windows-Papierkorb geprüft haben, bewerten Sie sie mit `migrate --apply --retry-legacy-discard` ausdrücklich neu. Das Installationsprogramm gibt diese Bestätigung nie automatisch an. Schlägt die Installation nach Beginn der Migration fehl, bleiben die neuen Programmdateien, die Konfiguration und die Registrierungen erhalten, und es wird nicht zur alten Binärdatei zurückgekehrt.

## MCP

`prunlet --config <absoluter Pfad> mcp` startet einen lokalen stdio-Server. Die Standardausgabe ist JSON-RPC vorbehalten. Die MCP-Protokollversionen 2025-11-25, 2025-06-18 und 2024-11-05 werden unterstützt. Synchrones Löschen mit `delete_files` funktioniert unter Windows, macOS und Linux; Einreihen, Abfragen und Abbrechen funktionieren unter Windows und macOS. Die übrigen Werkzeuge in der Tabelle gibt es nur unter Windows.

| Werkzeug | Argumente | Zweck |
| --- | --- | --- |
| `delete_files` | Synchron: `paths`, optional `dryRun` und `recursive`. Einreihen: `action: "enqueue"` und `paths`, optional `recursive`. Abfragen und Abbrechen: nur `action: "status"` / `"cancel"` und `jobId` | Synchrones Löschen von Dateien und Ordnern sowie Einreihen, Abfragen und Abbrechen. Einreihen unterstützt kein `dryRun` |
| `delete_registry` | `path` und `view` (`"32"`/`"64"`), optional `valueName`, `recursive`, `dryRun` und `accessMode` | Löscht einen Schlüssel oder Wert nach dessen Sicherung. Ein leerer `valueName` ist der Standardwert. `accessMode` ist `normal` oder `backupRestore` |
| `restore_registry` | `operationId`, optional `accessMode` | Stellt einen Registrierungsvorgang ohne Überschreiben wieder her. Geschützter Zugriff wird auch bei der Wiederherstellung ausdrücklich gewählt |
| `reconcile_registry` | `operationId` | Liest und prüft das gespeicherte Ergebnis nach einer Verbindungstrennung. Sendet Löschen oder Wiederherstellen nicht erneut |
| `list_operations` | Keine | Listet die Vorgangs-IDs der Registrierung auf (ob sie wiederherstellbar sind, wird bei der Wiederherstellung geprüft) |

Der Server kündigt den Zweck der Löschwerkzeuge in `instructions` an. Unter Windows wird normalerweise die CLI verwendet, und der MCP-Server kann zum Beispiel dann genutzt werden, wenn sich die installierte Programmdatei oder Konfiguration nicht sicher in CMD ausdrücken lässt. `purge` der Registrierung ist ein expliziter CLI-Vorgang.

## Integration mit Codex

Die gemeinsame MCP-Registrierung unter Windows, die Prüfung von Löscheingaben und die Abmeldung beschreibt die [Integrationsanleitung](docs/integration.md). Beispiele für die MCP-Registrierung und die Startargumente des Hooks unter macOS und Linux finden Sie im jeweiligen Installationsverfahren. [Installation unter macOS](docs/macos.md) · [Installation unter Linux](docs/linux.md)

Der Hook verweigert erkannte direkte Löschvorgänge und gibt den erkannten Befehl und die Shell-Interpretation als Grund zurück. Ist die Shell unbekannt, ist die Beurteilung nur ein Kandidat und keine bestätigte lokale Löschung. Werden Suchzeichenfolgen oder entfernte Skripte verweigert, prüfen Sie den [Prüfumfang des Hooks](docs/integration.md#hookの検査範囲). Die CLI, auf die der Hook verweist, dient zum Löschen von Zielen auf dem erlaubten Host-Betriebssystem. Er ersetzt weder Löschvorgänge noch Eingaben automatisch. Die Genehmigungen und Verwaltungsrichtlinien von Codex bleiben wirksam.

## Wenn die Prüfung des Speicherorts anhält

Bei MSIX-Apps können neue Ordner in AppData in den paketeigenen LocalCache umgeleitet werden. Die Umleitung gewöhnlicher Verzeichnisse wird auf den tatsächlichen Ort aufgelöst; lassen sich jedoch ein übergeordneter Link oder der tatsächliche Ort und seine Attribute nicht prüfen, hält es an. Prüfen Sie Pfad und Attribute aus der Fehlermeldung und legen Sie, ohne die Prüfung zu deaktivieren, Programmdatei, Konfiguration und Wiederherstellungsdaten bei Bedarf in einem eigenen Verzeichnis wie `%USERPROFILE%\.local\Prunlet` ab. Es wird nicht empfohlen, den LocalCache des Codex-Pakets als dauerhaften Speicherort für Wiederherstellungsdaten zu verwenden.

## Wenn Registrierungstransaktionen nicht verfügbar sind

Sind für den Ziel-Hive keine Transaktionen verfügbar, etwa bei `ERROR_RM_NOT_ACTIVE` (6801), wird das Löschen nicht per Commit übernommen; die ursprünglichen Daten bleiben erhalten, und es hält an. Die Verfügbarkeit kann sich selbst auf demselben PC je nach Hive unterscheiden. Wechseln Sie nicht zum nicht transaktionalen Löschen und reparieren Sie das Betriebssystem nicht, ohne die Ursache zu kennen; prüfen Sie den Fehler sowie den Ziel-Hive und die View.

## Entwicklungsdokumente

Builds während der Entwicklung und Arbeitsregeln beschreibt [AGENTS.md](AGENTS.md), Struktur und Designentscheidungen [DESIGN.md](DESIGN.md), und Ausführung und Umfang der E2E-Tests die [Verifikationsanleitung](docs/verification.md).
