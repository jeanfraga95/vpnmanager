# vpnmanager

Painel VPN + proxy CloudJF (WebSocket), BHTTP, TLS/SSL e SSH XHTTP.

## Instalação rápida

tar xzf vpnmanager-lite_tar.gz <br>
cd vpnmanager-lite<br>
./install.sh<br>
menuvpn<br>

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
- Produção 24/11/2026: WS 8080 rodando com `--auto-200` (`101` → `200` imediato); XHTTP real em `11443` (loopback); fallback em `127.0.0.1:19080`.
- **HCR na 80**: o sniff do BHTTP reconhece o cabeçalho HCR plain
  (`Operation 1-6` + `Version 0x01`, 62 bytes) e encaminha ao fallback, que
  roteia para `127.0.0.1:18082`. Validado: `HCR plain op=1` → `18082`.
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
| 80/tcp + 80/udp | **única entrada pública**: BHTTP → fallback `19080` |
| 19080 | fallback interno (`127.0.0.1`) → `18082` HCR, `8080` WS, `11443` XHTTP |
| 8080/tcp | proxy CloudJF patched (`vpnproxy-ws-8080`, `--auto-200`) |
| 443 | xray |
| 18082 | hcr-server (loopback) |
| 11443 | xhttpssh (loopback via drop-in systemd) |
| 2223 | sshd-bhttp (loopback) |
| 22 | sshd |

**Fechadas / não usadas:** `8443` (TCP e UDP), `8787`, `8788`, `9090`,
`9443`, `18083`. O HCR não tem porta pública: chega pela 80 via BHTTP →
fallback → `127.0.0.1:18082`. O comando `vpnmanager-stack` mostra o estado da
stack; para reaplicar: `bash /etc/VPNManager/modules/port80_stack.sh`.

### Opção 9 do menu (`Abrir Porta`)

A opção 9 chama `proxy_menu` e apenas cria
`/etc/systemd/system/vpnproxy-<tipo>-<porta>.service` com
`ExecStart=<bin> --port <porta> --to <destino>`:

- subopção **1) WebSocket** → `/etc/VPNManager/bin/proxy` (**proxy novo patched**)
- subopção **2) TLS/SSL** → `/etc/VPNManager/bin/sslproxy`
- subopção **3) SSH XHTTP** → `/etc/VPNManager/bin/xhttpssh`

Ela não configura o app nem o BHTTP automaticamente e recusa uma porta já
aberta/em uso (não dá para reabrir a 8080). Para a porta 80, use a opção 10
(BHTTP).

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
