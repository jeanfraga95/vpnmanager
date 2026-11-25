# vpnmanager

Painel VPN + proxy CloudJF (WebSocket), BHTTP, TLS/SSL e SSH XHTTP.

## Instalação rápida

tar xzf vpnmanager-lite_tar.gz <br>
cd vpnmanager-lite<br>
./install.sh<br>
menuvpn<br>

## Interface do menu (25/11/2026)

O `menuvpn` segue o padrão visual do VTProxy/SSHPlus:

- caixas ASCII `+----+` com bordas azuis, barra de título azul cheia e
  `MENU INICIAL` centralizado;
- opções `[n]` com status `ON/OFF/PARADO`; desinstalar e sair em vermelho;
- o fundo do terminal permanece o padrão — a cor só é aplicada aos elementos
  do menu (`modules/theme.sh`);
- `CPU/RAM` é reescrito no mesmo lugar a cada 2s, sem `clear` e sem duplicar
  linhas; enquanto uma opção está sendo digitada, a atualização é suspensa;
- os status são derivados do `exit status` das funções
  (`slowdns_is_installed`, `badvpn_is_installed`, `bhttp_is_installed`,
  `auto_menu_is_enabled`, etc.), pois elas retornam `0` sem imprimir nada;
- a contagem `Online:` do painel inicial soma usuários SSH + Xray/VLESS.

### Usuários online no Xray

A opção **2) Usuários Online** mostra usuário, IP(s) e quantidade de sessões
do Xray. Para isso, `/usr/local/etc/xray/config.json` expõe a API local:

```json
{
  "api": {
    "tag": "api",
    "listen": "127.0.0.1:8099",
    "services": ["StatsService", "HandlerService", "LoggerService"]
  },
  "stats": {},
  "policy": {
    "levels": { "0": { "statsUserOnline": true } }
  }
}
```

Sem `policy.levels.0.statsUserOnline`, `statsgetallonlineusers` retorna `{}`
mesmo com conexões ativas. Consultas usadas pelo menu:

```
xray api statsgetallonlineusers --server=127.0.0.1:8099
xray api statsonline --server=127.0.0.1:8099 -email <usuario>
xray api statsonlineiplist --server=127.0.0.1:8099 -email <usuario>
```

O V2Ray não está instalado nesta VPS; se for instalado, basta expor a API
equivalente e estender `_xray_online_count` / `_xray_online_list` em
`modules/online_users.sh`.

Arquivos da UI: `menu.sh`, `modules/theme.sh`, `modules/online_users.sh`,
`modules/common.sh`.

Rollbacks no VPS: `/root/rollback_vpnmanager_ui_v5.sh`,
`/root/rollback_online_users_xray.sh`, `/root/rollback_xray_online.sh`,
`/root/rollback_xray_api.sh`.

## Estado atual — 24/11/2026 (stack limpa, sem nginx)

O proxy em produção é o binário **patched/híbrido**:

- `/etc/VPNManager/bin/proxy` — md5 `6321c4873f1b8f3bec756ab164b19271`
- serviço systemd: `vpnproxy-ws-8080`
- fonte: `src/proxycloudjf/main_http_new.c`
- restore de emergência no VPS: `/root/restore_rawfix_20261123.sh`
- backup do binário corrigido: `/root/proxy_rawfix_20261123.bak`

### Correções incluídas (após o commit `4953530`)

- **`raw_tunnel`**: `CONNECT`, SOCKS4/5 e TLS ClientHello não passam mais pelo
  filtro de banner SSH. Antes o `ClientHello`/payload SOCKS era descartado por
  não conter `SSH-`, o que quebrava `proxy` e `ssl_proxy`. Esses túneis também
  não recebem fragmentação anti-DPI.
- **Handshake híbrido (padrão)**: o `200` só é enviado depois que o app manda
  `npv-x` (header HTTP ou payload legado) ou o banner `SSH-`. Isso mantém o
  timing do hsproxy sem perder filtro de decoys, DPI, keepalive e timeout 24h.
  `--auto-200` volta ao modo antigo (responde `200` imediatamente).
