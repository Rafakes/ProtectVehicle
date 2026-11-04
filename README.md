# Protect Vehicle

Mod para **Project Zomboid Build 42**, de **Rafa** (GitHub: [Rafakes](https://github.com/Rafakes)).

Sistema de protecao de veiculos para servidores multiplayer: o jogador protege
("claim") um veiculo, passa a ser dono dele e decide quem pode dirigir, abrir,
saquear e desmontar. Inclui painel do dono, painel de admin, logs por veiculo,
rate limit de comandos e um sistema opcional de Documento/Titulo de veiculo.

- Versao: 1.0 (pasta `42.20`, `versionMin=42.20`)
- Autor: Rafa / Refugio Z
- Licenca: ver [LICENSE](LICENSE)

## Instalacao

Copie a pasta para `%USERPROFILE%\Zomboid\mods` ou assine o item na Steam Workshop.

Em servidor dedicado, o mod tem de estar na lista de mods do servidor; as opcoes
ficam nas paginas **Protect Vehicle** e **Protect Vehicle - Documents** do Sandbox.

## Como abrir os paineis

- **Meus Veiculos Protegidos**: clique com o botao direito no chao ou pela tecla
  definida em *Opcoes > Teclas > [Protect Vehicle]*. O atalho vem **sem tecla**
  de fabrica, para nao conflitar com o jogo nem com outro mod; a mesma tecla
  fecha a janela. Precisa ser definida uma vez por jogador.
- **Painel de admin**: botao direito no chao, apenas para admin e moderator.
- **Permissoes de um veiculo**: botao direito no veiculo, ou pelo painel do dono.

## Transferir um veiculo

No painel do dono, botao **Transferir**: pede o nome do jogador e confirma com o
nome do carro e do destinatario na tela. Regras, todas conferidas no servidor:

- so o dono atual ou staff pode transferir;
- o destinatario tem de estar **online** (o limite de apoiador depende da role
  dele, e um jogador inativo veria o claim expirar logo depois);
- o destinatario nao pode estar no limite de veiculos protegidos;
- as permissoes **nao** seguem o carro: flags publicas, AllowList, faccao e
  safehouse voltam a zero, e quem recebe decide de novo quem entra.

A troca vai para o log do veiculo e aparece no console.

## Como a permissao e resolvida

A ordem abaixo e a que `PV.checkPermission` e `PV.canPerformAction` seguem
(`media/lua/shared/PV_Shared.lua` e `PV_Permissions.lua`):

1. **Veiculo sem SQLID** (nunca protegido) -> liberado para todos.
2. **DB ainda nao sincronizado** no cliente -> nega por seguranca (falha fechada).
3. **SQLID orfao** (sem entrada no DB) -> tratado como abandonado, liberado.
4. **Staff** (admin, moderator, gm, observer, overseer) -> acesso total.
5. **Dono** -> acesso total.
6. **Faccao** do dono, se `AllowFaction` e a flag do veiculo estiverem ligadas.
   O lider entra pelo `getOwner()` do grupo, nao so pelos membros.
7. **Safehouse** do dono, mesma regra, com `AllowSafehouse`.
8. **AllowList**: nao da acesso total, apenas as flags marcadas por jogador.
9. Senao, vale a **flag publica** do veiculo.

As flags conhecidas estao em `PV.DEFAULT_FLAGS` (todas comecam `false`):
`AllowDrive`, `AllowPassenger`, `AllowContainersAccess`, `AllowSiphonFuel`,
`AllowUninstallParts`, `AllowTakeEngineParts`, `AllowOpeningDoors`,
`AllowOpeningTrunk`, `AllowInflateTires`, `AllowDeflateTires`, `AllowTow`,
`AllowScrapVehicle`, `AllowEnterRV`, `AllowViewMechanics`.

## O que o mod protege

Os bloqueios sao overrides das timed actions e dos menus do jogo, em
`media/lua/client/PV_Overrides.lua`: entrar no veiculo, trocar de assento, abrir
porta e porta-malas, mover item de container, sifonar combustivel, inflar e
desinflar pneus, desinstalar peca, tirar peca do motor, rebocar, desmanchar
(vanilla e VRO), abrir o painel de mecanica e entrar no interior de RV.

Tambem ha hooks para o reboque do PZK VanillaPlusCarPack e para o salvage do
Vehicle Repair Overhaul, quando esses mods estao presentes.

### Camadas de servidor

Como os bloqueios acontecem no cliente, um cliente modificado (ou um mod que
substitua as mesmas timed actions) pode passar por eles. Do lado do servidor:

- `attachTrailer` / `detachTrailer` e `enterRV` sao reconferidos no
  `OnClientCommand` e bloqueados ali.
- O sweep de cada minuto olha quem esta sentado nos veiculos protegidos e
  registra o ocupante sem permissao (`TheftAlertEnabled`).
- Tentativa bloqueada no cliente e reportada ao servidor, que **reconfere a
  permissao** antes de avisar o dono (`DeniedAttemptAlert`), por isso o aviso
  nao pode ser forjado.
- Veiculo protegido destruido tem a protecao liberada automaticamente, para nao
  prender um slot do dono (`AutoUnclaimDestroyed`).

## Logs

Escritos em `Zomboid/Lua/ProtectVehicle/<AAAA-MM-DD>/` no servidor:

- `global.log` - claims, unclaims, timeouts, acoes de admin, erros.
- `VEH_<sqlid>.log` - eventos de um veiculo (ligado por `EnablePerVehicleLogs`).

Eventos criticos (claim, unclaim, admin, intrusao) sempre aparecem no console.
Os demais so com `EnableVerboseConsoleLogs`. Atualizacao de coordenada tem a
chave propria `EnableCoordSyncLogs` e nunca vai para o console.

## Opcoes de Sandbox

### Pagina "Protect Vehicle"

| Opcao | Tipo | Padrao | Para que serve |
| --- | --- | --- | --- |
| `MaxVehicle` | int 1..999 | 3 | Maximo de veiculos protegidos por jogador. |
| `SupporterRoleNames` | string | `Apoiador` | Roles do servidor que usam o limite de apoiador (separados por virgula). |
| `MaxVehicleSupporter` | int 1..999 | 6 | Limite para quem tem uma dessas roles. |
| `ClaimTimeoutHours` | int 0..99999 | 240 | Horas desde o ultimo logout antes do claim expirar. 0 desliga. |
| `AllowFaction` | bool | true | Permite liberar o veiculo para a faccao do dono. |
| `AllowSafehouse` | bool | true | Permite liberar o veiculo para o safehouse do dono. |
| `TrunkParts` | string | `TrunkDoor;DoorRear;...` | Nomes de peca tratados como porta-malas/container. |
| `CommandCooldownMs` | int 100..10000 | 500 | Tempo minimo entre comandos do mesmo jogador. |
| `MaxRequestsPer10s` | int 1..100 | 10 | Limite de rajada por 10 segundos. |
| `AdminTeleportEnabled` | bool | true | Libera o teleporte de/para veiculo no painel de admin. |
| `EnablePerVehicleLogs` | bool | true | Gera `VEH_<sqlid>.log` por veiculo. |
| `RequireVehicleDocumentForClaim` | bool | false | Exige o item de documento para proteger. |
| `VehicleDocumentItemType` | string | `Base.VehicleDocument` | Tipo do item exigido. |
| `ConsumeVehicleDocumentOnClaim` | bool | false | Consome o documento ao proteger. |
| `ReturnDocumentOnUnclaim` | bool | true | Devolve o documento consumido no unclaim manual do dono. |
| `EnableCoordSyncLogs` | bool | false | Loga atualizacao de coordenada em arquivo. |
| `EnableVerboseConsoleLogs` | bool | false | Echo de eventos nao-criticos no console. |
| `WarnUnprotectedVehicle` | bool | true | Avisa ao entrar no assento do motorista de um veiculo sem protecao. |
| `TheftAlertEnabled` | bool | true | Detecta ocupante sem permissao no sweep do servidor e avisa. |
| `DeniedAttemptAlert` | bool | true | Avisa o dono quando uma tentativa e bloqueada. |
| `TheftAlertCooldownMinutes` | int 1..1440 | 10 | Intervalo minimo entre avisos do mesmo jogador no mesmo veiculo (vale para os dois alertas). |
| `AutoUnclaimDestroyed` | bool | true | Libera a protecao de veiculo queimado/destruido. |
| `AutoUnclaimConditionPercent` | int 0..100 | 0 | Libera tambem abaixo dessa condicao geral. 0 = desligado (recomendado). |

### Pagina "Protect Vehicle - Documents"

| Opcao | Tipo | Padrao | Para que serve |
| --- | --- | --- | --- |
| `RequireConversionDocument` | bool | false | Exige Titulo em branco no inventario para converter o veiculo. |
| `RequireKeyForConversion` | bool | false | Exige chave valida no veiculo para converter. |
| `AllowHotwiredForConversion` | bool | true | Com a regra de chave ativa, aceita veiculo com hotwire. |
| `MaxVehicleDocuments` | int 0..99 | 0 | Maximo de Titulos por jogador. 0 = ilimitado. |
| `DocumentValidityHours` | int 0..99999 | 0 | Validade do Titulo apos a conversao. 0 = nunca expira. |
| `MinVehicleConditionForConversion` | int 0..100 | 0 | Condicao geral minima para converter. 0 desliga. |
| `ConsumeDocumentOnSpawn` | bool | false | Consome o Titulo ao spawnar o veiculo. |
| `SpawnMaxDistance` | int 2..80 | 12 | Distancia maxima, em tiles, para spawnar a partir do Titulo. |
| `AllowShopTransfer` | bool | true | Permite listar e vender Titulos no Survivor Shop. |

## Estrutura do codigo

```
Contents/mods/ProtectVehicle/42.20/media/
  sandbox-options.txt          opcoes de sandbox
  scripts/                     itens (documento/titulo) e receitas
  textures/                    icones dos itens e marca d'agua
  lua/shared/
    PV_Shared.lua              permissao, helpers de veiculo, coordenada
    PV_Permissions.lua         flags conhecidas e resolucao por flag
    PV_DB.lua                  estrutura e reparo do ModData
    PV_TrunkParts.lua          mapeamento de porta-malas de mods
    Translate/EN|PT|PTBR/      textos
  lua/client/
    PV_Client.lua              comandos do servidor, menu de contexto, sync
    PV_Overrides.lua           todos os bloqueios de acao do jogo
    PV_ClaimAction.lua         timed action de proteger
    PV_UnclaimAction.lua       timed action de desproteger
    PV_ISInventoryTransferAction.lua  container de veiculo
    PV_DocumentSystem.lua      documento/titulo no cliente
    UI/                        painel do dono, painel de admin, permissoes
  lua/server/
    PV_Server.lua              claim, unclaim, timeout, sweep, alertas
    PV_DocumentSystem.lua      documento/titulo no servidor
    PV_VehicleLogs.lua         escrita dos logs
    PV_AdminTools.lua          comandos de admin
    PV_RateLimit.lua           anti-spam de comandos
```

O DB vive em dois ModData globais: `PVByVehicleSQLID` (dados de cada veiculo) e
`PVByPlayerID` (veiculos e horarios de logon/logoff de cada jogador).

## Autoria

Todos os commits deste repositorio sao assinados (selo **Verified** no GitHub)
com a chave da conta Rafakes.
