#!/usr/bin/env python3
"""Patch reproducivel: destravar gap wait sem perder ordenacao.

O fix d97a53d adicionou um gap wait quando k > nextIdx. Ele e necessario
para a ordem da primeira janela, mas no timeout ele so fazia delete do
pending e bailava: nextIdx ficava preso no ordinal ausente e TODOS os
downloads seguintes bailavam (DL out parado, bail crescendo, watchdog
CONGELAMENTO -> reconecta, ping some).

Agora, quando a VEZ e nossa (k == minK) mas faltam ordinais entre nextIdx
e k (pedidos perdidos/janela encolhida), comitamos esses ordinais como
VAZIO em served[] e avancamos nextIdx ate k. O byte cursor nao se move:
os bytes seguem sendo entregues em ordem, apenas sob os ordinais que
realmente chegaram. Sem bail storm e sem reconexao.

 Tambem trocamos o cond.Wait() cego por waitTimed(): sync.Cond nao tem
timeout, entao o limite so era reavaliado quando outra goroutine
broadcastava. Um pedido perdido podia travar para sempre.
"""
import sys

MARK = 'pulou gap (ordinais ausentes)'

HELPER = '''// waitTimed espera no cond com despertar garantido apos d. sync.Cond
// nao tem timeout: sem o timer, um gap wait so reavalia o limite quando
// outra goroutine broadcasta e um ordinal perdido trava para sempre.
func (s *Session) waitTimed(d time.Duration) {
\tt := time.AfterFunc(d, func() { s.cond.Broadcast() })
\ts.cond.Wait()
\tt.Stop()
}

'''

OLD_CHUNK = '''\t\t\tif time.Since(waitStart) > limit {
\t\t\t\tdelete(s.dlPending, k)
\t\t\t\ts.dlBailCount++
\t\t\t\ts.cond.Broadcast()
\t\t\t\tvlog("sessao %x: getChunk(%d) baiilou apos espera (minK=%d)", s.key[:4], k, minK)
\t\t\t\treturn []byte{}, 0, false
\t\t\t}
\t\t\ts.cond.Wait()
\t\t\tcontinue
'''

NEW_CHUNK = '''\t\t\tif time.Since(waitStart) > limit {
\t\t\t\tdelete(s.dlPending, k)
\t\t\t\tif k == minK && s.anchored && k > s.nextIdx {
\t\t\t\t\tfor miss := s.nextIdx; miss < k; miss++ {
\t\t\t\t\t\ts.served[miss] = chunkSpan{start: s.nextOff, end: s.nextOff}
\t\t\t\t\t}
\t\t\t\t\ts.nextIdx = k
\t\t\t\t\ts.cond.Broadcast()
\t\t\t\t\tvlog("sessao %x: getChunk(%d) pulou gap (ordinais ausentes) -> nextIdx=%d", s.key[:4], k, k)
\t\t\t\t\tbreak
\t\t\t\t}
\t\t\t\ts.dlBailCount++
\t\t\t\ts.cond.Broadcast()
\t\t\t\tvlog("sessao %x: getChunk(%d) baiilou apos espera (minK=%d)", s.key[:4], k, minK)
\t\t\t\treturn []byte{}, 0, false
\t\t\t}
\t\t\ts.waitTimed(limit)
\t\t\tcontinue
'''

OLD_BATCH = '''\t\t\tif time.Since(waitStart) > limit {
\t\t\t\tdelete(s.dlPending, base)
\t\t\t\ts.dlBailCount++
\t\t\t\ts.cond.Broadcast()
\t\t\t\tvlog("sessao %x: getBatch(%d) baiilou apos espera (minK=%d, gap=%v)", s.key[:4], base, minK, gap)
\t\t\t\treturn datas, false
\t\t\t}
\t\t\ts.cond.Wait()
\t\t\tcontinue
'''

NEW_BATCH = '''\t\t\tif time.Since(waitStart) > limit {
\t\t\t\tdelete(s.dlPending, base)
\t\t\t\tif base == minK && s.anchored && base > s.nextIdx {
\t\t\t\t\tfor miss := s.nextIdx; miss < base; miss++ {
\t\t\t\t\t\ts.served[miss] = chunkSpan{start: s.nextOff, end: s.nextOff}
\t\t\t\t\t}
\t\t\t\t\ts.nextIdx = base
\t\t\t\t\ts.cond.Broadcast()
\t\t\t\t\tvlog("sessao %x: getBatch(%d) pulou gap (ordinais ausentes) -> nextIdx=%d", s.key[:4], base, base)
\t\t\t\t\tbreak
\t\t\t\t}
\t\t\t\ts.dlBailCount++
\t\t\t\ts.cond.Broadcast()
\t\t\t\tvlog("sessao %x: getBatch(%d) baiilou apos espera (minK=%d, gap=%v)", s.key[:4], base, minK, gap)
\t\t\t\treturn datas, false
\t\t\t}
\t\t\ts.waitTimed(limit)
\t\t\tcontinue
'''


def apply(path):
    with open(path, 'r', encoding='utf-8') as fh:
        src = fh.read()
    if MARK in src:
        print('  ja aplicado (gapskip):', path)
        return 0
    rc = 0
    for name, old, new in (('getChunk', OLD_CHUNK, NEW_CHUNK),
                           ('getBatch', OLD_BATCH, NEW_BATCH)):
        if old not in src:
            print('ERRO: bloco %s nao encontrado em %s' % (name, path), file=sys.stderr)
            rc = 3
        else:
            src = src.replace(old, new, 1)
    if rc:
        return rc
    anchor = 'func (s *Session) getChunk(k int64, reqSize int)'
    if anchor not in src:
        print('ERRO: ancoragem getChunk nao encontrada em', path, file=sys.stderr)
        return 4
    src = src.replace(anchor, HELPER + anchor, 1)
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(src)
    print('  patch gapskip aplicado:', path)
    return 0


if __name__ == '__main__':
    rc = 0
    for p in sys.argv[1:]:
        rc |= apply(p)
    sys.exit(rc)
