# Patch reprodutivel: conexao silenciosa na porta WS recebe 101 (como o C).
# Chamado pelo build_unified.py apos gerar src/vpnproxy, e tambem aplicavel
# diretamente nos arquivos ja gerados.
DST = globals().get('DST', '/tmp/vpnfull/src/vpnproxy')


def rep(path, old, new, label):
    s = open(path).read()
    if new in s and old not in s:
        return
    if old not in s:
        raise SystemExit('ERRO silent-ws [%s]: padrao nao encontrado' % label)
    open(path, 'w').write(s.replace(old, new, 1))


# --- main.go: flag ---
rep(DST + '/main.go',
    '\tflagTLSKey   = flag.String("tls-key", "", "caminho para chave TLS (para QUIC)")\n',
    '\tflagTLSKey   = flag.String("tls-key", "", "caminho para chave TLS (para QUIC)")\n'
    '\tflagSilentWS = flag.Bool("silent-ws", false, "conexao sem dados iniciais recebe 101 (como o C) em vez de virar BHTTP")\n',
    'flag")')

# --- main.go: timeout do sniff mais curto no modo WS ---
rep(DST + '/main.go',
    '\t\t// peek no primeiro byte para detectar TLS ClientHello (0x16)\n'
    '\t\tc.SetReadDeadline(time.Now().Add(200 * time.Millisecond))\n',
    '\t\t// peek no primeiro byte para detectar TLS ClientHello (0x16)\n'
    '\t\tsniffWait := 200 * time.Millisecond\n'
    '\t\tif *flagSilentWS {\n'
    '\t\t\tsniffWait = 50 * time.Millisecond\n'
    '\t\t}\n'
    '\t\tc.SetReadDeadline(time.Now().Add(sniffWait))\n',
    'sniff-timeout')

# --- main.go: frame fragmentado no modo WS vai para o wsproxy ---
rep(DST + '/main.go',
    '\t\t\t\tif len(pfx) >= 3 && (pfx[0] == 0x04 || pfx[0] == 0x05) && pfx[2] == 0x00 {\n'
    '\t\t\t\t\trouteWS(c, pfx)\n'
    '\t\t\t\t\treturn\n'
    '\t\t\t\t}\n'
    '\t\t\t\tc = &prefixConn{Conn: c, prefix: pfx}\n',
    '\t\t\t\tif len(pfx) >= 3 && (pfx[0] == 0x04 || pfx[0] == 0x05) && pfx[2] == 0x00 {\n'
    '\t\t\t\t\trouteWS(c, pfx)\n'
    '\t\t\t\t\treturn\n'
    '\t\t\t\t}\n'
    '\t\t\t\tif *flagSilentWS {\n'
    '\t\t\t\t\tlog.Printf("CONN %s: frame fragmentado %dB no modo silent-ws -> WS", c.RemoteAddr(), len(pfx))\n'
    '\t\t\t\t\trouteWS(c, pfx)\n'
    '\t\t\t\t\treturn\n'
    '\t\t\t\t}\n'
    '\t\t\t\tc = &prefixConn{Conn: c, prefix: pfx}\n',
    'fragmentado')

# --- main.go: zero bytes no modo WS ---
rep(DST + '/main.go',
    '\t\t} else {\n'
    '\t\t\t// timeout sem dados — assume BHTTP\n'
    '\t\t\tlog.Printf("CONN %s: sniff nil (timeout sem dados), assume BHTTP", c.RemoteAddr())\n'
    '\t\t}\n',
    '\t\t} else {\n'
    '\t\t\tif *flagSilentWS {\n'
    '\t\t\t\t// Comportamento do proxy C na 8080: o app abre a TCP e espera\n'
    '\t\t\t\t// o 101. No 4G/CGNAT o 1o pacote pode demorar; sem isso a\n'
    '\t\t\t\t// conexao cairia no motor BHTTP e nunca responderia.\n'
    '\t\t\t\tlog.Printf("CONN %s: sniff nil no modo silent-ws -> 101 imediato", c.RemoteAddr())\n'
    '\t\t\t\trouteWS(c, nil)\n'
    '\t\t\t\treturn\n'
    '\t\t\t}\n'
    '\t\t\t// timeout sem dados — assume BHTTP\n'
    '\t\t\tlog.Printf("CONN %s: sniff nil (timeout sem dados), assume BHTTP", c.RemoteAddr())\n'
    '\t\t}\n',
    'zero-byte')