- Produção 25/11/2026: WS 8080 substituído pelo `vpnproxy-unified-8080` (`101` → `200` imediato); XHTTP real em `11443` (loopback); fallback `19080` removido.
- **HCR na 80**: o sniff do BHTTP reconhece o cabeçalho HCR plain
  (`Operation 1-6` + `Version 0x01`, 62 bytes) e roteia internamente para
  `127.0.0.1:18082`. Validado: `HCR plain op=1` → `18082`.
- **`healthcheck.sh`** não religa mais `vpnproxy-hcr-tcp`/`quic` nem nginx;
  pelo contrário, força essas unidades paradas para manter as portas avulsas
  fechadas.
- **`npv-x` é opcional**: se aparecer, é descartado; se não aparecer, o banner
  `SSH-` também dispara o `200`.
- **Filtro completo de decoys**: `GET, POST, PUT, PATCH, PATH, ACL, UNLOCK,
  MKCOL, DELETE, PROPPATCH, POLL, SEARCH` (e outros), inclusive cabeçalhos
  parcelados ou sem linha final — nada disso chega ao sshd como
  `invalid protocol identifier`.
- **Sem queda por ociosidade**: timeout do proxy e do BHTTP (`connIdleTO`) em
  `24h`. **Não usar `--idle 0`** — BHTTP usa `--idle 24h`.
- **BHTTP/QUIC**: sniff fragmentado com `prefixConn`, `MaxIdleTimeout 300s` e
  `KeepAlivePeriod 30s`.
- **`ssl_proxy` corrigido**: `443` → xray `400`. TLS puro na `80` dá `EOF`
  porque a 80 é BHTTP (comportamento esperado). **nginx não faz parte da
  stack**: a 80 sozinha serve BHTTP, WebSocket, XHTTP e HCR.

### Portas em produção

| Porta | Serviço |
|---|---|
| 80/tcp + 80/udp | entrada pública unificada (`vpnproxy-unified`): BHTTP/HCR/WS/XHTTP/SSH |
| 8080/tcp + 8080/udp | entrada pública unificada (`vpnproxy-unified-8080`): BHTTP/HCR/WS/XHTTP/SSH |
| 19080 | removido; o fallback lógico do menu é `127.0.0.1:8080` (ver abaixo) |
| 18082 / 11443 | backends loopback de HCR e XHTTP |
| 443 | xray |
| 18082 | hcr-server (loopback) |
| 11443 | xhttpssh (loopback via drop-in systemd) |
| 2223 | sshd-bhttp (loopback) |
| 22 | sshd |

**Fechadas / não usadas:** `8443` (TCP e UDP), `8787`, `8788`, `9090`,
`9443`, `18083`. O HCR não tem porta pública: chega pela 80 via BHTTP e o
dispatcher interno encaminha para `127.0.0.1:18082`. O comando
`vpnmanager-stack` mostra o estado da stack; a stack publica atual deve ser
reaplicada pelos serviços `vpnproxy-unified` / `vpnproxy-unified-8080` (o
antigo `port80_stack.sh` é legado e não deve ser usado em produção).

### Opção 10 do menu (BHTTP)

A opção **10) BHTTP** abre portas com o mesmo binário unificado da 80/8080:
BHTTP, HCR, XHTTP, WebSocket, CONNECT/SOCKS e TLS na **mesma porta**.

- **Não pede mais porta de fallback.** O destino é escolhido em background e
  gravado em `/etc/VPNManager/conf/bhttp_fallback.conf`.
- Na primeira execução, reutiliza um `--fallback-target` já existente em
  serviços BHTTP/unificados; se não houver, usa `127.0.0.1:8080` e garante
  que `vpnproxy-unified-8080` esteja ativo.
- Esse valor é sempre reutilizado nas próximas portas abertas.
- Abrir `80` ou `8080` **nunca** chama o `port80_stack.sh` legado: essas
  portas usam `vpnproxy-unified.service` e `vpnproxy-unified-8080.service`.
