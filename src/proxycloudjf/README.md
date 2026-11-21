# Proxy CloudJF (porta 8080)

Proxy WebSocket usado pelo app CloudJF, com melhorias de DPI bypass e suporte a
SOCKS4/5 e HTTP CONNECT **no mesmo portão**.

## Compatibilidade

O fluxo original continua sendo o padrão:

1. app envia `GET /cloudjf2/ HTTP/1.1` com `Upgrade: websocket`
2. proxy responde `101`
3. app envia `npv-x` (ou `SSH-`)
4. proxy responde `200` e conecta ao SSH local (`127.0.0.1:22`)

Nada precisa mudar no app. Os recursos novos são ativados por detecção de
protocolo ou por flags opcionais.

## Recursos incluídos

- **WebSocket real**: valida `Upgrade: websocket` e responde
  `Sec-WebSocket-Accept` correto (calculado com SHA-1 do `Sec-WebSocket-Key`).
- **DPI bypass**: fragmenta os primeiros bytes em chunks pequenos com delay,
  tanto no sentido cliente→servidor quanto servidor→cliente.
- **SOCKS5** (`0x05`): métodos `0x00` e `0x02` (user/pass), IPv4, domínio e IPv6.
- **SOCKS4 / SOCKS4a** (`0x04`): com USERID e resolução de domínio.
- **HTTP CONNECT**: túnel padrão com `200 Connection Established`.
- **Decoy anti-sondagem**: requisições HTTP sem `Upgrade: websocket` recebem
  uma página nginx plausível em vez de `101`.
- **TLS ClientHello / SNI**: detecta `0x16 0x03`, extrai o SNI e encaminha ao
  destino configurado; SNI não permitido recebe o decoy.
- **Token opcional**: desligado por padrão. Quando ativo, aceita
  `X-Auth-Token`, `Authorization: Bearer`, `?token=` (WS/HTTP) e USERID (SOCKS).
- **TCP keepalive**: 60s idle / 30s interval / 3 retries (não injeta dados).
- **101 imediato para o app**: se o cliente silenciar por 50ms no aceite, o
  proxy envia o `101 OK` exato do original e passa a esperar o magic. Isso é
  necessário porque o app CloudJF espera o 101 antes de enviar qualquer dado.
  Se o cliente falar primeiro (SOCKS, probe, WS real), o protocolo é detectado
  normalmente e o 101 não é enviado antecipadamente.
- **Timeout ocioso**: 10s esperando o magic, igual ao proxy original.

## Flags

```
--port N                 porta de escuta (padrão 80)
--to N | --to-port N     destino SSH (padrão 22)
--response TEXTO         texto da resposta legada (padrão OK)
--no-dpi                 desliga fragmentação anti-DPI
--legacy-101             resposta 101 original exata
--no-immediate-101       não envia 101 no aceite (exige GET WebSocket)
--socks-force-local      ignora destino SOCKS/CONNECT e usa 127.0.0.1:<to>
--no-keepalive           desliga TCP keepalive
--tls-target HOST:PORT   destino do ClientHello (padrão 127.0.0.1:443)
--sni-allow HOST         só encaminha TLS com esse SNI (senão decoy)
--token TEXTO            exige token
--dpi-bytes N            bytes iniciais fragmentados (padrão 48)
--dpi-chunk N            tamanho de cada chunk (padrão 8)
--dpi-delay MS           delay entre chunks (padrão 12)
```

## Rollback rápido (sem trocar binário)

- `--legacy-101` — volta à resposta `101 OK` exata
- `--no-dpi` — desliga a fragmentação
- `--no-keepalive` — desliga keepalive
- `--no-immediate-101` — volta ao handshake WS estrito (espera o GET)

Para voltar ao binário anterior: `/etc/VPNManager/bin/proxy.bak_pre_dpi`.

## Build

```bash
./compile.sh arm64     # nativo nesta VPS
./compile.sh x86_64    # Docker ubuntu:22.04 --platform linux/amd64
./compile.sh all
```

Dependências: `gcc`, `libevent-dev`, `libssl-dev` (e Docker/qemu para x86_64).

## Validação

Testes usados em produção:

- `WS->SSH`, `SOCKS5`, `SOCKS4`, `CONNECT`, `DECOY`, `LEGADO` — 6/6
- token e SNI/decoy — 6/6
- fluxo real `80 -> fallback -> 8080 -> WS -> magic -> SSH` — OK
