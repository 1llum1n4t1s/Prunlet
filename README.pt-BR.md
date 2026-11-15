[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | **Português (Brasil)**

# Prunlet — Anti “blocked by policy”

O Prunlet é uma ferramenta para Windows, Mac com Apple Silicon e Linux que concentra a exclusão de arquivos e pastas feita por agentes de IA em uma CLI e um servidor MCP dedicados, para que a limpeza pare menos por `blocked by policy`. Ele padroniza o uso de entregar ao Prunlet, desde o início, as exclusões permitidas.

Arquivos e pastas normalmente vão para a lixeira do sistema operacional. O Prunlet não guarda registros de operação de arquivos, IDs de operação nem snapshots de restauração; a restauração a partir da lixeira e sua retenção ficam a cargo do sistema operacional. Ele não acompanha nenhuma ferramenta de IA específica e é instalado como um aplicativo independente. Você pode registrar opcionalmente o servidor MCP, a CLI e o hook em cada ferramenta de IA; o hook inspeciona e nega exclusões diretas e indica o procedimento com a CLI. Publicado por Kagayoi.

Ele trata arquivos e pastas vazias, e exclui uma pasta inteira quando `--recursive` é informado explicitamente. Os destinos de links nunca são seguidos. Um link físico movido para a lixeira continua compartilhando o conteúdo com os aliases restantes. A exclusão permanente condicional e a [exclusão e restauração do registro](#exclusão-e-restauração-do-registro) são exclusivas do Windows.

## Uso contra `blocked by policy`

Em ambientes em que a limpeza costuma parar por comandos de exclusão gerados pela IA, como `Remove-Item` ou `rm`, entregue as exclusões permitidas à CLI do Prunlet desde o início. O Codex no Mac com Apple Silicon e no Linux usa a CLI e a configuração colocadas na instalação. [Instalação no macOS](docs/macos.md) · [Instalação no Linux](docs/linux.md)

No Windows, use nesta ordem:

1. Instale o Prunlet como aplicativo independente com o comando de [Instalação e atualizações](#instalação-e-atualizações) abaixo. Ele não mexe nos arquivos de configuração das ferramentas de IA.
2. Registre o comando de inicialização de [Registro em um host MCP](#registro-em-um-host-mcp) nas ferramentas de IA (hosts MCP) que você usa. Para chamar a CLI diretamente, escreva os caminhos absolutos da CLI e da configuração instaladas nas instruções da ferramenta de IA. Para registrar tudo no Codex de uma vez, use [Registro no Codex (opcional)](#registro-no-codex-opcional).
3. Peça o trabalho e a limpeza normalmente. A CLI é chamada diretamente pelo CMD (`shell: cmd.exe`, `login: false`) com os caminhos absolutos da CLI e da configuração instaladas. Não é preciso adicionar as mesmas instruções a cada repositório.

Para pedir uma limpeza explicitamente, diga por exemplo:

> Limpe desde o início com a CLI do Prunlet os arquivos temporários e as pastas de trabalho desnecessários criados desta vez.

Passe caminhos com espaços, Unicode, caminhos longos ou vários destinos como uma lista JSON em UTF-8 com `--paths-file`, e informe `--recursive` explicitamente para pastas não vazias. Consulte [Exclusão e restauração](#exclusão-e-restauração) para os comandos reais e como restaurar.

O hook é um auxílio que detecta e nega exclusões diretas e indica o procedimento com a CLI; ele não converte comandos automaticamente. Para evitar falhas e novas tentativas repetidas, o básico é usar a CLI desde a primeira tentativa por meio das instruções comuns. As permissões, aprovações e políticas de gerenciamento do host e do sistema operacional continuam valendo. Se a própria chamada ao Prunlet for negada, pare e não tente de novo por outro caminho. Consulte o [guia de integração](docs/integration.md) para o registro e o escopo da inspeção.

Os scripts PowerShell que o Codex envia a um Mac ou a outro lugar devem ser passados na forma explícita de PowerShell filho descrita no [guia de integração do hook](docs/integration.md#hookの検査範囲). A entrada do hook do Codex não inclui o shell de execução, então informar apenas `shell: "pwsh"` não permite distinguir exclusões dentro de um here-string.

## Instalação e atualizações

### Mac com Apple Silicon

Obtenha `prunlet-update-osx-arm64.zip` em [GitHub Releases](https://github.com/1llum1n4t1s/Prunlet/releases/latest). O `scripts/Install-Prunlet.sh` faz em uma única execução o download, a verificação do tamanho e do SHA-256, a verificação da assinatura e da notarização e uma nova instalação em uma pasta dedicada (consulte [Instalação no macOS](docs/macos.md)). Registre você mesmo o servidor MCP no Codex ou em outros hosts usando as linhas de configuração exibidas. Um servidor MCP registrado verifica atualizações ao iniciar e as adia para uma inicialização posterior enquanto estiver em uso.

### Linux

Obtenha `prunlet-linux-x64.tar.gz` ou `prunlet-linux-arm64.tar.gz` de acordo com sua CPU, junto com o arquivo `.sha256` de mesmo nome. [GitHub Releases](https://github.com/1llum1n4t1s/Prunlet/releases)

Consulte [Instalação no Linux](docs/linux.md#初回インストール) para verificar a soma de verificação, colocá-lo em um diretório dedicado e registrá-lo no Codex. Colocada como descrito, a versão oficial verifica atualizações quando o servidor MCP inicia e as adia para uma inicialização posterior enquanto estiver em uso.

### Windows

Windows x64 e ARM64 são suportados. O instalador abaixo baixa o pacote pré-compilado e assinado (`prunlet-update-<runtime>.zip`) da release mais recente do [repositório no GitHub](https://github.com/1llum1n4t1s/Prunlet) e o coloca no lugar. Só é necessário o PowerShell 7; Rust, as ferramentas de build do MSVC e o Windows SDK não são necessários.

| Destino | Opção do instalador |
| --- | --- |
| Windows x64 | `-Runtime win-x64` (padrão) |
| Windows ARM64 | `-Runtime win-arm64` |

No Windows ARM64, adicione `-Runtime` explicitamente ao comando abaixo. Para escolher a emulação x64, informe `-Runtime win-x64`.

```powershell
$installerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Prunlet\bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $installerDirectory | Out-Null
$installer = Join-Path $installerDirectory 'Install-Prunlet.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.ps1' -OutFile $installer
pwsh -NoProfile -File $installer
```

Se o limite sem autenticação da API do GitHub for atingido, adicione `-UseGitHubCliAuthentication` ao comando `pwsh` acima para usar uma GitHub CLI existente já conectada. Ele não instala o gh nem faz login por você. Esta opção é só para o instalador manual.

O instalador obtém a release estável mais recente pela API do GitHub e verifica se a tag aponta para um commit da branch padrão e se há exatamente um pacote anexado para o runtime de destino. Antes de colocar o ZIP baixado, ele verifica o tamanho e o SHA-256 retornados pelo GitHub, a lista de arquivos incluídos e cada hash, o commit e o runtime da release e a assinatura Authenticode dos executáveis (Valid, com o signatário esperado e carimbo de data/hora). São as mesmas verificações da atualização automática na inicialização. Se, logo após uma release, o pacote ainda não estiver assinado e anexado, ou se alguma verificação falhar, ele para sem gravar nada. Ele nunca compila a partir do código-fonte nem muda para um clone local.

O diretório de instalação padrão é `%USERPROFILE%\.local\Prunlet`. Ele coloca `bin\prunlet.exe`, os scripts de registro e as instruções comuns, e registra a origem, a branch, o commit e o hash do pacote em `source-info.json` no mesmo formato da atualização automática na inicialização. Por padrão, não grava nada nos arquivos ou pastas de configuração do Codex ou de outras ferramentas de IA, e registra apenas a tarefa de manutenção e a tarefa de atualização.

A atualização automática verifica os binários pré-compilados do GitHub Releases quando um host MCP inicia o servidor MCP do Prunlet e pela tarefa de atualização registrada pelo instalador (diariamente às 12:30 e 10 minutos após o logon, sem janela), e troca de versão quando o servidor MCP antigo e os processos de manutenção terminam. Graças à tarefa de atualização, PCs que não registram o servidor MCP também acompanham a versão mais recente. A atualização automática não recompila a partir do código-fonte. Executar os executáveis do produto não exige instalar o runtime do .NET nem o runtime do VC. Enquanto estiver em uso, nada é encerrado; ele verifica de novo na próxima inicialização do MCP. Quando o limite de solicitações normais sem autenticação da API do GitHub se esgota, ele continua a consulta automaticamente com a autenticação de uma GitHub CLI (`gh`) já configurada. Se a comunicação ou o download falhar, ele usa a versão atual desde que o estado anterior à atualização esteja preservado com segurança.

A atualização automática confia no editor da GitHub Release e verifica se o pacote baixado corresponde. Consulte o [design da atualização automática na inicialização](DESIGN.md#起動時自動更新) para saber como a verificação funciona e o que é confiável.

Os dados de atualização são gerenciados dentro de uma cota dedicada de 2 GiB. Áreas verificadas são reutilizadas, e dados desconhecidos e saídas interrompidas são preservados. Quando falta espaço, a atualização é adiada; os dados de recuperação do registro nunca são limpos por esse motivo.

#### Registro em um host MCP

Em hosts MCP como Toolport ou Claude Code, registre o script de inicialização instalado como servidor stdio. Informe o PowerShell 7 como `pwsh` (na versão da Microsoft Store, `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`) e não use o caminho absoluto de um PowerShell incluído em uma ferramenta de IA.

```text
command: pwsh
args:    -NoProfile -NonInteractive -File %USERPROFILE%\.local\Prunlet\bin\start-prunlet-mcp.ps1 -ExecutablePath %USERPROFILE%\.local\Prunlet\bin\prunlet.exe -ConfigPath %USERPROFILE%\.local\Prunlet\config.json
```

Substitua `%USERPROFILE%` pelo caminho absoluto real. `-CodexHome` não é necessário. Somente quando resta um registro anterior no Codex o script de inicialização o verifica, em modo somente leitura, e o protege.

#### Registro no Codex (opcional)

Apenas para registrar tudo no Codex de uma vez, adicione `-RegisterCodex -RegisterAgentInstructions` ao instalador acima. Isso registra o servidor MCP do Codex, o hook do executável nativo e instruções comuns que usam a CLI do Prunlet desde o início no CodexHome (`CODEX_HOME`, ou `%USERPROFILE%\.codex` se não estiver definido).

Depois de instalar ou atualizar com `-RegisterCodex`, abra `/hooks` no Codex, revise a definição do hook do Prunlet e confie nele. O instalador não altera as configurações de confiança; `requiresHookTrust` no resultado informa que essa etapa é necessária. Reinicie o Codex e confirme que o servidor MCP, as instruções comuns e o hook foram carregados. Consulte o [guia de integração](docs/integration.md#登録) para registrar e cancelar o registro.

O `-RegisterAgentInstructions` acima é uma opção explícita que registra o `PRUNLET.md` no Codex home, junto com uma referência dedicada e os caminhos absolutos do executável e da configuração instalados no `AGENTS.md` comum. Sem acrescentar nada a cada repositório, ela instrui o Codex a excluir com a CLI do Prunlet no CMD desde o início. Se o próprio caminho do executável ou da configuração não puder ser expresso com segurança no CMD, escolha antes da execução o servidor MCP, que usa o mesmo núcleo. Omita esta opção se não quiser alterar as instruções comuns.

A atualização automática só troca para candidatos cujos registros, incluindo as instruções comuns, não precisam de alteração. Se o `PRUNLET.md` registrado diferir do candidato apenas nas quebras de linha CRLF ou LF, o arquivo existente é mantido como está. Se um registro precisar ser sobrescrito, ou se for detectada uma alteração de registro feita pelo usuário, a atualização fica em espera. Ao atualizar manualmente com o instalador, informe o mesmo `-RegisterAgentInstructions` se as instruções comuns estiverem registradas. Consulte as [instruções comuns do agente](docs/integration.md#エージェント共通指示) para mais detalhes.

Para a primeira atualização a partir de uma versão antiga sem atualização automática, ou para uma atualização manual, baixe novamente o instalador mais recente e execute-o. O `config.json` existente é mantido, exceto por uma migração única da capacidade de retenção. Os dados de recuperação antigos são tratados por uma [migração explícita](#migração-dos-dados-antigos-de-recuperação-de-arquivos). Não é preciso registrar antecipadamente as pastas a excluir. O antigo `-AllowedRoot` é aceito como argumento de compatibilidade, mas não restringe o que pode ser excluído. Altere o diretório de instalação com `-InstallDirectory`. O caminho do seu clone nunca é registrado na configuração das ferramentas de IA.

Se uma instalação gerenciada existente estiver dentro de um repositório Git e a atualização parar na verificação normal do destino, você pode adicionar `-UpdateManagedInstallation -InstallDirectory <caminho absoluto da instalação existente>` ao instalador baixado novamente. Ele verifica se a configuração existente, as informações de instalação e os hashes dos produtos correspondem, e atualiza uma instalação que não tem arquivos rastreados pelo Git e que está excluída pelo Git ou corresponde ao registro atual da CLI comum. Uma instalação que não pode ser verificada é preservada e o instalador para. Consulte o [guia de integração](docs/integration.md#手動の設定準備) para as condições.

Para exigir correspondência com uma release verificada antes, adicione `-ExpectedCommitSha <SHA de 40 caracteres>`. Se o commit da release mais recente for diferente, ele para antes de instalar.

Os arquivos bootstrap baixados são temporários. Depois de verificar o resultado da instalação, limpe apenas esse diretório bootstrap. Não inclua na limpeza o diretório de instalação do aplicativo nem os dados de recuperação.

Se houver backups dos produtos anteriores à atualização ou da configuração do Codex anterior ao registro, `updateBackupDirectory` no resultado da instalação mostra onde estão. O padrão é `%LOCALAPPDATA%\Prunlet\Backups\install-<ID>`. Depois de confirmar o funcionamento e os registros e de que não é necessária recuperação, limpe apenas o backup dessa instalação. Consulte o [guia de integração](docs/integration.md) para os backups de configuração dos scripts de integração.

Em um ambiente MSIX em que o AppData é redirecionado para outro local, você pode definir explicitamente a pasta pai dos backups de atualização com `-UpdateBackupRoot <caminho absoluto do local real>`. Sob ela é criado um `install-<ID>` por instalação. Um destino por instalação que se sobreponha a um repositório, ao Codex home, ao diretório de instalação, à área de trabalho ou aos dados de recuperação é recusado. Se restar um hook antigo do PowerShell, o instalador o move para a Lixeira do Windows com o Prunlet e salva o resultado em `retired-products.json` no mesmo backup de atualização.

## Configuração inicial

No macOS e no Linux, a configuração é criada pelo procedimento de instalação de cada sistema. A seguir está a configuração inicial do Windows. Se você usou o instalador do Windows, ela já está inicializada. Manualmente, informe onde guardar os dados de recuperação do registro. `init` não sobrescreve uma configuração existente.

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
& $exe --config $config migrate --dry-run
& $exe --config $config migrate --apply
```

`backupDirectory` é uma área protegida para snapshots do registro e dados antigos anteriores à migração. Ela não guarda registros nem conteúdo das novas exclusões de arquivos. Os registros do registro do Windows são guardados no `.registry-records-v1` dedicado. `allowedRoots` da configuração e o antigo `--allowed-root` são entradas de compatibilidade e não são usados como lista de permissões do que pode ser excluído.

Um `init` manual apenas cria a configuração. Antes de usar o registro, verifique os destinos com `migrate --dry-run` e execute `migrate --apply`. Sem migração, as operações normais do registro param com `migration_required` e não procuram automaticamente a área de arquivos antiga. A exclusão de arquivos não depende do estado de migração do registro.

```json
{
  "schema": 1,
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery",
  "retentionDays": 7,
  "maxRecoveryBytes": 1073741824
}
```

## Exclusão e restauração

### No Mac com Apple Silicon

Use os caminhos absolutos do executável e da configuração mostrados no [exemplo de CLI do macOS](docs/macos.md). Verifique os destinos com `delete --dry-run -- <caminho absoluto>` e remova `--dry-run` para executar. Itens com `recycled` podem ser restaurados pela Lixeira do Finder. Em caso de `ambiguous`, verifique o caminho original e a Lixeira, e não reenvie a mesma exclusão automaticamente.

Para esperar a liberação de um `flock` cooperativo, coloque na fila com `delete-queue -- <caminho absoluto>` e verifique o resultado final com `delete-queue-status <job-id>`. Cancele com `delete-queue-cancel <job-id>` enquanto estiver em `pending`.

### No Linux

Use os caminhos absolutos do executável e da configuração do [exemplo de CLI do Linux](docs/linux.md#初回インストール). Verifique os destinos com `delete --dry-run -- <caminho absoluto>` e remova `--dry-run` para executar. Itens no mesmo ponto de montagem da Lixeira da pasta pessoal podem ser movidos. Itens com `recycled` podem ser restaurados com um gerenciador de arquivos compatível com a lixeira freedesktop. Em caso de `ambiguous`, verifique o caminho original e a lixeira, e não reenvie a mesma exclusão automaticamente.

### No Windows

Em hosts do Codex que suportam solicitações formais de permissão de sandbox, e em que a configuração efetiva exige e permite essa solicitação, execute as exclusões reais com a solicitação desde a primeira tentativa. Um dry-run não garante permissão para acessar a Lixeira. Se forem necessários direitos de administrador do Windows, o agente inicia um CMD de administrador dentro do escopo permitido e executa e verifica o resultado com a mesma CLI e configuração instaladas. Se for necessário o seu consentimento do UAC, ele orienta essa etapa. O próprio Prunlet nunca eleva privilégios automaticamente e não tenta de novo por outro caminho negações ou resultados desconhecidos. Consulte o [guia de integração](docs/integration.md#sandboxとゴミ箱へのアクセス) para mais detalhes.

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --dry-run --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --paths-file C:\work\delete-paths.json
```

Substitua o executável e a configuração pelos caminhos absolutos da sua instalação. No Codex, informe `cmd.exe` e `login: false`. Não expanda no shell caminhos de destino com espaços, Unicode, muitos itens ou caminhos longos; passe-os como caminhos absolutos em um array JSON em UTF-8. `--paths-file` aceita de 1 a 256 entradas e até 1 MiB.

```json
["C:\\work\\project\\unused.txt", "C:\\work\\project\\other.txt"]
```

Use um `delete` normal para pastas vazias e `delete --recursive --paths-file <caminho JSON absoluto>` para pastas com conteúdo. Caminhos simples também podem ser passados como `delete [--dry-run] [--recursive] -- <caminho absoluto> [...]`. Curingas, caminhos de rede e tags de reparse desconhecidas não são tratados. Em um link, o próprio link é excluído e seu destino não é percorrido. Um arquivo comum com o mesmo nome de um nome reservado do Windows, como `NUL` ou `NUL.txt`, é excluído permanentemente após a verificação de sua identidade, sem confirmação adicional. Ele não vai para a Lixeira. Ancestrais, diretórios e links com nomes reservados não fazem parte dessa exceção. Para nomes comuns, a exclusão permanente só é tentada, após comparar o item e o nome originais, quando o Windows informa que o destino é grande demais para a Lixeira, ou quando a Lixeira está indisponível e a configuração de exclusão imediata da unidade de destino foi confirmada.

O resultado tem `dryRun`, `items` e `warnings`. Verifique `path`, `kind`, `status` e o `error` opcional de cada item. Os status são `recycled`, `permanently_deleted`, `would_recycle`, `would_permanently_delete`, `already_absent`, `failed` e `ambiguous`; não são retornados ID de operação de arquivo, backupPath, hash nem size. `permanently_deleted` significa que o nome original informado foi excluído sem ser movido para a Lixeira; não significa que outros links físicos ou backups foram apagados. `failed` e `ambiguous` não são tratados como sucesso.

Restaure itens `recycled` pela Lixeira do Windows. O nome original de um item `permanently_deleted` não pode ser restaurado pela Lixeira. O Prunlet não tem comando nem ferramenta MCP de restauração de arquivos. Se já existir um item no local de restauração da Lixeira, verifique o conflito na interface do Windows e não o sobrescreva.

Se um item não puder ser movido por estar em uso, por falta de permissões ou por limites de caminho, verifique o resultado. Em caso de falha, `error` inclui o destino e o código de erro e, quando em uso, também retorna o PID, o nome e o caminho de arquivo dos detentores observados. Na exclusão permanente recursiva, o `path` do resultado e o `Target` em `error` se referem à pasta informada. Um `Failure entry`, se presente, indica o caminho absoluto da entrada que falhou, e o diagnóstico dos detentores também se refere a essa entrada. Consulte o [guia de integração](docs/integration.md#使用中のファイルと同時実行) para o escopo e os limites do diagnóstico. Se o nome do destino for substituído durante o processamento do Shell, outro item pode ser movido para a Lixeira. O Prunlet verifica o item movido e para com `ambiguous` se não corresponder. Em caso de `ambiguous`, verifique o destino original e a Lixeira do Windows; a mesma exclusão não é reenviada automaticamente. Para um arquivo comum com nome reservado, um dry-run retorna `would_permanently_delete` e não o exclui de fato. Qualquer outro `would_recycle` é o resultado da verificação prévia da entrada e não consegue prever se virará `permanently_deleted` na execução nem se a movimentação real terá sucesso.

Os direitos de acesso enquanto o item está na Lixeira do Windows e a herança de permissões da pasta pai do local de restauração também seguem o comportamento do Windows. Links físicos compartilham não só o conteúdo, mas também as ACLs, então as mudanças de permissão ao mover para a Lixeira também se aplicam aos aliases restantes.

### Excluir arquivos em uso após aguardar

Para aguardar um destino em uso no Windows, coloque-o na `delete-queue` explícita antes de iniciar a exclusão. Um `delete` normal continua retornando o resultado de forma síncrona.

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-status <job-id>
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-cancel <job-id>
```

Informe pastas não vazias com `delete-queue --recursive --paths-file <caminho JSON absoluto>` e caminhos simples com `delete-queue [--recursive] -- <caminho absoluto> [...]`. A resposta da colocação na fila não significa que a exclusão terminou. Verifique o status e o resultado final com o ID de tarefa retornado. No MCP, informe `action: "enqueue"`, `"status"` ou `"cancel"` ao `delete_files` existente. Consulte o [guia de integração](docs/integration.md#明示的な削除待機キュー) para mais detalhes.

Antes de excluir, a fila fixa a identidade do destino, da pasta pai e, em destinos recursivos, dos itens filhos, e aguarda sem limite de tempo apenas violações de compartilhamento e de bloqueio. Se uma identidade mudar durante a espera, a tarefa é cancelada; falhas ou resultados desconhecidos após o início da exclusão não são reenviados. Até 8 tarefas por usuário e sessão do Windows (incluindo as mantidas após a conclusão). Uma tarefa só pode ser cancelada enquanto aguarda, e o resultado final é mantido por uma hora. As tarefas existem apenas na memória de um worker temporário dedicado e não são registros de operação de arquivos nem IDs de restauração. Se o resultado não puder ser confirmado porque expirou ou porque o sistema operacional ou o worker terminou, verifique o destino original e a Lixeira do Windows, e não reenvie a mesma exclusão automaticamente.

## Exclusão e restauração do registro

Chaves ou valores locais permitidos de HKCU, HKLM e HKU podem ser copiados e excluídos em uma view de 32 ou 64 bits informada explicitamente. Informe o caminho da chave como caminho absoluto e passe exatamente um após `--`. Sem `--value-name` o destino é a chave; com ele, o nome de valor literal. O valor padrão tem nome vazio, então use `--value-name=`, que o PowerShell não descarta como argumento vazio. A exclusão de valores não pode ser combinada com `--recursive`. Excluir uma chave com subchaves exige `--recursive`.

Dois-pontos em um nome de chave podem ser informados como estão. Por exemplo, o final de `HKCU:\Software\Example\C:#Program Files#Fixture.exe` é um único nome de chave. Nomes que contêm `%5C` e afins também são tomados literalmente, sem decodificação de URL.

```text
prunlet --config <caminho absoluto> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
prunlet --config <caminho absoluto> registry-delete --view 64 --recursive -- HKCU:\Software\Example
prunlet --config <caminho absoluto> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
prunlet --config <caminho absoluto> registry-restore <operation-id>
```

Os dados de backup e os registros são protegidos com permissões que só o usuário atual e o SYSTEM podem acessar, e registros cujas permissões foram adulteradas são preservados sem serem restaurados nem limpos. Salvar os dados da chave e os direitos de acesso completos exige `SeSecurityPrivilege`. Quando as permissões são insuficientes ou as transações não estão disponíveis, ele para antes de excluir e nunca eleva privilégios automaticamente. Restaurar um valor não altera os direitos de acesso da chave pai. Para destinos protegidos no Windows de 64 bits, com um processo de 64 bits e a view 64, `--access-mode backupRestore` pode ser informado explicitamente em cada exclusão, dry-run e restauração. Ele exige `SeBackupPrivilege` e `SeRestorePrivilege` no token efetivo atual, e não obtém acesso alterando ACLs ou a propriedade. O padrão é `normal`, sem troca automática. Verifique também as [condições de escolha e os limites](docs/integration.md#保護されたレジストリへの明示アクセス). Consulte o [DESIGN.md](DESIGN.md#レジストリの削除と復元) para o formato de armazenamento e o design das transações.

A restauração é feita na view original e nunca sobrescreve nem mescla chaves ou valores existentes (incluindo um valor padrão vazio). Se faltarem direitos para restaurar Owner ou SACL, ela reverte e preserva o backup. A própria raiz, HKCR/HKCC, caminhos remotos ou relativos, links arbitrários do registro, schemas desconhecidos, metadata e registros de restauração que não podem ser verificados são recusados. A class da chave também é salva, mas o horário da última gravação não é restaurado, e chaves volatile são restauradas como não volatile. Uma operação interrompida após o commit, mas antes da finalização do seu registro, é preservada como desconhecida, e a limpeza e a restauração automáticas são recusadas.

Entradas sob o alias `Software\Classes` do usuário efetivo são tratadas após a verificação do destino. Exclusão e restauração exigem permissão adicional de gravação no alias, e o horário da última gravação do alias pode mudar. Um dry-run não grava. O próprio Classes e outros links não são destinos. Consulte o [design](DESIGN.md#レジストリの削除と復元) para os caminhos suportados e as condições de segurança.

Se ocorrer o erro 6801 em uma view virtual vinda do MSIX, você pode usar uma [sessão explícita no Windows normal](docs/integration.md#通常windowsのレジストリを明示して操作する). Você inicia uma sessão com tempo limitado na área de trabalho normal e se conecta pela CLI ou pelo MCP com uma configuração dedicada selecionada. Não há troca automática a partir da view virtual nem elevação automática, e as chaves da view virtual não são tratadas como as chaves de mesmo nome no Windows normal.

Se a resposta da sessão se perder, guarde o `operationId` informado e verifique o resultado salvo com `prunlet --config <caminho absoluto da mesma configuração> registry-reconcile <operation-id>`. Não reenvie a mesma exclusão nem deduza um resultado de commit desconhecido pela existência atual da chave. Uma restauração bem-sucedida consome o snapshot, então o mesmo ID de operação não pode ser restaurado repetidamente.

Um `--dry-run` do registro também verifica a conexão com a transação com o mesmo destino, as mesmas permissões e a mesma recursividade da exclusão real, e falha se não conseguir se conectar. Ele não grava nem exclui dados, e não garante que uma exclusão real posterior terá sucesso.

## Retenção e limpeza automática dos dados de recuperação

`retentionDays` (padrão de 7 dias) e `maxRecoveryBytes` (padrão de 1 GiB) se aplicam apenas aos snapshots do registro. O Windows retém e limpa a Lixeira do Windows, e o Prunlet não a inclui na capacidade, na retenção nem no purge.

Se uma configuração antiga não tiver o marcador de migração de capacidade, ou tiver um menor que 1, a instalação latest atualiza `maxRecoveryBytes` para 1 GiB uma única vez. Uma capacidade alterada pelo usuário após a migração é mantida nas atualizações seguintes.

`operations` lista os IDs de operação do registro, e `purge <registry-operation-id> [--dry-run | --apply]` e `maintain [--dry-run | --apply] [--audit-records]` também são exclusivos do registro. Sem opções, apenas inspecionam. Antes da exclusão, e na manutenção explícita e agendada, os registros protegidos são inspecionados e as condições de retenção aplicadas. Registros ambíguos e snapshots que não podem ser verificados são preservados.

## Migração dos dados antigos de recuperação de arquivos

`migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]` limpa os dados de backup de arquivos antigos e os registros de operação, e move os registros antigos do registro para o namespace dedicado. **A compatibilidade de restauração de arquivos antigos termina.** Áreas de arquivos antigas cuja propriedade pode ser confirmada são enviadas como estão para a Lixeira do Windows, sem descompactar o formato, verificar hashes de conteúdo, copiar ou agrupar. Arquivos que já estão na Lixeira continuam sob o gerenciamento do Windows. Nenhum dado antigo é convertido para restauração e nenhum arquivo de referência das permissões originais é criado.

O instalador executa `migrate --apply --if-needed` após o registro e após desativar o backend antigo. Áreas antigas centrais já avaliadas não são examinadas de novo e, na atualização, ele também verifica dados antigos próprios em unidades conectadas depois. A exclusão, a listagem e a manutenção normais de arquivos não examinam os diretórios de operações antigos. Consulte o [DESIGN.md](DESIGN.md#旧ファイル復元データの明示移行) para o design da verificação de propriedade e do novo exame.

A preservação do registro, as ACLs completas e a restauração sem sobrescrita são mantidas. Áreas com vestígios do registro, áreas cuja propriedade não pode ser confirmada e áreas offline ou com permissões insuficientes são deixadas com um aviso, e uma limpeza de arquivos incompleta por si só não interrompe as operações normais do registro.

Uma limpeza de arquivos interrompida ou com resultado desconhecido não é reenviada automaticamente e para em uma gate vazia fixa. Somente depois de verificar a pasta original e a Lixeira do Windows, reavalie explicitamente com `migrate --apply --retry-legacy-discard`. O instalador nunca informa essa confirmação automaticamente. Se a instalação falhar depois do início da migração, os novos executáveis, a configuração e os registros são mantidos, sem voltar ao binário antigo.

## MCP

`prunlet --config <caminho absoluto> mcp` inicia um servidor stdio local. A saída padrão é reservada ao JSON-RPC. As versões 2025-11-25, 2025-06-18 e 2024-11-05 do protocolo MCP são suportadas. A exclusão síncrona com `delete_files` funciona no Windows, no macOS e no Linux; a colocação na fila, a consulta e o cancelamento funcionam no Windows e no macOS. As demais ferramentas da tabela são exclusivas do Windows.

| Ferramenta | Argumentos | Finalidade |
| --- | --- | --- |
| `delete_files` | Síncrono: `paths`, `dryRun` e `recursive` opcionais. Fila: `action: "enqueue"` e `paths`, `recursive` opcional. Consulta e cancelamento: apenas `action: "status"` / `"cancel"` e `jobId` | Exclusão síncrona de arquivos e pastas, e colocação na fila, consulta e cancelamento. A colocação na fila não suporta `dryRun` |
| `delete_registry` | `path` e `view` (`"32"`/`"64"`), `valueName`, `recursive`, `dryRun` e `accessMode` opcionais | Exclui uma chave ou um valor após preservá-lo. Um `valueName` vazio é o valor padrão. `accessMode` é `normal` ou `backupRestore` |
| `restore_registry` | `operationId`, `accessMode` opcional | Restaura uma operação do registro sem sobrescrever. O acesso protegido também é escolhido explicitamente na restauração |
| `reconcile_registry` | `operationId` | Lê e verifica o resultado salvo após uma desconexão. Não reenvia exclusão nem restauração |
| `list_operations` | Nenhum | Lista os IDs de operação do registro (se podem ser restaurados é verificado na restauração) |

O servidor anuncia a finalidade das ferramentas de exclusão em `instructions`. No Windows normalmente se usa a CLI, e o MCP pode ser usado quando, por exemplo, o executável ou a configuração instalados não podem ser expressos com segurança no CMD. O `purge` do registro é uma operação explícita da CLI.

## Integração com o Codex

Consulte o [guia de integração](docs/integration.md) para o registro MCP comum no Windows, a inspeção da entrada de exclusão e como cancelar o registro. Consulte cada procedimento de instalação para os exemplos de registro MCP e os argumentos de inicialização do hook no macOS e no Linux. [Instalação no macOS](docs/macos.md) · [Instalação no Linux](docs/linux.md)

O hook nega as exclusões diretas que reconhece e retorna como motivo o comando detectado e a interpretação do shell. Quando o shell é desconhecido, o julgamento é apenas um candidato, e não uma exclusão local confirmada. Se cadeias de pesquisa ou scripts remotos forem negados, verifique o [escopo da inspeção do hook](docs/integration.md#hookの検査範囲). A CLI indicada pelo hook serve para excluir destinos no sistema operacional host permitido. Ele não substitui exclusões nem entradas automaticamente. As aprovações e as políticas de gerenciamento do Codex continuam valendo.

## Quando a verificação do local de armazenamento para

Em aplicativos MSIX, novas pastas no AppData podem ser redirecionadas para o LocalCache próprio do pacote. O redirecionamento de diretórios comuns é resolvido para o local real, mas se um link ancestral ou o local real e seus atributos não puderem ser verificados, ele para. Verifique o caminho e os atributos mostrados no erro e, sem desativar a verificação, coloque se necessário o executável, a configuração e os dados de recuperação em um diretório dedicado como `%USERPROFILE%\.local\Prunlet`. Não é recomendado usar o LocalCache do pacote do Codex como local permanente dos dados de recuperação.

## Quando as transações do registro não estão disponíveis

Se as transações não estiverem disponíveis para a hive de destino, por exemplo com `ERROR_RM_NOT_ACTIVE` (6801), a exclusão não é confirmada com commit; os dados originais são preservados e ele para. A disponibilidade pode variar por hive, mesmo no mesmo PC. Não troque para a exclusão não transacional nem repare o sistema operacional sem conhecer a causa; verifique o erro e a hive e a view de destino.

## Documentos de desenvolvimento

Consulte o [AGENTS.md](AGENTS.md) para builds de desenvolvimento e regras de trabalho, o [DESIGN.md](DESIGN.md) para a estrutura e as decisões de design, e o [guia de verificação](docs/verification.md) para como executar os testes E2E e o que eles cobrem.