- **`--silent-ws` em todas as portas**, inclusive a `80`. Cliente que abre a
  conexão e não envia dados recebe `101` imediato; BHTTP, HCR, XHTTP, WS com
  dados, CONNECT/SOCKS e decoys continuam no roteamento normal.

### Opção 9 do menu (`Abrir Porta`)

A opção 9 chama `proxy_menu` e apenas cria
`/etc/systemd/system/vpnproxy-<tipo>-<porta>.service` com
`ExecStart=<bin> --port <porta> --to <destino>`:

- subopção **1) WebSocket** → `/etc/VPNManager/bin/proxy` (**proxy novo patched**)
- subopção **2) TLS/SSL** → `/etc/VPNManager/bin/sslproxy`
- subopção **3) SSH XHTTP** → `/etc/VPNManager/bin/xhttpssh`

O WebSocket manual já responde `101` para cliente silencioso em ~50ms
(comportamento equivalente ao `--silent-ws`); as portas criadas aqui nunca
usam `--no-immediate-101`. TLS/SSL e XHTTP não têm esse conceito e ficam
inalterados.

Ela não configura o app nem o BHTTP automaticamente e recusa uma porta já
aberta/em uso (não dá para reabrir a 8080). Para a porta 80, use a opção 10
(BHTTP).

### Protecao SSH (24/11/2026)

Todos os caminhos (BHTTP, XHTTP, WebSocket e HCR) autenticam no sshd da
porta 22. Com `LoginGraceTime 0`, conexoes abandonadas pelos proxies ficavam
abertas para sempre, esgotavam `MaxStartups` e causavam o sintoma
`101 -> 200` sem banner SSH.

- `LoginGraceTime 60`, `MaxStartups 300:30:600`, `MaxSessions 100`.
- `modules/sshd_auth_guard.sh` roda a cada 2 min pelo healthcheck: remove
  somente conexoes **pre-auth** abandonadas (>70s) e filhos `[priv]` orfaos,
  nunca sessoes autenticadas; alerta se `startups >= 250`.
- `vpnmanager-stack` mostra a carga do sshd e a quantidade de pre-auth.
- Validado: conexao abandonada removida em 60s; `101 -> 200 -> SSH` voltou
  a funcionar no IP direto e no CDN.

### Comparacao com a VPS sshplus (24/11/2026)

A VPS sshplus (167.126.9.217) usa configuracoes **mais fracas** nos pontos
criticos: `LoginGraceTime 120`, `MaxStartups 10:30:100`, sem `MaxSessions`
e sem watchdog de pre-auth. Nao foi copiado nada que enfraquece o vpnmanager.

Alem disso, foi encontrado o **mesmo vazamento de conexoes pre-auth no sshd
interno do BHTTP (2223)**: 4 processos `[accepted]` presos por ate 107
minutos, com apenas 10 slots. O guard foi estendido para os DOIS listeners:

- `sshd 22` e `sshd 2223` com `LoginGraceTime 60`, `MaxStartups 300:30:600`,
  `MaxSessions 100`.
- `sshd_auth_guard.sh` limpa pre-auth em ambos e recarrega via SIGHUP sem
  derrubar sessoes autenticadas.
- Template de reinstallacao (`port80_stack.sh`) corrigido para nao reintroduzir
  `LoginGraceTime 0` no sshd do BHTTP.
- `vpnmanager-stack` mostra a carga dos dois listeners.
- Unico ajuste adotado da sshplus: `net.core.netdev_max_backlog=100000`
  (era 65536), para absorber rajadas de pacotes.

### Validação

- Payload real rotacionado: 54 blocos em `18091/18092/18093` → 0 problemas.
- Matriz de modos: `direct` e `ssl_direct` idênticos; `proxy` (CONNECT) e
  `ssl_proxy` funcionam somente no patched corrigido.
- Produção: `101` → silêncio → `POLL` → `npv-x` → `200` + banner, usuários reais
  autenticando, nenhum `invalid protocol identifier`.
- Porta 80 via BHTTP: `AUTENTICADO_PORTA_80`, vivo `700s`, `RC=0`
  (`/tmp/test80_final_result.txt`).