# --- dispatch.go: routeWS com config Silent ---
rep(DST + '/dispatch.go',
    'func routeWS(c net.Conn, prefix []byte) {\n'
    '\twsproxy.Serve(&prefixConn{Conn: c, prefix: prefix}, wsConfig())\n'
    '}\n',
    'func routeWS(c net.Conn, prefix []byte) {\n'
    '\tcfg := wsConfig()\n'
    '\tif *flagSilentWS && len(prefix) == 0 {\n'
    '\t\tsilent := *cfg\n'
    '\t\tsilent.Silent = true\n'
    '\t\tcfg = &silent\n'
    '\t}\n'
    '\twsproxy.Serve(&prefixConn{Conn: c, prefix: prefix}, cfg)\n'
    '}\n',
    'routeWS')

# --- wsproxy.go: campo Silent ---
rep(DST + '/internal/wsproxy/wsproxy.go',
    '\tSNIAllow     string\n'
    '\tAuthToken    string\n'
    '}\n',
    '\tSNIAllow     string\n'
    '\tAuthToken    string\n'
    '\tSilent       bool // envia 101 sem esperar o 1o read (cliente silencioso)\n'
    '}\n',
    'config silent')

# --- wsproxy.go: Serve envia 101 na hora quando Silent ---
OLD_SERVE = '''\tbuf := make([]byte, 8192)
\tc.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
\tn, err := c.Read(buf)
\tif n > 0 {
\t\tp.clientBuf = append(p.clientBuf, buf[:n]...)
\t}
\tif err != nil {
\t\tne, timeout := err.(net.Error)
\t\tif timeout && ne.Timeout() && p.state == stInit && cfg.Immediate101 &&
\t\t\tcfg.AuthToken == "" && !p.sent101 && n == 0 {
\t\t\t// Cliente silenciou: 101 exato do proxy original e passa a
\t\t\t// aguardar dados. Não processa ST_WS_MAGIC agora (o C só responde
\t\t\t// ao próximo read callback).
\t\t\tp.sendImmediate101()
\t\t\tp.sent101 = true
\t\t\tp.state = stWSMagic
\t\t\tp.armMagicTimer()
\t\t} else if n == 0 {
\t\t\treturn
\t\t}
\t\t// Se n > 0, processa os bytes recebidos mesmo com erro de leitura.
\t}
\tc.SetReadDeadline(time.Time{})
'''
NEW_SERVE = '''\tbuf := make([]byte, 8192)
\tvar n int
\tvar err error
\tif cfg.Silent {
\t\t// O sniff da 8080 ja esperou o cliente; mandar o 101 agora evita
\t\t// somar mais 50ms e replica o aceite do proxy C.
\t\tp.sendImmediate101()
\t\tp.sent101 = true
\t\tp.state = stWSMagic
\t\tp.armMagicTimer()
\t} else {
\t\tc.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
\t\tn, err = c.Read(buf)
\t\tif n > 0 {
\t\t\tp.clientBuf = append(p.clientBuf, buf[:n]...)
\t\t}
\t\tif err != nil {
\t\t\tne, timeout := err.(net.Error)
\t\t\tif timeout && ne.Timeout() && p.state == stInit && cfg.Immediate101 &&
\t\t\t\tcfg.AuthToken == "" && !p.sent101 && n == 0 {
\t\t\t\t// Cliente silenciou: 101 exato do proxy original e passa a
\t\t\t\t// aguardar dados. Não processa ST_WS_MAGIC agora (o C só responde
\t\t\t\t// ao próximo read callback).
\t\t\t\tp.sendImmediate101()
\t\t\t\tp.sent101 = true
\t\t\t\tp.state = stWSMagic
\t\t\t\tp.armMagicTimer()
\t\t\t} else if n == 0 {
\t\t\t\treturn
\t\t\t}
\t\t\t// Se n > 0, processa os bytes recebidos mesmo com erro de leitura.
\t\t}
\t\tc.SetReadDeadline(time.Time{})
\t}
'''
rep(DST + '/internal/wsproxy/wsproxy.go', OLD_SERVE, NEW_SERVE, 'serve silent')

print('silent-ws aplicado em', DST)
