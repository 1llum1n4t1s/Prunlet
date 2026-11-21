[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md) | **Español** | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português (Brasil)](README.pt-BR.md)

# Prunlet — Anti “blocked by policy”

Prunlet es una herramienta para Windows, Mac con Apple Silicon y Linux que canaliza la eliminación de archivos y carpetas de los agentes de IA a través de una CLI y un servidor MCP dedicados, para que la limpieza se detenga menos por `blocked by policy`. Unifica el uso de entregar a Prunlet desde el principio las eliminaciones permitidas.

Normalmente los archivos y carpetas se mueven a la papelera del sistema operativo. Prunlet no guarda registros de operación de archivos, ID de operación ni snapshots de restauración; la restauración desde la papelera y su conservación quedan a cargo del sistema operativo. No viene incluido con ninguna herramienta de IA concreta y se instala como aplicación independiente. Puede registrar opcionalmente su servidor MCP, la CLI y el hook en cada herramienta de IA; el hook inspecciona y rechaza las eliminaciones directas e indica el procedimiento con la CLI. Lo publica Kagayoi.

Trata archivos y carpetas vacías, y elimina una carpeta completa cuando se indica `--recursive` explícitamente. Nunca sigue los destinos de los enlaces. Un vínculo físico movido a la papelera sigue compartiendo su contenido con los alias que permanecen. La eliminación permanente condicional y la [eliminación y restauración del registro](#eliminación-y-restauración-del-registro) son exclusivas de Windows.

## Uso contra `blocked by policy`

En entornos donde la limpieza suele detenerse por comandos de eliminación generados por la IA, como `Remove-Item` o `rm`, entregue las eliminaciones permitidas a la CLI de Prunlet desde el principio. Codex en Mac con Apple Silicon y en Linux usa la CLI y la configuración colocadas durante la instalación. [Instalación en macOS](docs/macos.md) · [Instalación en Linux](docs/linux.md)

En Windows, úselo en este orden:

1. Instale Prunlet como aplicación independiente con el comando de [Instalación y actualizaciones](#instalación-y-actualizaciones) más abajo. No toca los archivos de configuración de las herramientas de IA.
2. Registre el comando de inicio de [Registro en un host MCP](#registro-en-un-host-mcp) en las herramientas de IA (hosts MCP) que utilice. Para llamar a la CLI directamente, escriba las rutas absolutas de la CLI y la configuración instaladas en las instrucciones de la herramienta de IA. Para registrar todo en Codex de una vez, use [Registro en Codex (opcional)](#registro-en-codex-opcional).
3. Pida el trabajo y la limpieza como siempre. La CLI se llama directamente desde CMD (`shell: cmd.exe`, `login: false`) con las rutas absolutas de la CLI y la configuración instaladas. No es necesario añadir las mismas instrucciones a cada repositorio.

Para pedir una limpieza explícitamente, diga por ejemplo:

> Limpia con la CLI de Prunlet desde el principio los archivos temporales y las carpetas de trabajo innecesarios creados esta vez.

Pase las rutas con espacios, Unicode, rutas largas o varios destinos como una lista JSON en UTF-8 con `--paths-file`, e indique `--recursive` explícitamente para las carpetas no vacías. Consulte [Eliminación y restauración](#eliminación-y-restauración) para ver los comandos reales y cómo restaurar.

El hook es una ayuda que detecta y rechaza las eliminaciones directas e indica el procedimiento con la CLI; no convierte comandos automáticamente. Para evitar fallos y reintentos repetidos, lo básico es usar la CLI desde el primer intento mediante las instrucciones comunes. Los permisos, aprobaciones y políticas de administración del host y del sistema operativo siguen aplicándose. Si se rechaza la propia llamada a Prunlet, deténgase y no lo reintente por otra vía. Consulte la [guía de integración](docs/integration.md) para el registro y el alcance de la inspección.

Los scripts de PowerShell que Codex envía a un Mac u otro equipo deben pasarse con la forma explícita de PowerShell hijo descrita en la [guía de integración del hook](docs/integration.md#hookの検査範囲). La entrada del hook de Codex no incluye el shell de ejecución, por lo que indicar solo `shell: "pwsh"` no permite distinguir las eliminaciones dentro de un here-string.

## Instalación y actualizaciones

Las versiones publicadas antes de que la distribución pasara a los manifiestos firmados de `https://prunlet.kagayoi.com` (las versiones distribuidas mediante GitHub Releases) no pueden detectar versiones nuevas. Siguen funcionando con la versión actual sin romperse, pero no migran automáticamente, así que reinstale una vez: en Windows, vuelva a ejecutar el comando del instalador de [Windows](#windows); en Mac con Apple Silicon y Linux, siga [la reinstalación en macOS](docs/macos.md#旧版からの再導入) o [la reinstalación en Linux](docs/linux.md#旧版からの再導入).

### Mac con Apple Silicon

`scripts/Install-Prunlet.sh` obtiene el manifiesto firmado de `https://prunlet.kagayoi.com`, lo verifica con la clave pública integrada en el script y descarga `prunlet-update-osx-arm64.zip` desde la ubicación registrada en él. Realiza en una sola ejecución la descarga, las comprobaciones de tamaño y SHA-256, la verificación de firma y notarización, y una instalación nueva en una carpeta dedicada (consulte [Instalación en macOS](docs/macos.md)). Registre usted mismo el servidor MCP en Codex u otros hosts con las líneas de configuración que muestra. Un servidor MCP registrado busca actualizaciones al iniciarse y las pospone a un inicio posterior mientras está en uso.

### Linux

Obtenga `prunlet-linux-x64.tar.gz` o `prunlet-linux-arm64.tar.gz` según su CPU desde `https://prunlet.kagayoi.com`. Su ubicación y su SHA-256 están registrados en el manifiesto firmado; para una descarga rápida, también hay nombres fijos y archivos `.sha256` del mismo nombre en `https://prunlet.kagayoi.com/download/latest/`.

Consulte [Instalación en Linux](docs/linux.md#初回インストール) para comprobar el manifiesto firmado y la suma de verificación, colocarlo en un directorio dedicado y registrarlo en Codex. Colocada como se describe, la versión oficial busca actualizaciones al iniciarse el servidor MCP y las pospone a un inicio posterior mientras está en uso.

### Windows

Se admiten Windows x64 y ARM64. El instalador siguiente descarga el paquete precompilado y firmado (`prunlet-update-<runtime>.zip`) de la versión más reciente desde `https://prunlet.kagayoi.com` y lo coloca. Solo se necesita PowerShell 7; no hacen falta Rust, las herramientas de compilación de MSVC ni el Windows SDK.

| Destino | Opción del instalador |
| --- | --- |
| Windows x64 | `-Runtime win-x64` (predeterminado) |
| Windows ARM64 | `-Runtime win-arm64` |

En Windows ARM64, añada `-Runtime` explícitamente al comando siguiente. Para elegir la emulación x64, indique `-Runtime win-x64`.

```powershell
$installerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Prunlet\bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $installerDirectory | Out-Null
$installer = Join-Path $installerDirectory 'Install-Prunlet.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.ps1' -OutFile $installer
pwsh -NoProfile -File $installer
```

La instalación y las actualizaciones no requieren cuenta, inicio de sesión ni token de GitHub.

El instalador obtiene el manifiesto firmado de la versión más reciente (`latest/<runtime>.json`) desde `https://prunlet.kagayoi.com`, verifica su firma con la clave pública integrada en el instalador y comprueba que coinciden el producto, el repositorio, el runtime, el nombre del paquete y la ubicación de descarga. Descarga el ZIP desde esa ubicación fija sin seguir redirecciones y, antes de colocarlo, verifica la longitud y el SHA-256 registrados en el manifiesto, la lista de archivos incluidos y cada hash, el commit y el runtime, y la firma Authenticode de los ejecutables (Valid, con el firmante esperado y marca de tiempo). Son las mismas comprobaciones que la actualización automática al iniciar. Si no puede obtener el manifiesto o falla alguna comprobación, se detiene sin escribir nada. Nunca compila desde el código fuente ni cambia a un clon local.

El directorio de instalación predeterminado es `%USERPROFILE%\.local\Prunlet`. Coloca `bin\prunlet.exe`, los scripts de registro y las instrucciones comunes, y registra el origen, la rama, el commit y el hash del paquete en `source-info.json` con el mismo formato que la actualización automática al iniciar. De forma predeterminada no escribe en los archivos ni carpetas de configuración de Codex ni de otras herramientas de IA, y solo registra la tarea de mantenimiento y la tarea de actualización.

La actualización automática comprueba el manifiesto firmado de `https://prunlet.kagayoi.com` cuando un host MCP inicia el servidor MCP de Prunlet y desde la tarea de actualización que registra el instalador (cada día a las 12:30 y 10 minutos después de iniciar sesión, sin ventana), y cambia de versión cuando el servidor MCP anterior y los procesos de mantenimiento han terminado. Solo aplica una versión más reciente que la instalada. Gracias a la tarea de actualización, los equipos que no registran el servidor MCP también siguen la versión más reciente. La actualización automática no recompila desde el código fuente. Ejecutar los ejecutables del producto no requiere instalar el runtime de .NET ni el de VC. Mientras está en uso no finaliza nada; vuelve a comprobarlo en el siguiente inicio del MCP. Si falla la comunicación, la descarga o la verificación, no aplica nada y usa la versión actual siempre que el estado previo a la actualización se conserve de forma segura.

La actualización automática solo confía en la firma hecha con la clave de publicación dedicada. El workflow de publicación firma el manifiesto únicamente después de comprobar que el commit está en `main` y de compilar, firmar y verificar el paquete. Consulte el [diseño de la actualización automática al iniciar](DESIGN.md#起動時自動更新) para saber cómo funciona la verificación y en qué se confía.

Los datos de actualización se gestionan dentro de una cuota dedicada de 2 GiB. Las áreas verificadas se reutilizan, y los datos desconocidos y las salidas interrumpidas se conservan. Si falta espacio, la actualización se pospone; los datos de recuperación del registro nunca se limpian por ese motivo.

#### Registro en un host MCP

En hosts MCP como Toolport o Claude Code, registre el script de inicio instalado como servidor stdio. Indique PowerShell 7 como `pwsh` (en la versión de Microsoft Store, `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`) y no use la ruta absoluta de un PowerShell incluido con una herramienta de IA.

```text
command: pwsh
args:    -NoProfile -NonInteractive -File %USERPROFILE%\.local\Prunlet\bin\start-prunlet-mcp.ps1 -ExecutablePath %USERPROFILE%\.local\Prunlet\bin\prunlet.exe -ConfigPath %USERPROFILE%\.local\Prunlet\config.json
```

Sustituya `%USERPROFILE%` por la ruta absoluta real. `-CodexHome` no es necesario. Solo cuando queda un registro anterior en Codex, el script de inicio lo comprueba en modo de solo lectura y lo protege.

#### Registro en Codex (opcional)

Solo para registrar todo en Codex de una vez, añada `-RegisterCodex -RegisterAgentInstructions` al instalador anterior. Registra el servidor MCP de Codex, el hook del ejecutable nativo y las instrucciones comunes que usan la CLI de Prunlet desde el principio en CodexHome (`CODEX_HOME`, o `%USERPROFILE%\.codex` si no está definido).

Después de instalar o actualizar con `-RegisterCodex`, abra `/hooks` en Codex, revise la definición del hook de Prunlet y confíe en él. El instalador no cambia la configuración de confianza; `requiresHookTrust` en su resultado indica que este paso es necesario. Reinicie Codex y confirme que el servidor MCP, las instrucciones comunes y el hook se han cargado. Consulte la [guía de integración](docs/integration.md#登録) para registrar y anular el registro.

`-RegisterAgentInstructions` es una opción explícita que registra `PRUNLET.md` en el Codex home, junto con una referencia dedicada y las rutas absolutas del ejecutable y la configuración instalados en el `AGENTS.md` común. Sin añadir nada a cada repositorio, indica a Codex que elimine con la CLI de Prunlet en CMD desde el principio. Si la propia ruta del ejecutable o de la configuración no puede expresarse de forma segura en CMD, elija antes de ejecutar el servidor MCP, que usa el mismo núcleo. Omita esta opción si no quiere que se modifiquen las instrucciones comunes.

La actualización automática solo cambia a candidatos cuyos registros, incluidas las instrucciones comunes, no requieren cambios. Si el `PRUNLET.md` registrado difiere del candidato solo en los finales de línea CRLF frente a LF, se conserva el archivo existente tal cual. Si hubiera que sobrescribir un registro o se detecta un cambio del usuario en un registro, la actualización queda en espera. Al actualizar manualmente con el instalador, indique el mismo `-RegisterAgentInstructions` si las instrucciones comunes están registradas. Consulte las [instrucciones comunes del agente](docs/integration.md#エージェント共通指示) para más detalles.

Para la primera actualización desde una versión antigua sin actualización automática, o para una actualización manual, vuelva a descargar el instalador más reciente y ejecútelo. El `config.json` existente se conserva, salvo una migración única de la capacidad de retención. Los datos de recuperación antiguos se tratan con una [migración explícita](#migración-de-los-datos-antiguos-de-recuperación-de-archivos). No es necesario registrar de antemano las carpetas que se van a eliminar. El antiguo `-AllowedRoot` se acepta como argumento de compatibilidad, pero no restringe lo que se puede eliminar. Cambie el directorio de instalación con `-InstallDirectory`. La ruta de su clon nunca se registra en la configuración de las herramientas de IA.

Si una instalación administrada existente está dentro de un repositorio Git y la actualización se detiene en la comprobación normal del destino, puede añadir `-UpdateManagedInstallation -InstallDirectory <ruta absoluta de la instalación existente>` al instalador descargado de nuevo. Comprueba que coincidan la configuración existente, la información de instalación y los hashes del producto, y actualiza una instalación que no tiene archivos con seguimiento en Git y que está excluida por Git o coincide con el registro actual de la CLI común. Una instalación que no puede verificarse se conserva y el instalador se detiene. Consulte la [guía de integración](docs/integration.md#手動の設定準備) para ver las condiciones.

Para exigir que coincida con una release comprobada de antemano, añada `-ExpectedCommitSha <SHA de 40 caracteres>`. Si el commit de la release más reciente es distinto, se detiene antes de instalar.

Los archivos bootstrap descargados son temporales. Después de comprobar el resultado de la instalación, limpie solo ese directorio bootstrap. No incluya en la limpieza el directorio de instalación de la aplicación ni los datos de recuperación.

Si hay copias de seguridad de los productos previos a la actualización o de la configuración de Codex anterior al registro, `updateBackupDirectory` en el resultado de la instalación muestra dónde están. El valor predeterminado es `%LOCALAPPDATA%\Prunlet\Backups\install-<ID>`. Después de confirmar el funcionamiento y los registros y de que no se necesita recuperación, limpie solo la copia de seguridad de esa instalación. Consulte la [guía de integración](docs/integration.md) para las copias de seguridad de configuración de los scripts de integración.

En un entorno MSIX donde AppData se redirige a otra ubicación, puede establecer explícitamente la carpeta principal de las copias de seguridad de actualización con `-UpdateBackupRoot <ruta absoluta de la ubicación real>`. Debajo se crea un `install-<ID>` por instalación. Se rechaza un destino por instalación que se superponga con un repositorio, el Codex home, el directorio de instalación, el área de trabajo o los datos de recuperación. Si queda un hook antiguo de PowerShell, el instalador lo mueve a la Papelera de reciclaje de Windows con Prunlet y guarda el resultado en `retired-products.json` dentro de la misma copia de seguridad de actualización.

## Configuración inicial

En macOS y Linux, la configuración se crea con el procedimiento de instalación de cada sistema. Lo siguiente es la configuración inicial para Windows. Si usó el instalador de Windows, ya está inicializada. Manualmente, indique dónde guardar los datos de recuperación del registro. `init` no sobrescribe una configuración existente.

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
& $exe --config $config migrate --dry-run
& $exe --config $config migrate --apply
```

`backupDirectory` es un área protegida para los snapshots del registro y los datos antiguos anteriores a la migración. No guarda registros ni contenido de las nuevas eliminaciones de archivos. Los registros del registro de Windows se guardan bajo el `.registry-records-v1` dedicado. `allowedRoots` de la configuración y el antiguo `--allowed-root` son entradas de compatibilidad y no se usan como lista de permitidos de lo que se puede eliminar.

Un `init` manual solo crea la configuración. Antes de usar el registro, compruebe los destinos con `migrate --dry-run` y ejecute `migrate --apply`. Si no se ha migrado, las operaciones normales del registro se detienen con `migration_required` y no buscan automáticamente el área de archivos antigua. La eliminación de archivos no depende del estado de migración del registro.

```json
{
  "schema": 1,
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery",
  "retentionDays": 7,
  "maxRecoveryBytes": 1073741824
}
```

## Eliminación y restauración

### En Mac con Apple Silicon

Use las rutas absolutas del ejecutable y la configuración que aparecen en el [ejemplo de CLI de macOS](docs/macos.md). Compruebe los destinos con `delete --dry-run -- <ruta absoluta>` y quite `--dry-run` para ejecutarlo. Los elementos con `recycled` pueden restaurarse desde la Papelera del Finder. En caso de `ambiguous`, revise la ruta original y la Papelera, y no reenvíe la misma eliminación automáticamente.

Para esperar a que se libere un `flock` cooperativo, póngalo en cola con `delete-queue -- <ruta absoluta>` y compruebe el resultado final con `delete-queue-status <job-id>`. Cancele con `delete-queue-cancel <job-id>` mientras esté en `pending`.

### En Linux

Use las rutas absolutas del ejecutable y la configuración del [ejemplo de CLI de Linux](docs/linux.md#初回インストール). Compruebe los destinos con `delete --dry-run -- <ruta absoluta>` y quite `--dry-run` para ejecutarlo. Se pueden mover los elementos que estén en el mismo punto de montaje que la Papelera del directorio personal. Los elementos con `recycled` pueden restaurarse con un gestor de archivos compatible con la papelera de freedesktop. En caso de `ambiguous`, revise la ruta original y la papelera, y no reenvíe la misma eliminación automáticamente.

### En Windows

En hosts de Codex que admiten solicitudes formales de permisos de sandbox, y donde la configuración efectiva requiere y permite esa solicitud, ejecute las eliminaciones reales con la solicitud desde el primer intento. Un dry-run no garantiza permiso para acceder a la Papelera de reciclaje. Si se necesitan derechos de administrador de Windows, el agente inicia un CMD de administrador dentro del alcance permitido y ejecuta y comprueba el resultado con la misma CLI y configuración instaladas. Si se necesita su consentimiento de UAC, le guía en ese paso. Prunlet nunca se eleva automáticamente ni reintenta por otra vía los rechazos o los resultados desconocidos. Consulte la [guía de integración](docs/integration.md#sandboxとゴミ箱へのアクセス) para más detalles.

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --dry-run --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --paths-file C:\work\delete-paths.json
```

Sustituya el ejecutable y la configuración por las rutas absolutas de su instalación. En Codex, indique `cmd.exe` y `login: false`. No expanda en el shell las rutas de destino con espacios, Unicode, muchos elementos o rutas largas; páselas como rutas absolutas en un array JSON en UTF-8. `--paths-file` admite en Windows de 1 a 1024 entradas y hasta 4 MiB (macOS y Linux: 256 entradas y 1 MiB); MCP `delete_files` y `delete-queue` admiten hasta 256 rutas por solicitud. Las solicitudes que superan el límite se rechazan por completo sin cambiar nada; divida la lista.

```json
["C:\\work\\project\\unused.txt", "C:\\work\\project\\other.txt"]
```

Use un `delete` normal para las carpetas vacías y `delete --recursive --paths-file <ruta JSON absoluta>` para las carpetas con contenido. Las rutas simples también pueden pasarse como `delete [--dry-run] [--recursive] -- <ruta absoluta> [...]`. No se tratan comodines, rutas de red ni etiquetas de reparse desconocidas. En un enlace, se elimina el propio enlace y no se recorre su destino. Un archivo normal con el mismo nombre que un nombre reservado de Windows, como `NUL` o `NUL.txt`, se elimina permanentemente tras comprobar su identidad, sin más confirmación. No va a la Papelera de reciclaje. Los antecesores, directorios y enlaces con nombres reservados no forman parte de esta excepción. Para los nombres normales, solo se intenta la eliminación permanente, tras cotejar el elemento y el nombre originales, cuando Windows indica que el destino es demasiado grande para la Papelera de reciclaje, o cuando la Papelera no está disponible y se ha confirmado la configuración de eliminación inmediata de la unidad de destino.

El resultado tiene `dryRun`, `items` y `warnings`. Revise `path`, `kind`, `status` y el `error` opcional de cada elemento. Los estados son `recycled`, `permanently_deleted`, `would_recycle`, `would_permanently_delete`, `already_absent`, `failed` y `ambiguous`; no se devuelve ID de operación de archivo, backupPath, hash ni size. `permanently_deleted` significa que el nombre original indicado se eliminó sin moverlo a la Papelera de reciclaje; no significa que se borraran otros vínculos físicos ni copias de seguridad. `failed` y `ambiguous` no se consideran éxito.

Restaure los elementos `recycled` desde la Papelera de reciclaje de Windows. El nombre original de un elemento `permanently_deleted` no puede restaurarse desde la Papelera. Prunlet no tiene ningún comando ni herramienta MCP para restaurar archivos. Si ya existe un elemento en la ubicación de restauración de la Papelera, revise el conflicto en la interfaz de Windows y no lo sobrescriba.

Si un elemento no puede moverse porque está en uso, le faltan permisos o alcanza límites de ruta, revise el resultado. En caso de fallo, `error` incluye el destino y el código de error y, si está en uso, también devuelve el PID, el nombre y la ruta de archivo de los procesos que lo retienen observados. En la eliminación permanente recursiva, `path` del resultado y `Target` en `error` se refieren a la carpeta indicada. Un `Failure entry`, si existe, indica la ruta absoluta de la entrada que falló, y el diagnóstico de los procesos que lo retienen también se refiere a esa entrada. Consulte la [guía de integración](docs/integration.md#使用中のファイルと同時実行) para ver el alcance y los límites del diagnóstico. Si el nombre del destino se sustituye durante el procesamiento del Shell, puede moverse a la Papelera un elemento distinto. Prunlet comprueba el elemento movido y se detiene con `ambiguous` si no coincide. En caso de `ambiguous`, revise el destino original y la Papelera de reciclaje de Windows; la misma eliminación no se reenvía automáticamente. Para un archivo normal con un nombre reservado, un dry-run devuelve `would_permanently_delete` y no lo elimina realmente. Cualquier otro `would_recycle` es el resultado de la comprobación previa de la entrada y no puede predecir si pasará a `permanently_deleted` al ejecutarse ni si el movimiento real tendrá éxito.

Los derechos de acceso mientras está en la Papelera de reciclaje de Windows, y la herencia de permisos desde la carpeta principal de la ubicación de restauración, también siguen el comportamiento de Windows. Los vínculos físicos comparten no solo el contenido sino también las ACL, por lo que los cambios de permisos al moverlos a la Papelera también se aplican a los alias que permanecen.

### Eliminar archivos en uso tras esperar

Para esperar a un destino en uso en Windows, póngalo en la `delete-queue` explícita antes de iniciar la eliminación. Un `delete` normal sigue devolviendo su resultado de forma síncrona.

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-status <job-id>
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-cancel <job-id>
```

Indique las carpetas no vacías con `delete-queue --recursive --paths-file <ruta JSON absoluta>` y las rutas simples con `delete-queue [--recursive] -- <ruta absoluta> [...]`. La respuesta de puesta en cola no significa que la eliminación haya terminado. Compruebe el estado y el resultado final con el ID de trabajo devuelto. En MCP, indique `action: "enqueue"`, `"status"` o `"cancel"` en el `delete_files` existente. Consulte la [guía de integración](docs/integration.md#明示的な削除待機キュー) para más detalles.

Antes de eliminar, la cola fija la identidad del destino, de su carpeta principal y, en destinos recursivos, de sus elementos secundarios, y espera sin límite de tiempo solo ante infracciones de uso compartido y de bloqueo. Si una identidad cambia durante la espera, se cancela; los fallos o resultados desconocidos tras iniciarse la eliminación no se reenvían. Hasta 8 trabajos por usuario y sesión de Windows (incluidos los conservados tras completarse). Un trabajo solo puede cancelarse mientras espera, y el resultado final se conserva una hora. Los trabajos existen solo en la memoria de un worker temporal dedicado y no son registros de operación de archivos ni ID de restauración. Si no puede confirmarse el resultado porque caducó o porque terminó el sistema operativo o el worker, revise el destino original y la Papelera de reciclaje de Windows, y no reenvíe la misma eliminación automáticamente.

## Eliminación y restauración del registro

Las claves o valores locales permitidos de HKCU, HKLM y HKU pueden respaldarse y eliminarse en una view de 32 o 64 bits indicada explícitamente. Indique la ruta de la clave como ruta absoluta y pase exactamente una después de `--`. Sin `--value-name` el destino es la clave; con él, el nombre de valor literal. El valor predeterminado tiene un nombre vacío, así que use `--value-name=`, que PowerShell no descarta como argumento vacío. La eliminación de valores no puede combinarse con `--recursive`. Eliminar una clave con subclaves requiere `--recursive`.

Los dos puntos en un nombre de clave pueden indicarse tal cual. Por ejemplo, el final de `HKCU:\Software\Example\C:#Program Files#Fixture.exe` es un único nombre de clave. Los nombres que contienen `%5C` y similares también se toman literalmente, sin decodificación de URL.

```text
prunlet --config <ruta absoluta> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
prunlet --config <ruta absoluta> registry-delete --view 64 --recursive -- HKCU:\Software\Example
prunlet --config <ruta absoluta> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
prunlet --config <ruta absoluta> registry-restore <operation-id>
```

Los datos de respaldo y los registros se protegen con permisos a los que solo pueden acceder el usuario actual y SYSTEM, y los registros cuyos permisos se han manipulado se conservan sin restaurarse ni limpiarse. Guardar los datos de la clave y los derechos de acceso completos requiere `SeSecurityPrivilege`. Si faltan permisos o no hay transacciones disponibles, se detiene antes de eliminar y nunca se eleva automáticamente. Restaurar un valor no cambia los derechos de acceso de la clave principal. Para destinos protegidos en Windows de 64 bits, con un proceso de 64 bits y la view 64, puede indicarse `--access-mode backupRestore` explícitamente en cada eliminación, dry-run y restauración. Requiere `SeBackupPrivilege` y `SeRestorePrivilege` en el token efectivo actual, y no obtiene acceso cambiando ACL ni la propiedad. El valor predeterminado es `normal`, sin cambio automático. Revise también las [condiciones de selección y los límites](docs/integration.md#保護されたレジストリへの明示アクセス). Consulte [DESIGN.md](DESIGN.md#レジストリの削除と復元) para el formato de almacenamiento y el diseño de las transacciones.

La restauración se hace en la view original y nunca sobrescribe ni combina claves o valores existentes (incluido un valor predeterminado vacío). Si faltan derechos para restaurar Owner o SACL, revierte y conserva el respaldo. Se rechazan la propia raíz, HKCR/HKCC, las rutas remotas o relativas, los enlaces arbitrarios del registro, los schemas desconocidos, la metadata y los registros de restauración que no pueden verificarse. También se guarda la class de la clave, pero no se restaura la hora de la última escritura, y las claves volatile se restauran como no volatile. Una operación interrumpida tras el commit pero antes de que su registro se finalizara se conserva como desconocida, y se rechazan la limpieza y la restauración automáticas.

Las entradas bajo el alias `Software\Classes` del usuario efectivo se tratan tras verificar el destino. La eliminación y la restauración requieren permiso de escritura adicional en el alias, y la hora de la última escritura del alias puede cambiar. Un dry-run no escribe. El propio Classes y otros enlaces no son destinos. Consulte el [diseño](DESIGN.md#レジストリの削除と復元) para las rutas admitidas y las condiciones de seguridad.

Si aparece 6801 en una view virtual procedente de MSIX, puede usar una [sesión explícita en Windows normal](docs/integration.md#通常windowsのレジストリを明示して操作する). Usted inicia una sesión con tiempo limitado en el escritorio normal y se conecta desde la CLI o el MCP con una configuración dedicada seleccionada. No hay cambio automático desde la view virtual ni elevación automática, y las claves de la view virtual no se tratan como las claves del mismo nombre en Windows normal.

Si se pierde la respuesta de la sesión, conserve el `operationId` notificado y compruebe el resultado guardado con `prunlet --config <ruta absoluta de la misma configuración> registry-reconcile <operation-id>`. No reenvíe la misma eliminación ni deduzca un resultado de commit desconocido a partir de si la clave existe actualmente. Una restauración correcta consume el snapshot, por lo que no se puede restaurar repetidamente el mismo ID de operación.

Un `--dry-run` del registro también comprueba la conexión con la transacción con el mismo destino, permisos y recursividad que la eliminación real, y falla si no puede conectarse. No escribe ni elimina datos, y no garantiza que una eliminación real posterior tenga éxito.

## Conservación y limpieza automática de los datos de recuperación

`retentionDays` (7 días de forma predeterminada) y `maxRecoveryBytes` (1 GiB de forma predeterminada) se aplican solo a los snapshots del registro. Windows conserva y limpia la Papelera de reciclaje de Windows, y Prunlet no la incluye en la capacidad, la retención ni purge.

Si una configuración antigua no tiene marca de migración de capacidad, o tiene una inferior a 1, la instalación latest actualiza `maxRecoveryBytes` a 1 GiB una sola vez. Una capacidad modificada por el usuario después de la migración se conserva en las actualizaciones posteriores.

`operations` enumera los ID de operación del registro, y `purge <registry-operation-id> [--dry-run | --apply]` y `maintain [--dry-run | --apply] [--audit-records]` también son exclusivos del registro. Sin opciones solo inspeccionan. Antes de eliminar, y en el mantenimiento explícito y programado, se inspeccionan los registros protegidos y se aplican las condiciones de retención. Los registros ambiguos y los snapshots que no pueden verificarse se conservan.

## Migración de los datos antiguos de recuperación de archivos

`migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]` limpia los datos de respaldo de archivos antiguos y los registros de operación, y mueve los registros antiguos del registro al namespace dedicado. **La compatibilidad de restauración de archivos antiguos termina.** Las áreas de archivos antiguas cuya propiedad puede confirmarse se envían tal cual a la Papelera de reciclaje de Windows, sin desempaquetar el formato, comprobar hashes de contenido, copiar ni agrupar. Los archivos que ya están en la Papelera siguen bajo la gestión de Windows. No se convierte ningún dato antiguo para restaurarlo ni se crean archivos de referencia de los permisos originales.

El instalador ejecuta `migrate --apply --if-needed` después del registro y de retirar el backend antiguo. Las áreas antiguas centrales ya evaluadas no se vuelven a examinar y, al actualizar, también comprueba los datos antiguos propios en unidades conectadas más tarde. La eliminación, el listado y el mantenimiento normales de archivos no examinan los directorios de operaciones antiguos. Consulte [DESIGN.md](DESIGN.md#旧ファイル復元データの明示移行) para el diseño de la comprobación de propiedad y del nuevo examen.

Se mantienen la conservación del registro, las ACL completas y la restauración sin sobrescritura. Las áreas con rastros del registro, las áreas cuya propiedad no puede confirmarse y las áreas sin conexión o con permisos insuficientes se dejan con una advertencia, y una limpieza de archivos incompleta por sí sola no detiene las operaciones normales del registro.

Una limpieza de archivos interrumpida o con resultado desconocido no se reenvía automáticamente y se detiene en una gate vacía fija. Solo después de revisar la carpeta original y la Papelera de reciclaje de Windows, vuelva a evaluarla explícitamente con `migrate --apply --retry-legacy-discard`. El instalador nunca indica esta confirmación automáticamente. Si la instalación falla después de iniciarse la migración, se conservan los nuevos ejecutables, la configuración y los registros, y no se vuelve al binario antiguo.

## MCP

`prunlet --config <ruta absoluta> mcp` inicia un servidor stdio local. La salida estándar está reservada para JSON-RPC. Se admiten las versiones del protocolo MCP 2025-11-25, 2025-06-18 y 2024-11-05. La eliminación síncrona con `delete_files` funciona en Windows, macOS y Linux; la puesta en cola, la consulta y la cancelación funcionan en Windows y macOS. Las demás herramientas de la tabla son exclusivas de Windows.

| Herramienta | Argumentos | Uso |
| --- | --- | --- |
| `delete_files` | Síncrono: `paths`, `dryRun` y `recursive` opcionales. En cola: `action: "enqueue"` y `paths`, `recursive` opcional. Consulta y cancelación: solo `action: "status"` / `"cancel"` y `jobId` | Eliminación síncrona de archivos y carpetas, y puesta en cola, consulta y cancelación. La puesta en cola no admite `dryRun` |
| `delete_registry` | `path` y `view` (`"32"`/`"64"`), `valueName`, `recursive`, `dryRun` y `accessMode` opcionales | Elimina una clave o un valor tras conservarlo. Un `valueName` vacío es el valor predeterminado. `accessMode` es `normal` o `backupRestore` |
| `restore_registry` | `operationId`, `accessMode` opcional | Restaura una operación del registro sin sobrescribir. El acceso protegido también se elige explícitamente al restaurar |
| `reconcile_registry` | `operationId` | Lee y comprueba el resultado guardado tras una desconexión. No reenvía la eliminación ni la restauración |
| `list_operations` | Ninguno | Enumera los ID de operación del registro (si pueden restaurarse se verifica al restaurar) |

El servidor anuncia el propósito de las herramientas de eliminación en `instructions`. En Windows normalmente se usa la CLI, y el MCP puede usarse cuando, por ejemplo, el ejecutable o la configuración instalados no pueden expresarse de forma segura en CMD. `purge` del registro es una operación explícita de la CLI.

## Integración con Codex

Consulte la [guía de integración](docs/integration.md) para el registro MCP común en Windows, la inspección de la entrada de eliminación y cómo anular el registro. Consulte cada procedimiento de instalación para los ejemplos de registro MCP y los argumentos de inicio del hook en macOS y Linux. [Instalación en macOS](docs/macos.md) · [Instalación en Linux](docs/linux.md)

El hook rechaza las eliminaciones directas que reconoce y devuelve como motivo el comando detectado y la interpretación del shell. Cuando el shell es desconocido, la evaluación es una candidata y no una eliminación local confirmada. Si se rechazan cadenas de búsqueda o scripts remotos, revise el [alcance de la inspección del hook](docs/integration.md#hookの検査範囲). La CLI que indica el hook sirve para eliminar destinos en el sistema operativo host permitido. No sustituye eliminaciones ni entradas automáticamente. Las aprobaciones y las políticas de administración de Codex siguen vigentes.

## Cuando se detiene la comprobación de la ubicación de almacenamiento

En las aplicaciones MSIX, las carpetas nuevas de AppData pueden redirigirse al LocalCache propio del paquete. La redirección de directorios normales se resuelve a la ubicación real, pero si no puede verificarse un enlace antecesor o la ubicación real y sus atributos, se detiene. Revise la ruta y los atributos que muestra el error y, sin desactivar la verificación, coloque si es necesario el ejecutable, la configuración y los datos de recuperación en un directorio dedicado como `%USERPROFILE%\.local\Prunlet`. No se recomienda usar el LocalCache del paquete de Codex como ubicación permanente de los datos de recuperación.

## Cuando las transacciones del registro no están disponibles

Si las transacciones no están disponibles para la hive de destino, por ejemplo con `ERROR_RM_NOT_ACTIVE` (6801), la eliminación no se confirma con commit; los datos originales se conservan y se detiene. La disponibilidad puede variar según la hive incluso en el mismo equipo. No cambie a la eliminación no transaccional ni repare el sistema operativo sin conocer la causa; revise el error y la hive y la view de destino.

## Documentos de desarrollo

Consulte [AGENTS.md](AGENTS.md) para la compilación durante el desarrollo y las normas de trabajo, [DESIGN.md](DESIGN.md) para la estructura y las decisiones de diseño, y la [guía de verificación](docs/verification.md) para ejecutar las pruebas E2E y lo que cubren.
