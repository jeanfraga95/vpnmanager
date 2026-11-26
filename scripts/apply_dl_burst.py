#!/usr/bin/env python3
"""Patch reproducivel: absorver rajadas (speedtest/download) sem shrink.

O app informa window=8388608B (8MB), mas o replay retain ficava em 6MB
(per/2 com piso de 12MB). Re-pulls além de 6MB viravam VAZIO, o app
encolia a janela e o watchdog CONGELAMENTO resetava a sessao.

Muda:
  - replayRetainMin: 2MB -> 8MB;
  - retain = per*2/3 (com per minimo 12MB => 8MB, igual a janela do app);
  - CONGELAMENTO so reseta se houver backlog real (>=256KB) E o app
    ainda estiver pedindo (s.last <= 10s): sessao ociosa nao e' destruida;
  - log do reaper so para cortes >=64KB (evita flood no speedtest).
"""
import sys

MARK = 'replayRetainMin = 8 << 20'

RETAIN_OLD = '\treplayRetainMin = 2 << 20\n'
RETAIN_NEW = '\treplayRetainMin = 8 << 20 // janela do app e 8MB: retain menor gera vazio no re-pull\n'

FORMULA_OLD = '\tretain := per / 2\n'
FORMULA_NEW = ('\t// retem pelo menos a janela do app (8MB) para o re-pull nao\n'
               '\t// devolver vazio e encolher a janela durante rajadas.\n'
               '\tretain := per * 2 / 3\n')

FREEZE_OLD = '''\t\t\tif !s.dead && s.everData && !s.lastDLAdvance.IsZero() &&
\t\t\t\t(s.dlOutBytes > 0 || len(s.dlBuf) > 0) &&
\t\t\t\ttime.Since(s.lastDLAdvance) >= 30*time.Second &&
\t\t\t\t(s.lastUpWrite.IsZero() || time.Since(s.lastUpWrite) >= 30*time.Second) {
'''
FREEZE_NEW = '''\t\t\tif !s.dead && s.everData && !s.lastDLAdvance.IsZero() &&
\t\t\t\t(s.dlOutBytes > 0 || len(s.dlBuf) > 0) &&
\t\t\t\ttime.Since(s.lastDLAdvance) >= 30*time.Second &&
\t\t\t\ttime.Since(s.last) <= 10*time.Second &&
\t\t\t\tlen(s.dlBuf) >= 256<<10 &&
\t\t\t\t(s.lastUpWrite.IsZero() || time.Since(s.lastUpWrite) >= 30*time.Second) {
'''

LOG_OLD = '''\t\t\tif cut > 0 {
\t\t\t\tlog.Printf("sessao %x: reaper limpou %dKB do dlBuf (%dKB -> %dKB)",
\t\t\t\t\ts.key[:4], cut/1024, (cut+int64(len(s.dlBuf)))/1024, len(s.dlBuf)/1024)
\t\t\t\ts.cond.Broadcast()
\t\t\t}
'''
LOG_NEW = '''\t\t\tif cut > 0 {
\t\t\t\tif cut >= 64<<10 {
\t\t\t\t\tlog.Printf("sessao %x: reaper limpou %dKB do dlBuf (%dKB -> %dKB)",
\t\t\t\t\t\ts.key[:4], cut/1024, (cut+int64(len(s.dlBuf)))/1024, len(s.dlBuf)/1024)
\t\t\t\t}
\t\t\t\ts.cond.Broadcast()
\t\t\t}
'''


def apply(path):
    with open(path, 'r', encoding='utf-8') as fh:
        src = fh.read()
    if MARK in src:
        print('  ja aplicado (burst):', path)
        return 0
    rc = 0
    for name, old, new in (('retainMin', RETAIN_OLD, RETAIN_NEW),
                           ('formula', FORMULA_OLD, FORMULA_NEW),
                           ('freeze', FREEZE_OLD, FREEZE_NEW),
                           ('log', LOG_OLD, LOG_NEW)):
        if old not in src:
            print('ERRO: bloco %s nao encontrado em %s' % (name, path), file=sys.stderr)
            rc = 3
        else:
            src = src.replace(old, new, 1)
    if rc:
        return rc
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(src)
    print('  patch burst aplicado:', path)
    return 0


if __name__ == '__main__':
    rc = 0
    for p in sys.argv[1:]:
        rc |= apply(p)
    sys.exit(rc)
