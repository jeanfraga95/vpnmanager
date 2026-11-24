# vpnmanager

Painel VPN + proxy CloudJF (WebSocket), BHTTP, TLS/SSL e SSH XHTTP.

## Instalação rápida

tar xzf vpnmanager-lite_tar.gz <br>
cd vpnmanager-lite<br>
./install.sh<br>
menuvpn<br>

## Estado atual — 23/11/2026

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
- Produção 24/11/2026: WS 8080 rodando com `--auto-200` (`101` → `200` imediato); XHTTP real em `11443`, com fallback, `port80_stack.sh` e healthcheck atualizados.
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
- **`ssl_proxy` corrigido**: `9443` → nginx `200`, `443` → xray `400`,
  `11443` → XHTTP `200`. Na porta `80` TLS puro dá `EOF` porque a 80 é BHTTP
  (comportamento esperado).

### Portas em produção

| Porta | Serviço |
|---|---|
| 80 | BHTTP (TCP/UDP) → fallback `19080` |
| 19080 | fallback-proxy → `18082` (HCR), `8080` (WS), `10443` (XHTTP) |
| 8080 | proxy CloudJF patched (`vpnproxy-ws-8080`) |
| 443 | xray |
| 8443 | HCR |
| 9443 | nginx |
| 11443 | SSH XHTTP |
| 18082 | hcr-server |
| 22 / 2223 | sshd / sshd-bhttp |

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

Detalhes do proxy: [`src/proxycloudjf/README.md`](src/proxycloudjf/README.md).