- Validação 24/11/2026: HCR via 80 respondeu cabeçalho de status e o log do
  fallback registrou `HCR plain op=1` → `127.0.0.1:18082`; HTTP/XHTTP e
  WebSocket pela 80 retornaram banner SSH; `101 → 200 → SSH` confirmado na
  8080 (local e CDN); portas `8443/8787/8788/9090/9443/18082/11443` fechadas
  externamente.

Detalhes do proxy: [`src/proxycloudjf/README.md`](src/proxycloudjf/README.md).

### Estabilidade sem watchdog destrutivo (25/11/2026)

A queda das portas **80/8080** foi rastreada até o cron
`*/2 * * * * /usr/local/bin/ramwatch.sh`: ao atingir 97% de RAM ele entrava em
modo "forçado" e reiniciava `ssh`, `sshd`, `squid`, `xray`, `x-ui` e os proxies.
Isso derrubava as sessões dos usuários mesmo com a stack systemd intacta.
O log mostrou `RAM=97% >= 90% (forçado)` às 12:04 UTC e o `vpnproxy-bhttp-80`
reiniciado às 12:12:17 UTC.

- `modules/ram_clean.sh` agora é **100% não destrutivo**: libera apenas page
  cache e registra alerta; nunca reinicia serviços nem mata proxies.
- `memwatch.sh` (legado, fora do repo) também passou a apenas alertar.
- O healthcheck continua supervisionando os serviços críticos, mas não há mais
  watchdog que derrube conexões autenticadas por causa de RAM.

### Correção do vazamento de memória do BHTTP (25/11/2026)

O `dlBuf` parecia estável em `6144KB`, mas `s.dlBuf = s.dlBuf[cut:]` reduzia
apenas `len` e mantinha o `cap` do array grande alocado durante speedtests.
Com isso o RSS ficava em ~1,2–1,3 GB enquanto o log reportava só ~47 MB de
`dlBuf_total`.

- Novo `compactDLBufLocked()` copia os bytes vivos para um array novo quando
  `cap-len >= 4MB`, chamado pelo reaper sob `s.mu`.
- `logRAM()` agora reporta também `dlBuf_cap`, para medir a memória realmente
  retida.
- Nenhuma regra de replay/ACK/janela foi alterada; testes Go passaram e o
  binário aarch64 foi reconstruído.

### Proxy unificado na porta 80 (25/11/2026)

O `fallback-proxy` (19080) foi eliminado. O binário
`bin/aarch64/vpnproxy-unified` (fonte em `src/vpnproxy/`) faz o sniff na própria
porta pública e roteia sem redial externo:

- **BHTTP** TCP/TLS/QUIC → motor `bhttpssh` inalterado → `127.0.0.1:2223`.
- **HCR plain** → `127.0.0.1:18082` (módulo loopback interno).
- **XHTTP** (`x-http-sid` / `x-session-id`) → `127.0.0.1:11443` (módulo loopback).
- **WebSocket CloudJF, CONNECT, SOCKS4/5, TLS/SNI e decoys** → dentro do próprio
  processo (`src/vpnproxy/internal/wsproxy/`), com `101` em 50ms e `--auto-200`.
- **Zero bytes iniciais** continua indo para BHTTP; SSH direto permanece atrás de
  CONNECT/SOCKS/WS (sem probe ativo, para não quebrar CGNAT/4G).

O mesmo número de porta atende TCP e UDP; o QUIC é separado por ALPN
(`bhttp-ssh`). O motor BHTTP não foi alterado: apenas o ponto de decisão
`pipeFallback` virou dispatcher interno e o sniff passou a ser incondicional em
TCP. O replay dos bytes parciais do sniff também foi corrigido (SOCKS4/5 antes
perdiam os bytes lidos antes do timeout).

Rollback: `/root/rollback_unified.sh`. Backup completo:
`/root/backup_unified_cutover_20261125_140620.tar.gz`.
A unit `vpnproxy-unified-8080.service` foi habilitada em 25/11/2026; as units
`vpnproxy-ws-8080`, `vpnproxy-bhttp-80` e `vpnproxy-fallback` estão inativas e
desabilitadas. O `healthcheck.sh` agora monitora apenas `vpnproxy-unified`,
`vpnproxy-unified-8080`, `vpnproxy-xhttp-11443`, `hcr-server`, `sshd-bhttp` e
`checkuser`, evitando restart-loop e conflito de bind.

