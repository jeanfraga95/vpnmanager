# Patch reprodutivel: no caminho silent (101 imediato), nao enviar 200 extra.
# Chamado pelo build_unified.py depois do apply_silent_ws.py.
# Inspirado no proxyjf: apos consumir o request inicial, entra direto na ponte.
import re

DST = globals().get('DST', '/tmp/vpnfull/src/vpnproxy')
WS = DST + '/internal/wsproxy/wsproxy.go'


def rep(path, old, new, label):
    s = open(path).read()
    if new in s and old not in s:
        return
    if old not in s:
        raise SystemExit('ERRO nomagic200 [%s]: padrao nao encontrado' % label)
    open(path, 'w').write(s.replace(old, new, 1))


# --- wsproxy.go: marca que o 101 veio do ramo silent ---
# Insercao ancorada no campo 'pending' para tolerar o alinhamento do gofmt.
s = open(WS).read()
if re.search(r'^\tsilent101\s+bool', s, re.M):
    pass
else:
    m = re.search(r'^\tpending\s+\[\]byte // ClientHello enfileirado para o remoto\n', s, re.M)
    if not m:
        raise SystemExit('ERRO nomagic200 [campo silent101]: ancora nao encontrada')
    s = s[:m.end()] + '\tsilent101  bool   // 101 enviado no ramo --silent-ws (sem 200 extra)\n' + s[m.end():]
    open(WS, 'w').write(s)

# --- wsproxy.go: seta a marca no 101 imediato ---
rep(WS,
    '\t\tp.sendWS101("")\n'
    '\t\tp.sent101 = true\n'
    '\t\tp.state = stWSMagic\n'
    '\t\tp.armMagicTimer()\n',
    '\t\tp.sendWS101("")\n'
    '\t\tp.sent101 = true\n'
    '\t\tp.silent101 = true\n'
    '\t\tp.state = stWSMagic\n'
    '\t\tp.armMagicTimer()\n',
    'marca silent101')

# --- wsproxy.go: consome o request e vai direto a ponte no caminho silent ---
rep(WS,
    '\t\tp.clientBuf = b\n'
    '\t\tp.send200()\n'
    '\t\treturn p.startRelay(p.cfg.ToAddr, p.cfg.ToPort, false)\n',
    '\t\tp.clientBuf = b\n'
    '\t\tif !p.silent101 { // proxyjf: apos o 101 imediato, vai direto a ponte\n'
    '\t\t\tp.send200()\n'
    '\t\t}\n'
    '\t\tp.silent101 = false\n'
    '\t\treturn p.startRelay(p.cfg.ToAddr, p.cfg.ToPort, false)\n',
    'sem 200 extra')

print('nomagic200 aplicado em', DST)
