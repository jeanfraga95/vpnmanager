#!/usr/bin/env python3
"""Patch reproducivel PATCH9: reaper de zumbis por atividade REAL.

O reaper usava s.last, atualizado por QUALQUER frame (inclusive polling
de conexoes abandonadas pelo app). Com isso sessoes que nao transferiam
bytes nunca eram encerradas: 2600+ sessoes no registry, zero kills,
dezenas de processos sshd por usuario e "Online" inflado no painel.

Agora a idade da sessao e medida pelo ultimo byte real de upload
(lastUpWrite) ou download (lastDLAdvance), com fallback para a criacao.
"""
import re
import sys

MARK = 'created time.Time // criacao: base do reaper'

INIT_OLD = '\t\tlast:      time.Now(),\n'
INIT_NEW = '\t\tlast:      time.Now(),\n\t\tcreated:   time.Now(),\n'

STALE_OLD = '''\t\t\tif time.Since(s.last) > *flagIdle {
\t\t\t\tstale = append(stale, s)
\t\t\t}
'''
STALE_NEW = '''\t\t\t// s.last e atualizado por QUALQUER frame, inclusive o polling
\t\t\t// de conexoes que o app abandonou — nao serve para medir uso.
\t\t\t// Usa bytes REAIS de upload/download (ou a criacao) para nao
\t\t\t// acumular sessoes/sshd que ninguem mais esta usando.
\t\t\tlastAct := s.created
\t\t\tif s.lastDLAdvance.After(lastAct) {
\t\t\t\tlastAct = s.lastDLAdvance
\t\t\t}
\t\t\tif s.lastUpWrite.After(lastAct) {
\t\t\t\tlastAct = s.lastUpWrite
\t\t\t}
\t\t\tif time.Since(lastAct) > *flagIdle {
\t\t\t\tstale = append(stale, s)
\t\t\t}
'''


def apply(path):
    with open(path, 'r', encoding='utf-8') as fh:
        src = fh.read()
    if MARK in src:
        print('  ja aplicado (stale-reap):', path)
        return 0
    # O gerador aplica os patches ANTES do gofmt: o espacamento do struct
    # varia entre '\tlast time.Time' e '\tlast        time.Time'.
    src, n = re.subn(r'\n\tlast\s+time\.Time\n',
                     '\n\tlast        time.Time\n'
                     '\tcreated     time.Time // criacao: base do reaper de zumbis sem trafego real\n',
                     src, count=1)
    if n != 1:
        print('  ERRO: campo last nao encontrado no struct', file=sys.stderr)
        return 1
    print('  aplicado: struct')

    rc = 0
    for name, old, new in (('init', INIT_OLD, INIT_NEW),
                           ('stale', STALE_OLD, STALE_NEW)):
        if old not in src:
            print('  ERRO: padrao nao encontrado (%s) em %s' % (name, path), file=sys.stderr)
            rc = 1
            continue
        src = src.replace(old, new, 1)
        print('  aplicado:', name)
    if rc == 0:
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(src)
    return rc


if __name__ == '__main__':
    sys.exit(apply(sys.argv[1] if len(sys.argv) > 1 else
                   '/tmp/vpnfull/src/vpnproxy/main.go'))