Validação: `101 → 200 → banner SSH`, CONNECT e SOCKS5 idênticos ao baseline da
80 e 8080; XHTTP e HCR roteados corretamente; TLS 1.3 com ALPN `bhttp-ssh`; ~98
conexões reais na 80 com `WRITE->SSHD` no log; RSS ~55MB, 138 FDs, 6 threads;
portas `8443/8787/8788/9090/9443/18082/11443` fechadas externamente.

### `--silent-ws` na 8080 (25/11/2026)

O app CloudJF abre a conexão TCP e **espera o `101` antes de enviar qualquer payload**.
No WiFi o primeiro pacote chegava dentro do sniff de 200ms e a conexão virava
WebSocket; no 4G/CGNAT o pacote demorava e o sniff caía no motor BHTTP
(`sniff nil (timeout sem dados), assume BHTTP`), que não responde nada. O proxy C
enviava `101` em 50ms nesse caso.

- Nova flag `--silent-ws`, inicialmente usada **apenas** em
  `vpnproxy-unified-8080.service` (estendida para todas as portas abaixo).
- Com a flag o sniff cai de 200ms para 50ms. Zero bytes, frame incompleto ou
  qualquer prefixo não identificado vão para o `wsproxy`, que responde
  `HTTP/1.1 101 OK` em ~50ms; o payload seguinte recebe `200 OK` + banner SSH.
- Regra de roteamento: **BHTTP, HCR e XHTTP** continuam nos seus motores;
  **todo o resto** (WebSocket, CONNECT, SOCKS4/5, TLS bruto, decoys e payloads
  arbitrários) é tratado como WebSocket/SOCKS pelo dispatcher interno.
- Naquele momento a porta 80 **não** usava a flag: zero bytes ia para BHTTP.
- Tradeoff: na 8080, um cliente BHTTP que demore >50ms para enviar o primeiro
  frame receberá o 101 e não falará BHTTP nessa conexão. O app BHTTP normal envia
  imediatamente e segue no motor BHTTP; o app VPN no 4G envia nada e recebe o 101.
- Fontes geradas por `scripts/build_unified.py`, que reaplica
  `scripts/apply_silent_ws.py` e roda `gofmt` — rebuilds são reproduzíveis.
- Validação: 11/11 no teste silencioso + 13/13 no QA de cada porta.
- Rollback específico: `/root/rollback_silent_ws.sh`
  (backup `/root/backup_silent_ws_20261125_150120`).

### 101 completo no `--silent-ws` (25/11/2026, 15:19 UTC)

A primeira versão do `--silent-ws` enviava `HTTP/1.1 101 OK\r\n\r\n` cru. O app
reconhecia a status line (logava "101 OK") mas, em clientes WebSocket estritos,
rejeitava a resposta por não haver `Upgrade: websocket` / `Connection: Upgrade`
e abortava logo depois, ou expirava a leitura.

Agora o ramo `cfg.Silent` usa o mesmo formato do `send_ws_101("")` do proxy C:

```
HTTP/1.1 101 OK
Upgrade: websocket
Connection: Upgrade
Server: nginx
X-Request-Id: <hex>
```

O `200 OK` + banner SSH continua sendo enviado somente após o payload seguinte
do cliente. O `101` com `Sec-WebSocket-Key` (GET legítimo) permanece com
`101 Switching Protocols` + `Sec-WebSocket-Accept`.

- Build reproduzível: `scripts/build_unified.py` reaplica
  `scripts/apply_silent_ws.py` (com o `sendWS101("")` no ramo silent) e roda
  `gofmt`.
- Validação: 11/11 silent + 13/13 em cada porta; cliente externo recebeu o
  `101` completo em 14ms e o `200` + banner em seguida.
