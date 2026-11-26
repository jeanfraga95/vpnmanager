#!/usr/bin/env python3
"""Janela de sniff do --silent-ws compativel com BHTTP de rtt alto.

O app informa rtt=81ms. Com 50ms o proxy devolvia 101 antes do primeiro
frame BHTTP, o cliente interpretava o HTTP como dados SSH e estourava
"packet corrupt" logo apos autenticar. 200ms continua dentro do limite
do QA do 101 silencioso (<300ms).
"""
import sys

OLD = '\t\tif *flagSilentWS {\n\t\t\tsniffWait = 50 * time.Millisecond\n\t\t}\n'
NEW = (
    '\t\tif *flagSilentWS {\n'
    '\t\t\t// App BHTTP reporta rtt=81ms: com 50ms o 1o frame chegava depois\n'
    '\t\t\t// do 101 e o stream SSH era corrompido na autenticacao.\n'
    '\t\t\tsniffWait = 200 * time.Millisecond\n'
    '\t\t}\n'
)


def apply(path):
    with open(path, 'r', encoding='utf-8') as fh:
        src = fh.read()
    if 'rtt=81ms: com 50ms' in src:
        print('  ja aplicado:', path)
        return 0
    if OLD not in src:
        print('ERRO: marcador sniffWait ausente em', path, file=sys.stderr)
        return 2
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(src.replace(OLD, NEW, 1))
    print('  patch aplicado:', path)
    return 0


if __name__ == '__main__':
    rc = 0
    for p in sys.argv[1:]:
        rc |= apply(p)
    sys.exit(rc)
