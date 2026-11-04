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
- **Avisos dos meus veiculos**: botao **Avisos** no pe da lista de veiculos,
  no painel do dono. O rotulo mostra quantos avisos ainda nao foram lidos.
- **Slots de protecao**: botao **Slots**, ao lado de Avisos. Mostra os limites
  e, se o servidor permitir, o aluguel de slots extras.

## Slots de protecao

A janela **Slots** mostra, sempre, os dois patamares de limite lado a lado -
quanto um jogador comum pode proteger e quanto um apoiador pode - com o seu em
destaque. Assim da para ver o que se ganha virando apoiador sem precisar
perguntar a ninguem.

### Aluguel de slots

Opcional, e so funciona com o mod **Server Shop** no servidor. O jogador aluga
slots extras pagando com os pontos da loja; os slots alugados **somam** em cima
do limite da role, nao substituem.

- Dois pacotes, com preco e duracao configuraveis: 1 slot e 2 slots, por padrao
  200 e 300 pontos por 7 dias reais.
- Teto por jogador (`MaxRentedSlots`), somando todos os alugueis dele.
- **Renovar** cobra de novo e soma o tempo ao que ainda faltava, entao quem
  renova cedo nao perde dias.
- **Auto-renovar** por aluguel: no vencimento, se o saldo cobrir o preco, cobra
  e renova sozinho, inclusive com o jogador offline (o saldo da loja e por
  conta, nao por personagem). Se o saldo nao cobrir, o aluguel vence e ele
  recebe um aviso dizendo que faltou saldo. Nunca deixa o saldo negativo.

### O que acontece quando o aluguel vence

Esta e a parte que pode custar um veiculo, entao vale ler com atencao.

Se o aluguel vence e o jogador fica com mais veiculos protegidos do que o
limite, **nada e solto na hora**. Comeca uma carencia de `SlotGraceHours`
(24h de fabrica) em que:

1. Ele continua com todos os veiculos.
2. Recebe um aviso na caixa dizendo qual veiculo esta em risco e quanto tempo
   falta.
3. O botao **Slots** no painel fica vermelho, e a janela mostra o prazo.

Se ate o fim da carencia ele nao alugar de novo nem desproteger nada por conta
propria, o veiculo **protegido mais recentemente** perde a protecao, e ele
recebe outro aviso dizendo qual foi.

A carencia existe porque o vencimento quase sempre acontece com o jogador
offline: sem ela, ele perderia o carro sem nenhuma chance de reagir. Pondo
`SlotGraceHours` em 0 o comportamento vira "solta na hora".

Alugar, renovar ou desproteger um veiculo durante a carencia encerra a carencia
na hora, se isso trouxer o jogador de volta para dentro do limite.

### Sem o Server Shop

O mod **nao** declara dependencia do Server Shop. Se ele nao estiver no
servidor, ou se `EnableSlotRental` estiver desligado, o aluguel inteiro fica
desligado: a janela de slots continua funcionando e mostrando os limites, mas
sem os botoes de alugar. Nada mais no mod muda.

O saldo nunca e lido ou escrito direto no ModData da loja: usamos o modulo
`ServerShopBalanceCore` dela, para o arredondamento, o cache por personagem e a
estatistica de "total ganho" continuarem sendo responsabilidade de quem e dono
deles.

## Caixa de avisos

Todo aviso do mod era `setHaloNote`: texto que aparece na tela e morre. Se o
dono nao estivesse conectado no segundo exato do evento, o aviso nao existia em
lugar nenhum que ele pudesse ler depois - ou seja, ele nunca descobria o que
tinha acontecido com o carro enquanto estava fora. E dois eventos nao chegavam
a ele nem estando online, so ficavam no log do servidor.

A caixa de avisos guarda esses eventos por jogador e entrega no logon. O que
entra nela:

| Aviso | Existia antes? |
| --- | --- |
| Alguem tentou dirigir, abrir ou saquear um veiculo seu e foi bloqueado | So como halo, perdido se offline |
| Alguem estava sentado num veiculo seu sem permissao | So como halo, perdido se offline |
| Um veiculo seu foi destruido e a protecao foi liberada | So como halo, perdido se offline |
| Alguem transferiu um veiculo para voce, ou voce transferiu o seu | So como halo, perdido se offline |
| Um veiculo deixou de ser seu por tempo sem entrar (`ClaimTimeoutHours`) | Nao chegava ao dono, nunca |
| Staff liberou a protecao de um veiculo seu | Nao chegava ao dono, nunca |
| Aluguel de slot renovado, vencido ou sem saldo para renovar | Recurso novo |
| Um veiculo seu esta em risco pela carencia, ou perdeu a protecao | Recurso novo |