- Deploy naquele momento: só a unit da 8080 foi reiniciada. A 80 continuou com
  zero bytes → BHTTP até a atualização registrada mais abaixo.
- Rollback: `/root/rollback_ws101hdr.sh`
  (backup `/root/backup_ws101hdr_20261125_151859`).

### Caminho silent sem `200` extra (25/11/2026, 15:31 UTC)

O `proxyjf` (C) funciona bem no app porque, no caminho silencioso, ele faz apenas
três coisas: envia o `101` completo, consome o request inicial do cliente e entra
direto na ponte TCP — sem enviar um `200 OK` extra. Não foi aproveitada a
simplicidade dele de não filtrar decoys/múltiplos métodos: esse filtro continua
no `wsproxy` Go.

Agora o ramo `--silent-ws` segue exatamente esse fluxo (na época, só na 8080):

```
TCP sem payload -> 101 completo em ~50ms
payload seguinte (npv-x, decoy ou múltiplos métodos) -> ponte direta, sem 200
GET legítimo com Sec-WebSocket-Key -> 101 Switching Protocols + Accept + 200
```

O `200 OK` continua presente em todos os outros caminhos (GET-first, CONNECT,
SOCKS, XHTTP e BHTTP). Naquele momento a porta 80 não usava `--silent-ws`.

- Build reproduzível: `scripts/build_unified.py` reaplica
  `scripts/apply_silent_ws.py` e `scripts/apply_nomagic200.py`, roda `gofmt` e
  o binário é gerado com `CGO_ENABLED=1 /usr/local/go/bin/go build -o
  bin/aarch64/vpnproxy-unified .` (sem `-trimpath`/`-ldflags`).
- Hash do binário: `f38283eeab05410fdaa5cbfd0abd3b8e4bf9e3f75e17cc4d94384d5baec471ef`.
- Validação: 8/8 no QA específico do silent e 13/13 no QA completo em cada
  porta temporária (18098 sem a flag, 18099 com a flag) e em produção (80 e
  8080). O `ActiveEnterTimestamp` da unit da 80 não mudou no deploy.
- Deploy naquele momento: só `vpnproxy-unified-8080.service` foi reiniciado.
- Rollback: `/root/rollback_nomagic200.sh`
  (backup `/root/backup_nomagic200_20261125_153144`).

### `--silent-ws` em todas as portas (25/11/2026, 18:xx UTC)

A pedido, a flag passou a ser aplicada a **todas** as entradas unificadas
criadas pelo módulo BHTTP, inclusive a porta `80`:

- `vpnproxy-unified.service` (80) recebeu `--silent-ws`;
- `vpnproxy-unified-8080.service` já tinha a flag;
- toda porta nova criada pelo menu BHTTP recebe a flag automaticamente.

Comportamento mantido: BHTTP, HCR, XHTTP, WebSocket com payload, CONNECT/SOCKS,
TLS e filtros de decoys continuam no roteamento normal. A única mudança é o
cliente que abre TCP e **não envia nenhum byte**: antes na 80 caía no motor
BHTTP e não respondia; agora recebe o `101` completo em ~50ms.

O proxy manual (opção 9) permanece com `/etc/VPNManager/bin/proxy`: o WebSocket
já responde `101` para cliente silencioso por padrão e nenhuma unidade criada
por ali usa `--no-immediate-101`. TLS/SSL e XHTTP não são afetados.

A unit da 80 foi reiniciada para aplicar a flag (queda de alguns segundos nas
conexões da 80). Rollback específico: `/root/rollback_silent_all.sh`.

### Rollback temporário para o C e restauração do Go (25/11/2026)

Às 15:40 UTC a stack pré-Go foi restaurada (`/root/rollback_unified.sh`:
BHTTP 80 + fallback 19080 + `vpnproxy-ws-8080` com o binário C
`cd67643c…`). O app em dados móveis apresentou o mesmo sintoma após o `101`,
então às 15:59 UTC a stack Go foi restabelecida com o binário `f38283ee…` e
todas as validações passaram novamente (8/8 silent + 13/13 em cada porta).
As units Go estão enabled/active; as units antigas permanecem disabled.
