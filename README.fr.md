[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md) | [Español](README.es.md) | **Français** | [Deutsch](README.de.md) | [Português (Brasil)](README.pt-BR.md)

# Prunlet — Anti “blocked by policy”

Prunlet est un outil pour Windows, Mac Apple Silicon et Linux qui fait passer la suppression de fichiers et de dossiers par les agents d'IA par une CLI et un serveur MCP dédiés, afin que le nettoyage s'arrête moins souvent sur `blocked by policy`. Il uniformise l'usage consistant à confier dès le départ à Prunlet les suppressions autorisées.

Les fichiers et dossiers vont normalement dans la corbeille du système d'exploitation. Prunlet n'enregistre ni historique d'opérations sur les fichiers, ni ID d'opération, ni snapshot de restauration ; la restauration depuis la corbeille et sa conservation sont laissées au système. Il n'est fourni avec aucun outil d'IA en particulier et s'installe comme une application autonome. Vous pouvez enregistrer à votre gré son serveur MCP, sa CLI et son hook dans chaque outil d'IA ; le hook inspecte et refuse les suppressions directes et indique la procédure avec la CLI. Publié par Kagayoi.

Il gère les fichiers et les dossiers vides, et supprime un dossier entier lorsque `--recursive` est indiqué explicitement. Les cibles des liens ne sont jamais suivies. Un lien physique mis à la corbeille continue de partager son contenu avec les alias restants. La suppression définitive conditionnelle et la [suppression et restauration du registre](#suppression-et-restauration-du-registre) sont propres à Windows.

## Utilisation contre `blocked by policy`

Là où le nettoyage s'arrête souvent sur des commandes de suppression générées par l'IA, comme `Remove-Item` ou `rm`, confiez dès le départ les suppressions autorisées à la CLI Prunlet. Codex sur Mac Apple Silicon et sur Linux utilise la CLI et la configuration placées lors de l'installation. [Installation sur macOS](docs/macos.md) · [Installation sur Linux](docs/linux.md)

Sous Windows, procédez dans cet ordre :

1. Installez Prunlet comme application autonome avec la commande de la section [Installation et mises à jour](#installation-et-mises-à-jour) ci-dessous. Il ne touche pas aux fichiers de configuration des outils d'IA.
2. Enregistrez la commande de démarrage de la section [Enregistrement dans un hôte MCP](#enregistrement-dans-un-hôte-mcp) dans les outils d'IA (hôtes MCP) que vous utilisez. Pour appeler directement la CLI, inscrivez les chemins absolus de la CLI et de la configuration installées dans les instructions de l'outil d'IA. Pour tout enregistrer d'un coup dans Codex, utilisez [Enregistrement dans Codex (facultatif)](#enregistrement-dans-codex-facultatif).
3. Demandez le travail et le nettoyage comme d'habitude. La CLI est appelée directement depuis CMD (`shell: cmd.exe`, `login: false`) avec les chemins absolus de la CLI et de la configuration installées. Inutile d'ajouter les mêmes instructions dans chaque dépôt.

Pour demander explicitement un nettoyage, dites par exemple :

> Nettoie dès le départ avec la CLI Prunlet les fichiers temporaires et les dossiers de travail inutiles créés cette fois-ci.

Transmettez les chemins contenant des espaces, de l'Unicode, les chemins longs ou plusieurs cibles sous forme de liste JSON en UTF-8 avec `--paths-file`, et indiquez explicitement `--recursive` pour les dossiers non vides. Consultez [Suppression et restauration](#suppression-et-restauration) pour les commandes réelles et la restauration.

Le hook est une aide qui détecte et refuse les suppressions directes et indique la procédure avec la CLI ; il ne convertit pas les commandes automatiquement. Pour éviter les échecs et nouvelles tentatives à répétition, la règle de base est d'utiliser la CLI dès la première tentative grâce aux instructions communes. Les autorisations, approbations et stratégies de gestion de l'hôte et du système continuent de s'appliquer. Si l'appel à Prunlet lui-même est refusé, arrêtez-vous et ne réessayez pas par une autre voie. Consultez le [guide d'intégration](docs/integration.md) pour l'enregistrement et le périmètre d'inspection.

Les scripts PowerShell que Codex envoie vers un Mac ou ailleurs doivent être transmis sous la forme explicite de PowerShell enfant décrite dans le [guide d'intégration du hook](docs/integration.md#hookの検査範囲). L'entrée du hook de Codex ne contient pas le shell d'exécution ; indiquer seulement `shell: "pwsh"` ne permet donc pas de distinguer les suppressions à l'intérieur d'un here-string.

## Installation et mises à jour

### Mac Apple Silicon

Récupérez `prunlet-update-osx-arm64.zip` depuis [GitHub Releases](https://github.com/1llum1n4t1s/Prunlet/releases/latest). `scripts/Install-Prunlet.sh` effectue en une seule exécution le téléchargement, la vérification de la taille et du SHA-256, la vérification de la signature et de la notarisation, et une nouvelle installation dans un dossier dédié (voir [Installation sur macOS](docs/macos.md)). Enregistrez vous-même le serveur MCP dans Codex ou d'autres hôtes avec les lignes de configuration affichées. Un serveur MCP enregistré vérifie les mises à jour au démarrage et les reporte à un démarrage ultérieur tant qu'il est utilisé.

### Linux

Récupérez `prunlet-linux-x64.tar.gz` ou `prunlet-linux-arm64.tar.gz` selon votre processeur, ainsi que le fichier `.sha256` du même nom. [GitHub Releases](https://github.com/1llum1n4t1s/Prunlet/releases)

Consultez [Installation sur Linux](docs/linux.md#初回インストール) pour vérifier la somme de contrôle, le placer dans un répertoire dédié et l'enregistrer dans Codex. Placée comme indiqué, la version officielle vérifie les mises à jour au démarrage du serveur MCP et les reporte à un démarrage ultérieur tant qu'il est utilisé.

### Windows

Windows x64 et ARM64 sont pris en charge. Le programme d'installation ci-dessous télécharge le paquet précompilé et signé (`prunlet-update-<runtime>.zip`) depuis la dernière release du [dépôt GitHub](https://github.com/1llum1n4t1s/Prunlet) et le place. Seul PowerShell 7 est nécessaire ; Rust, les outils de compilation MSVC et le Windows SDK ne le sont pas.

| Cible | Option du programme d'installation |
| --- | --- |
| Windows x64 | `-Runtime win-x64` (par défaut) |
| Windows ARM64 | `-Runtime win-arm64` |

Sous Windows ARM64, ajoutez explicitement `-Runtime` à la commande ci-dessous. Pour choisir l'émulation x64, indiquez `-Runtime win-x64`.

```powershell
$installerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Prunlet\bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $installerDirectory | Out-Null
$installer = Join-Path $installerDirectory 'Install-Prunlet.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.ps1' -OutFile $installer
pwsh -NoProfile -File $installer
```

Si la limite non authentifiée de l'API GitHub est atteinte, ajoutez `-UseGitHubCliAuthentication` à la commande `pwsh` ci-dessus pour utiliser une GitHub CLI existante déjà connectée. Il n'installe pas gh et ne se connecte pas à votre place. Cette option est réservée au programme d'installation manuel.

Le programme d'installation récupère la dernière release stable depuis l'API GitHub et vérifie que son tag pointe vers un commit de la branche par défaut et qu'un seul paquet pour le runtime cible est joint. Avant de placer le ZIP téléchargé, il vérifie la taille et le SHA-256 renvoyés par GitHub, la liste des fichiers inclus et chaque hash, le commit et le runtime de la release, ainsi que la signature Authenticode des exécutables (Valid, avec le signataire attendu et un horodatage). Ce sont les mêmes vérifications que la mise à jour automatique au démarrage. Si, juste après une release, le paquet n'est pas encore signé et joint, ou si une vérification échoue, il s'arrête sans rien écrire. Il ne compile jamais depuis les sources et ne bascule jamais vers un clone local.

Le répertoire d'installation par défaut est `%USERPROFILE%\.local\Prunlet`. Il y place `bin\prunlet.exe`, les scripts d'enregistrement et les instructions communes, et enregistre la source, la branche, le commit et le hash du paquet dans `source-info.json` au même format que la mise à jour automatique au démarrage. Par défaut, il n'écrit rien dans les fichiers ou dossiers de configuration de Codex ou d'autres outils d'IA, et n'enregistre que la tâche de maintenance et la tâche de mise à jour.

La mise à jour automatique vérifie les binaires précompilés de GitHub Releases lorsqu'un hôte MCP démarre le serveur MCP de Prunlet et depuis la tâche de mise à jour enregistrée par le programme d'installation (chaque jour à 12 h 30 et 10 minutes après l'ouverture de session, sans fenêtre), puis bascule une fois que l'ancien serveur MCP et les processus de maintenance se sont terminés. Grâce à la tâche de mise à jour, les PC qui n'enregistrent pas le serveur MCP suivent aussi la dernière version. La mise à jour automatique ne recompile pas depuis les sources. L'exécution des exécutables du produit ne nécessite pas d'installer le runtime .NET ni le runtime VC. Tant qu'il est utilisé, rien n'est arrêté ; il revérifie au prochain démarrage du MCP. Lorsque la limite de requêtes normales non authentifiées de l'API GitHub est épuisée, il poursuit automatiquement la consultation avec l'authentification d'une GitHub CLI (`gh`) déjà configurée. Si la communication ou le téléchargement échoue, il utilise la version actuelle tant que l'état antérieur à la mise à jour est préservé en toute sécurité.

La mise à jour automatique fait confiance à l'éditeur de la GitHub Release et vérifie que le paquet téléchargé correspond. Consultez la [conception de la mise à jour automatique au démarrage](DESIGN.md#起動時自動更新) pour le fonctionnement de la vérification et ce qui est considéré comme fiable.

Les données de mise à jour sont gérées dans un quota dédié de 2 Gio. Les zones vérifiées sont réutilisées, et les données inconnues et les sorties interrompues sont conservées. En cas de manque d'espace, la mise à jour est reportée ; les données de récupération du registre ne sont jamais nettoyées pour autant.

#### Enregistrement dans un hôte MCP

Pour les hôtes MCP comme Toolport ou Claude Code, enregistrez le script de démarrage installé comme serveur stdio. Indiquez PowerShell 7 sous la forme `pwsh` (pour la version du Microsoft Store, `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`), et n'utilisez pas le chemin absolu d'un PowerShell fourni avec un outil d'IA.

```text
command: pwsh
args:    -NoProfile -NonInteractive -File %USERPROFILE%\.local\Prunlet\bin\start-prunlet-mcp.ps1 -ExecutablePath %USERPROFILE%\.local\Prunlet\bin\prunlet.exe -ConfigPath %USERPROFILE%\.local\Prunlet\config.json
```

Remplacez `%USERPROFILE%` par le chemin absolu réel. `-CodexHome` n'est pas nécessaire. Ce n'est que lorsqu'un ancien enregistrement subsiste dans Codex que le script de démarrage le vérifie, en lecture seule, et le protège.

#### Enregistrement dans Codex (facultatif)

Uniquement pour tout enregistrer d'un coup dans Codex, ajoutez `-RegisterCodex -RegisterAgentInstructions` au programme d'installation ci-dessus. Il enregistre le serveur MCP de Codex, le hook de l'exécutable natif et des instructions communes qui utilisent la CLI Prunlet dès le départ, dans CodexHome (`CODEX_HOME`, ou `%USERPROFILE%\.codex` s'il n'est pas défini).

Après une installation ou une mise à jour avec `-RegisterCodex`, ouvrez `/hooks` dans Codex, examinez la définition du hook Prunlet et accordez-lui votre confiance. Le programme d'installation ne modifie pas les paramètres de confiance ; `requiresHookTrust` dans son résultat indique que cette étape est nécessaire. Redémarrez Codex et vérifiez que le serveur MCP, les instructions communes et le hook sont chargés. Consultez le [guide d'intégration](docs/integration.md#登録) pour l'enregistrement et la désinscription.

`-RegisterAgentInstructions` ci-dessus est une option explicite qui enregistre `PRUNLET.md` dans le Codex home, ainsi qu'une référence dédiée et les chemins absolus de l'exécutable et de la configuration installés dans le `AGENTS.md` commun. Sans rien ajouter à chaque dépôt, elle demande à Codex de supprimer dès le départ avec la CLI Prunlet sous CMD. Si le chemin de l'exécutable ou de la configuration lui-même ne peut pas être exprimé sans risque dans CMD, choisissez avant l'exécution le serveur MCP, qui utilise le même cœur. Omettez cette option si vous ne voulez pas modifier les instructions communes.

La mise à jour automatique ne bascule que vers des candidats dont les enregistrements, y compris les instructions communes, ne nécessitent aucune modification. Si le `PRUNLET.md` enregistré ne diffère du candidat que par les fins de ligne CRLF ou LF, le fichier existant est conservé tel quel. Si un enregistrement devait être écrasé, ou si une modification d'un enregistrement par l'utilisateur est détectée, la mise à jour est suspendue. Lors d'une mise à jour manuelle avec le programme d'installation, indiquez le même `-RegisterAgentInstructions` si les instructions communes sont enregistrées. Consultez les [instructions communes de l'agent](docs/integration.md#エージェント共通指示) pour plus de détails.

Pour la première mise à jour depuis une ancienne version sans mise à jour automatique, ou pour une mise à jour manuelle, retéléchargez le dernier programme d'installation et exécutez-le. Le `config.json` existant est conservé, sauf pour une migration unique de la capacité de conservation. Les anciennes données de récupération sont traitées par une [migration explicite](#migration-des-anciennes-données-de-récupération-de-fichiers). Il n'est pas nécessaire d'enregistrer à l'avance les dossiers à supprimer. L'ancien `-AllowedRoot` est accepté comme argument de compatibilité mais ne restreint pas ce qui peut être supprimé. Changez le répertoire d'installation avec `-InstallDirectory`. Le chemin de votre clone n'est jamais enregistré dans la configuration des outils d'IA.

Si une installation gérée existante se trouve dans un dépôt Git et que la mise à jour s'arrête lors de la vérification normale de la destination, vous pouvez ajouter `-UpdateManagedInstallation -InstallDirectory <chemin absolu de l'installation existante>` au programme d'installation retéléchargé. Il vérifie que la configuration existante, les informations d'installation et les hashes des produits correspondent, et met à jour une installation qui n'a aucun fichier suivi par Git et qui est soit exclue par Git, soit conforme à l'enregistrement actuel de la CLI commune. Une installation invérifiable est conservée et le programme s'arrête. Consultez le [guide d'intégration](docs/integration.md#手動の設定準備) pour les conditions.

Pour exiger la correspondance avec une release vérifiée au préalable, ajoutez `-ExpectedCommitSha <SHA de 40 caractères>`. Si le commit de la dernière release diffère, il s'arrête avant l'installation.

Les fichiers bootstrap téléchargés sont temporaires. Après avoir vérifié le résultat de l'installation, ne nettoyez que ce répertoire bootstrap. N'incluez pas le répertoire d'installation de l'application ni les données de récupération dans le nettoyage.

S'il existe des sauvegardes des produits antérieurs à la mise à jour ou de la configuration Codex antérieure à l'enregistrement, `updateBackupDirectory` dans le résultat de l'installation indique leur emplacement. La valeur par défaut est `%LOCALAPPDATA%\Prunlet\Backups\install-<ID>`. Après avoir vérifié le fonctionnement et les enregistrements, et une fois qu'aucune récupération n'est nécessaire, ne nettoyez que la sauvegarde de cette installation. Consultez le [guide d'intégration](docs/integration.md) pour les sauvegardes de configuration des scripts d'intégration.

Dans un environnement MSIX où AppData est redirigé vers un autre emplacement, vous pouvez définir explicitement le dossier parent des sauvegardes de mise à jour avec `-UpdateBackupRoot <chemin absolu de l'emplacement réel>`. Un `install-<ID>` par installation y est créé. Une destination par installation qui chevauche un dépôt, le Codex home, le répertoire d'installation, la zone de travail ou les données de récupération est refusée. S'il reste un ancien hook PowerShell, le programme d'installation le place dans la Corbeille de Windows avec Prunlet et enregistre le résultat dans `retired-products.json` de la même sauvegarde de mise à jour.

## Configuration initiale

Sur macOS et Linux, la configuration est créée par la procédure d'installation de chaque système. Ce qui suit est la configuration initiale pour Windows. Si vous avez utilisé le programme d'installation Windows, elle est déjà initialisée. Manuellement, indiquez où stocker les données de récupération du registre. `init` n'écrase pas une configuration existante.

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
& $exe --config $config migrate --dry-run
& $exe --config $config migrate --apply
```

`backupDirectory` est une zone protégée pour les snapshots du registre et les anciennes données antérieures à la migration. Elle ne stocke ni les enregistrements ni le contenu des nouvelles suppressions de fichiers. Les enregistrements du registre sont stockés sous le `.registry-records-v1` dédié. `allowedRoots` de la configuration et l'ancien `--allowed-root` sont des entrées de compatibilité et ne servent pas de liste d'autorisation de ce qui peut être supprimé.

Un `init` manuel ne fait que créer la configuration. Avant d'utiliser le registre, vérifiez les cibles avec `migrate --dry-run` et exécutez `migrate --apply`. Sans migration, les opérations normales du registre s'arrêtent avec `migration_required` et ne recherchent pas automatiquement l'ancienne zone de fichiers. La suppression de fichiers ne dépend pas de l'état de migration du registre.

```json
{
  "schema": 1,
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery",
  "retentionDays": 7,
  "maxRecoveryBytes": 1073741824
}
```

## Suppression et restauration

### Sur Mac Apple Silicon

Utilisez les chemins absolus de l'exécutable et de la configuration indiqués dans l'[exemple de CLI macOS](docs/macos.md). Vérifiez les cibles avec `delete --dry-run -- <chemin absolu>`, puis retirez `--dry-run` pour l'exécuter. Les éléments `recycled` peuvent être restaurés depuis la Corbeille du Finder. En cas d'`ambiguous`, vérifiez le chemin d'origine et la Corbeille, et ne renvoyez pas automatiquement la même suppression.

Pour attendre la libération d'un `flock` coopératif, mettez en file d'attente avec `delete-queue -- <chemin absolu>` et vérifiez le résultat final avec `delete-queue-status <job-id>`. Annulez avec `delete-queue-cancel <job-id>` tant que l'état est `pending`.

### Sur Linux

Utilisez les chemins absolus de l'exécutable et de la configuration de l'[exemple de CLI Linux](docs/linux.md#初回インストール). Vérifiez les cibles avec `delete --dry-run -- <chemin absolu>`, puis retirez `--dry-run` pour l'exécuter. Les éléments situés sur le même point de montage que la Corbeille du dossier personnel peuvent être déplacés. Les éléments `recycled` peuvent être restaurés avec un gestionnaire de fichiers compatible avec la corbeille freedesktop. En cas d'`ambiguous`, vérifiez le chemin d'origine et la corbeille, et ne renvoyez pas automatiquement la même suppression.

### Sur Windows

Sur les hôtes Codex qui prennent en charge les demandes formelles d'autorisation de sandbox, et où la configuration effective exige et autorise une telle demande, exécutez les suppressions réelles avec la demande dès la première tentative. Un dry-run ne garantit pas l'autorisation d'accéder à la Corbeille. Si des droits d'administrateur Windows sont nécessaires, l'agent lance un CMD administrateur dans le périmètre autorisé, puis exécute et vérifie le résultat avec la même CLI et la même configuration installées. Si votre consentement UAC est nécessaire, il vous guide dans cette étape. Prunlet ne s'élève jamais automatiquement et ne réessaie pas par une autre voie les refus ou les résultats inconnus. Consultez le [guide d'intégration](docs/integration.md#sandboxとゴミ箱へのアクセス) pour plus de détails.

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --dry-run --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --paths-file C:\work\delete-paths.json
```

Remplacez l'exécutable et la configuration par les chemins absolus de votre installation. Dans Codex, indiquez `cmd.exe` et `login: false`. N'étendez pas dans le shell les chemins cibles contenant des espaces, de l'Unicode, de nombreux éléments ou des chemins longs ; transmettez-les comme chemins absolus dans un tableau JSON en UTF-8. `--paths-file` accepte de 1 à 256 entrées et jusqu'à 1 Mio.

```json
["C:\\work\\project\\unused.txt", "C:\\work\\project\\other.txt"]
```

Utilisez un `delete` normal pour les dossiers vides et `delete --recursive --paths-file <chemin JSON absolu>` pour les dossiers non vides. Les chemins simples peuvent aussi être transmis sous la forme `delete [--dry-run] [--recursive] -- <chemin absolu> [...]`. Les caractères génériques, les chemins réseau et les balises reparse inconnues ne sont pas pris en charge. Pour un lien, c'est le lien lui-même qui est supprimé, sans parcourir sa cible. Un fichier ordinaire portant le même nom qu'un nom réservé de Windows, comme `NUL` ou `NUL.txt`, est supprimé définitivement après vérification de son identité, sans autre confirmation. Il ne passe pas par la Corbeille. Les ancêtres, répertoires et liens portant un nom réservé ne relèvent pas de cette exception. Pour les noms ordinaires, la suppression définitive n'est tentée, après rapprochement de l'élément et du nom d'origine, que lorsque Windows indique que la cible est trop volumineuse pour la Corbeille, ou lorsque la Corbeille est indisponible et que le paramètre de suppression immédiate du lecteur cible a été confirmé.

Le résultat contient `dryRun`, `items` et `warnings`. Vérifiez `path`, `kind`, `status` et l'éventuel `error` de chaque élément. Les états sont `recycled`, `permanently_deleted`, `would_recycle`, `would_permanently_delete`, `already_absent`, `failed` et `ambiguous` ; aucun ID d'opération de fichier, backupPath, hash ni size n'est renvoyé. `permanently_deleted` signifie que le nom d'origine indiqué a été supprimé sans passer par la Corbeille ; cela ne signifie pas que d'autres liens physiques ou sauvegardes ont été effacés. `failed` et `ambiguous` ne sont pas considérés comme un succès.

Restaurez les éléments `recycled` depuis la Corbeille de Windows. Le nom d'origine d'un élément `permanently_deleted` ne peut pas être restauré depuis la Corbeille. Prunlet n'a ni commande ni outil MCP de restauration de fichiers. Si un élément existe déjà à l'emplacement de restauration de la Corbeille, vérifiez le conflit dans l'interface de Windows et ne l'écrasez pas.

Si un élément ne peut pas être déplacé parce qu'il est utilisé, que les autorisations sont insuffisantes ou qu'une limite de chemin est atteinte, vérifiez le résultat. En cas d'échec, `error` contient la cible et le code d'erreur et, si l'élément est utilisé, renvoie aussi le PID, le nom et le chemin de fichier des détenteurs observés. Dans une suppression définitive récursive, le `path` du résultat et le `Target` de `error` désignent le dossier indiqué. Un `Failure entry`, s'il est présent, donne le chemin absolu de l'entrée en échec, et le diagnostic des détenteurs porte aussi sur cette entrée. Consultez le [guide d'intégration](docs/integration.md#使用中のファイルと同時実行) pour le périmètre et les limites du diagnostic. Si le nom de la cible est remplacé pendant le traitement du Shell, un autre élément peut être placé dans la Corbeille. Prunlet vérifie l'élément déplacé et s'arrête avec `ambiguous` s'il ne correspond pas. En cas d'`ambiguous`, vérifiez la cible d'origine et la Corbeille de Windows ; la même suppression n'est pas renvoyée automatiquement. Pour un fichier ordinaire portant un nom réservé, un dry-run renvoie `would_permanently_delete` et ne le supprime pas réellement. Tout autre `would_recycle` résulte de la vérification préalable de l'entrée et ne permet pas de prévoir s'il deviendra `permanently_deleted` à l'exécution, ni si le déplacement réel réussira.

Les droits d'accès pendant le séjour dans la Corbeille de Windows, ainsi que l'héritage des autorisations depuis le parent de l'emplacement de restauration, suivent aussi le comportement de Windows. Les liens physiques partagent non seulement le contenu mais aussi les ACL ; les changements d'autorisations lors de la mise à la corbeille s'appliquent donc aussi aux alias restants.

### Supprimer des fichiers utilisés après attente

Pour attendre une cible utilisée sous Windows, placez-la dans la `delete-queue` explicite avant de lancer la suppression. Un `delete` normal renvoie toujours son résultat de façon synchrone.

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-status <job-id>
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-cancel <job-id>
```

Indiquez les dossiers non vides avec `delete-queue --recursive --paths-file <chemin JSON absolu>` et les chemins simples avec `delete-queue [--recursive] -- <chemin absolu> [...]`. La réponse de mise en file d'attente ne signifie pas que la suppression est terminée. Vérifiez l'état et le résultat final avec l'ID de tâche renvoyé. Dans MCP, indiquez `action: "enqueue"`, `"status"` ou `"cancel"` au `delete_files` existant. Consultez le [guide d'intégration](docs/integration.md#明示的な削除待機キュー) pour plus de détails.

Avant la suppression, la file fige l'identité de la cible, de son parent et, pour les cibles récursives, de ses enfants, et n'attend sans limite de temps que les violations de partage et de verrouillage. Si une identité change pendant l'attente, la tâche est annulée ; les échecs ou résultats inconnus survenus après le début de la suppression ne sont pas renvoyés. Jusqu'à 8 tâches par utilisateur et par session Windows (y compris celles conservées après leur achèvement). Une tâche ne peut être annulée que pendant l'attente, et le résultat final est conservé une heure. Les tâches n'existent que dans la mémoire d'un worker temporaire dédié et ne sont ni des enregistrements d'opérations sur les fichiers ni des ID de restauration. Si le résultat ne peut pas être confirmé parce qu'il a expiré ou que le système ou le worker s'est arrêté, vérifiez la cible d'origine et la Corbeille de Windows, et ne renvoyez pas automatiquement la même suppression.

## Suppression et restauration du registre

Les clés ou valeurs locales autorisées de HKCU, HKLM et HKU peuvent être sauvegardées puis supprimées dans une view 32 ou 64 bits indiquée explicitement. Donnez le chemin de la clé sous forme de chemin absolu, et transmettez-en exactement un après `--`. Sans `--value-name`, la cible est la clé ; avec, c'est le nom de valeur littéral. La valeur par défaut a un nom vide ; utilisez donc `--value-name=`, que PowerShell ne supprime pas comme argument vide. La suppression d'une valeur ne peut pas être combinée avec `--recursive`. Supprimer une clé avec des sous-clés nécessite `--recursive`.

Un deux-points dans un nom de clé peut être indiqué tel quel. Par exemple, la fin de `HKCU:\Software\Example\C:#Program Files#Fixture.exe` est un seul nom de clé. Les noms contenant `%5C` et autres sont aussi pris littéralement, sans décodage d'URL.

```text
prunlet --config <chemin absolu> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
prunlet --config <chemin absolu> registry-delete --view 64 --recursive -- HKCU:\Software\Example
prunlet --config <chemin absolu> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
prunlet --config <chemin absolu> registry-restore <operation-id>
```

Les données de sauvegarde et les enregistrements sont protégés par des autorisations accessibles uniquement à l'utilisateur actuel et à SYSTEM, et les enregistrements dont les autorisations ont été altérées sont conservés sans être restaurés ni nettoyés. L'enregistrement des données de la clé et des droits d'accès complets nécessite `SeSecurityPrivilege`. Si les autorisations sont insuffisantes ou que les transactions sont indisponibles, il s'arrête avant la suppression et ne s'élève jamais automatiquement. La restauration d'une valeur ne modifie pas les droits d'accès de la clé parente. Pour les cibles protégées sous Windows 64 bits, avec un processus 64 bits et la view 64, `--access-mode backupRestore` peut être indiqué explicitement pour chaque suppression, dry-run et restauration. Il nécessite `SeBackupPrivilege` et `SeRestorePrivilege` dans le jeton effectif actuel, et n'obtient pas l'accès en modifiant les ACL ou la propriété. La valeur par défaut est `normal`, sans bascule automatique. Consultez aussi les [conditions de choix et les limites](docs/integration.md#保護されたレジストリへの明示アクセス). Consultez [DESIGN.md](DESIGN.md#レジストリの削除と復元) pour le format de stockage et la conception des transactions.

La restauration se fait dans la view d'origine et n'écrase ni ne fusionne jamais les clés ou valeurs existantes (y compris une valeur par défaut vide). Si les droits de restauration d'Owner ou de SACL sont insuffisants, elle annule et conserve la sauvegarde. La racine elle-même, HKCR/HKCC, les chemins distants ou relatifs, les liens arbitraires du registre, les schemas inconnus, la metadata et les enregistrements de restauration invérifiables sont refusés. La class de la clé est aussi enregistrée, mais l'heure de la dernière écriture n'est pas restaurée, et les clés volatile sont restaurées comme clés non volatile. Une opération interrompue après le commit mais avant la finalisation de son enregistrement est conservée comme inconnue, et le nettoyage et la restauration automatiques sont refusés.

Les entrées sous l'alias `Software\Classes` de l'utilisateur effectif sont traitées après vérification de la destination. La suppression et la restauration nécessitent une autorisation d'écriture supplémentaire sur l'alias, et l'heure de la dernière écriture de l'alias peut changer. Un dry-run n'écrit rien. Classes lui-même et les autres liens ne sont pas des cibles. Consultez la [conception](DESIGN.md#レジストリの削除と復元) pour les chemins pris en charge et les conditions de sécurité.

Si l'erreur 6801 survient dans une view virtuelle issue de MSIX, vous pouvez utiliser une [session explicite sur Windows normal](docs/integration.md#通常windowsのレジストリを明示して操作する). Vous lancez une session à durée limitée sur le bureau normal et vous vous connectez depuis la CLI ou le MCP avec une configuration dédiée sélectionnée. Il n'y a ni bascule automatique depuis la view virtuelle ni élévation automatique, et les clés de la view virtuelle ne sont pas traitées comme les clés de même nom sur Windows normal.

Si la réponse de la session est perdue, conservez l'`operationId` signalé et vérifiez le résultat enregistré avec `prunlet --config <chemin absolu de la même configuration> registry-reconcile <operation-id>`. Ne renvoyez pas la même suppression et ne déduisez pas un résultat de commit inconnu de l'existence actuelle de la clé. Une restauration réussie consomme le snapshot ; le même ID d'opération ne peut donc pas être restauré plusieurs fois.

Un `--dry-run` du registre vérifie aussi la connexion à la transaction avec la même cible, les mêmes autorisations et la même récursivité que la suppression réelle, et échoue s'il ne peut pas se connecter. Il n'écrit ni ne supprime de données, et ne garantit pas qu'une suppression réelle ultérieure réussira.

## Conservation et nettoyage automatique des données de récupération

`retentionDays` (7 jours par défaut) et `maxRecoveryBytes` (1 Gio par défaut) ne s'appliquent qu'aux snapshots du registre. Windows conserve et nettoie la Corbeille de Windows, et Prunlet ne l'inclut ni dans la capacité, ni dans la durée de conservation, ni dans purge.

Si une ancienne configuration n'a pas de marqueur de migration de capacité, ou en a un inférieur à 1, l'installation latest met `maxRecoveryBytes` à 1 Gio une seule fois. Une capacité modifiée par l'utilisateur après la migration est conservée lors des mises à jour suivantes.

`operations` liste les ID d'opération du registre, et `purge <registry-operation-id> [--dry-run | --apply]` et `maintain [--dry-run | --apply] [--audit-records]` sont aussi réservés au registre. Sans option, ils se contentent d'inspecter. Avant une suppression, ainsi que lors de la maintenance explicite et planifiée, les enregistrements protégés sont inspectés et les conditions de conservation appliquées. Les enregistrements ambigus et les snapshots invérifiables sont conservés.

## Migration des anciennes données de récupération de fichiers

`migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]` nettoie les anciennes données de sauvegarde de fichiers et les enregistrements d'opérations, et déplace les anciens enregistrements du registre vers le namespace dédié. **La compatibilité de restauration des anciens fichiers prend fin.** Les anciennes zones de fichiers dont la propriété peut être confirmée sont envoyées telles quelles dans la Corbeille de Windows, sans décompresser le format, vérifier les hashes du contenu, copier ni regrouper. Les fichiers déjà dans la Corbeille restent gérés par Windows. Aucune conversion des anciennes données pour la restauration ni aucun fichier de référence des autorisations d'origine n'est créé.

Le programme d'installation exécute `migrate --apply --if-needed` après l'enregistrement et le retrait de l'ancien backend. Les anciennes zones centrales déjà évaluées ne sont pas réanalysées et, lors d'une mise à jour, il vérifie aussi les anciennes données possédées sur les lecteurs connectés ultérieurement. La suppression, le listage et la maintenance normaux des fichiers n'analysent pas les anciens répertoires d'opérations. Consultez [DESIGN.md](DESIGN.md#旧ファイル復元データの明示移行) pour la conception de la vérification de propriété et de la réanalyse.

La conservation du registre, les ACL complètes et la restauration sans écrasement sont maintenues. Les zones portant des traces du registre, les zones dont la propriété ne peut pas être confirmée et les zones hors ligne ou aux autorisations insuffisantes sont laissées avec un avertissement, et un nettoyage de fichiers inachevé ne suffit pas à arrêter les opérations normales du registre.

Un nettoyage de fichiers interrompu ou au résultat inconnu n'est pas renvoyé automatiquement et s'arrête à une gate vide fixe. Ce n'est qu'après avoir vérifié le dossier d'origine et la Corbeille de Windows que vous pouvez le réévaluer explicitement avec `migrate --apply --retry-legacy-discard`. Le programme d'installation n'indique jamais cette confirmation automatiquement. Si l'installation échoue après le début de la migration, les nouveaux exécutables, la configuration et les enregistrements sont conservés, sans retour à l'ancien binaire.

## MCP

`prunlet --config <chemin absolu> mcp` démarre un serveur stdio local. La sortie standard est réservée à JSON-RPC. Les versions 2025-11-25, 2025-06-18 et 2024-11-05 du protocole MCP sont prises en charge. La suppression synchrone avec `delete_files` fonctionne sous Windows, macOS et Linux ; la mise en file d'attente, la consultation et l'annulation fonctionnent sous Windows et macOS. Les autres outils du tableau sont propres à Windows.

| Outil | Arguments | Rôle |
| --- | --- | --- |
| `delete_files` | Synchrone : `paths`, `dryRun` et `recursive` facultatifs. File d'attente : `action: "enqueue"` et `paths`, `recursive` facultatif. Consultation et annulation : uniquement `action: "status"` / `"cancel"` et `jobId` | Suppression synchrone de fichiers et de dossiers, et mise en file d'attente, consultation et annulation. La mise en file d'attente ne prend pas en charge `dryRun` |
| `delete_registry` | `path` et `view` (`"32"`/`"64"`), `valueName`, `recursive`, `dryRun` et `accessMode` facultatifs | Supprime une clé ou une valeur après l'avoir conservée. Un `valueName` vide désigne la valeur par défaut. `accessMode` vaut `normal` ou `backupRestore` |
| `restore_registry` | `operationId`, `accessMode` facultatif | Restaure une opération du registre sans écrasement. L'accès protégé est aussi choisi explicitement lors de la restauration |
| `reconcile_registry` | `operationId` | Lit et vérifie le résultat enregistré après une déconnexion. Ne renvoie ni suppression ni restauration |
| `list_operations` | Aucun | Liste les ID d'opération du registre (la possibilité de restauration est vérifiée lors de la restauration) |

Le serveur annonce le rôle des outils de suppression dans `instructions`. Sous Windows, on utilise normalement la CLI, et le MCP peut servir lorsque, par exemple, l'exécutable ou la configuration installés ne peuvent pas être exprimés sans risque dans CMD. `purge` du registre est une opération explicite de la CLI.

## Intégration avec Codex

Consultez le [guide d'intégration](docs/integration.md) pour l'enregistrement MCP commun sous Windows, l'inspection des entrées de suppression et la désinscription. Consultez chaque procédure d'installation pour les exemples d'enregistrement MCP et les arguments de démarrage du hook sous macOS et Linux. [Installation sur macOS](docs/macos.md) · [Installation sur Linux](docs/linux.md)

Le hook refuse les suppressions directes qu'il reconnaît et renvoie comme motif la commande détectée et l'interprétation du shell. Lorsque le shell est inconnu, le jugement n'est qu'une hypothèse et non une suppression locale confirmée. Si des chaînes de recherche ou des scripts distants sont refusés, consultez le [périmètre d'inspection du hook](docs/integration.md#hookの検査範囲). La CLI indiquée par le hook sert à supprimer des cibles sur le système hôte autorisé. Il ne remplace pas automatiquement les suppressions ni les entrées. Les approbations et les stratégies de gestion de Codex restent en vigueur.

## Lorsque la vérification de l'emplacement de stockage s'arrête

Avec les applications MSIX, les nouveaux dossiers d'AppData peuvent être redirigés vers le LocalCache propre au paquet. La redirection des répertoires ordinaires est résolue vers l'emplacement réel, mais si un lien ancêtre ou l'emplacement réel et ses attributs ne peuvent pas être vérifiés, il s'arrête. Vérifiez le chemin et les attributs indiqués dans l'erreur et, sans désactiver la vérification, placez si nécessaire l'exécutable, la configuration et les données de récupération dans un répertoire dédié comme `%USERPROFILE%\.local\Prunlet`. Il est déconseillé d'utiliser le LocalCache du paquet Codex comme emplacement permanent des données de récupération.

## Lorsque les transactions du registre sont indisponibles

Si les transactions sont indisponibles pour la hive cible, par exemple avec `ERROR_RM_NOT_ACTIVE` (6801), la suppression n'est pas validée par commit ; les données d'origine sont conservées et il s'arrête. La disponibilité peut varier selon la hive, même sur le même PC. Ne basculez pas vers une suppression non transactionnelle et ne réparez pas le système sans en connaître la cause ; vérifiez l'erreur ainsi que la hive et la view ciblées.

## Documents de développement

Consultez [AGENTS.md](AGENTS.md) pour la compilation en développement et les règles de travail, [DESIGN.md](DESIGN.md) pour la structure et les choix de conception, et le [guide de vérification](docs/verification.md) pour l'exécution des tests E2E et leur périmètre.