Detalhes do comportamento:

- **Repeticao vira contagem.** Eventos iguais do mesmo jogador no mesmo veiculo
  dentro de `NoticeGroupMinutes` formam **uma** entrada com contagem, em vez de
  dezenas de linhas iguais. A contagem e o que separa alguem que passou de
  alguem que ficou uma hora a trabalhar no carro. Antes, o cooldown do alerta
  descartava as repeticoes.
- **Guarda a chave de traducao, nao a frase.** O texto e montado na hora de
  desenhar, entao o aviso sai no idioma de quem le, nao no de quem estava
  logado quando o evento aconteceu.
- **Tempo relativo** ("ha 5 min", "ha 2 d"), igual a linha de localizacao do
  painel: sem duvida de fuso horario.
- **Marcados como lidos ao fechar** a janela, nao ao abrir, para o destaque dos
  novos continuar visivel durante a leitura.
- **Teto e validade**: `NoticeMaxPerPlayer` e `NoticeRetentionDays`. A lista
  vive em ModData global, que e carregado e gravado inteiro, por isso uma lista
  sem limite custaria tamanho de save e rede.

Cada jogador recebe **apenas a propria lista**, por comando direcionado; o
cliente nunca pede a chave `PVNotices`. Ver a ressalva em "O que o mod protege".

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

Sobre a caixa de avisos, vale saber o que e confiavel e o que nao e:

- **Tentativa bloqueada** nasce do cliente do infrator (comando
  `reportDenied`), entao um cliente modificado simplesmente nao reporta e o
  aviso nao aparece. O servidor reconfere a permissao antes de aceitar, por
  isso o aviso tambem nao pode ser **forjado** - mas pode ser **omitido**.
- **Intruso, expiracao, veiculo destruido e acao de staff** sao decididos no
  servidor e nao tem como ser escondidos.

Ou seja: "nenhum aviso" nao significa "ninguem mexeu".

Os avisos ficam no ModData global `PVNotices`. Um cliente modificado consegue
pedir qualquer ModData global, inclusive esse - o que ja valia para
`PVByVehicleSQLID`, que expoe dono e ultima coordenada conhecida de todos os
veiculos protegidos. O cliente normal recebe somente a propria lista.

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
| `NoticesEnabled` | bool | true | Liga a caixa de avisos do dono. |
| `NoticeRetentionDays` | int 1..365 | 30 | Quanto tempo um aviso fica guardado. |
| `NoticeMaxPerPlayer` | int 5..200 | 50 | Teto de avisos por jogador; o mais antigo sai primeiro. |
| `NoticeGroupMinutes` | int 1..120 | 10 | Janela em que repeticao do mesmo evento vira uma entrada com contagem. |
| `EnableSlotRental` | bool | false | Liga o aluguel de slots. Precisa do mod Server Shop. |
| `SlotRentDays` | int 1..30 | 7 | Duracao do aluguel, em dias reais. |
| `SlotRentPrice1` | int 0..1000000 | 200 | Pontos por um aluguel de 1 slot, e por renovacao dele. |
| `SlotRentPrice2` | int 0..1000000 | 300 | Pontos por um aluguel de 2 slots, e por renovacao dele. |
| `MaxRentedSlots` | int 1..20 | 4 | Teto de slots alugados por jogador. |
| `SlotGraceHours` | int 0..168 | 24 | Carencia apos o vencimento antes de soltar o claim. 0 = solta na hora. |

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
    UI/                        painel do dono, admin, permissoes, avisos, slots
  lua/server/
    PV_Server.lua              claim, unclaim, timeout, sweep, alertas
    PV_Notices.lua             caixa de avisos do dono
    PV_ClaimSlots.lua          aluguel de slots, vencimento e carencia
    PV_DocumentSystem.lua      documento/titulo no servidor
    PV_VehicleLogs.lua         escrita dos logs
    PV_AdminTools.lua          comandos de admin
    PV_RateLimit.lua           anti-spam de comandos
```

O DB vive em dois ModData globais: `PVByVehicleSQLID` (dados de cada veiculo) e
`PVByPlayerID` (veiculos e horarios de logon/logoff de cada jogador). A caixa
de avisos tem a chave propria `PVNotices`, e o aluguel de slots a sua,
`PVClaimSlots`; o cliente nunca pede nenhuma das duas. As duas tem chave
separada de proposito: `PV.getClaimCount` conta toda chave de
`PVByPlayerID[jogador]` que nao seja um dos dois campos de horario, entao
guardar aviso ou aluguel ali faria cada um contar como um veiculo protegido.

## Autoria

Todos os commits deste repositorio sao assinados (selo **Verified** no GitHub)
com a chave da conta Rafakes.
