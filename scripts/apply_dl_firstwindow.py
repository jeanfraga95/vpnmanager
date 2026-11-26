#!/usr/bin/env python3
"""Patch reproducivel: ordenacao da PRIMEIRA janela de frameDownload.

Com pipeline/multi-conexao, o maior ordinal pode pegar o mutex primeiro,
ancorar o cursor e transformar os ordinais menores em "obsoletos" (resposta
vazia). O app entao monta o stream SSH fora de ordem e reporta
"Packet corrupt" durante a autenticacao.

Aplica:
  - campo firstDLAt (janela comum de estabilizacao da 1a janela);
  - wait antes de ancorar em k>0;
  - gap wait no loop de turno quando k > nextIdx.
"""
import sys

MARK_START = '// getChunk \u2014 semantica PROVADA'
MARK_END = '// getBatch serve N chunks contiguos'

FIELD_OLD = '\tlastDLAdvance time.Time // ultima vez que bytes reais flu\u00edram ao app (getChunk/getBatch n>0)\n'
FIELD_NEW = (FIELD_OLD +
             '\tfirstDLAt     time.Time // instante do 1o pedido da janela (ordena os downloads iniciais)\n')
RESET_OLD = '\ts.lastDLAdvance = time.Time{}\n'
RESET_NEW = (RESET_OLD +
             '\ts.firstDLAt = time.Time{}\n')

NEW = r'''// getChunk — modelo CURSOR/TURNOS: cada ordinal entrega, NA SUA VEZ
// (minK), os bytes que estiverem no cursor; vazio comita e avanca a vez;
// parcial sai imediato. Toda saida deleta pending => sem deadlock.
//
// ORDENACAO DA PRIMEIRA JANELA (packet corrupt com pipeline/multi-conexao):
// o app dispara N downloads de uma vez. Se o ordinal maior pegar o mutex
// primeiro e ancorar, os menores viram "obsoletos" e recebem vazio; o JSch
// entao reporta Packet corrupt no meio da autenticacao. Abre-se uma janela
// curta (200ms, ~2.5 RTT do app) para os menores chegarem e reivindicarem
// a vez; so ancora em k se ele for o menor ao fim da janela.
func (s *Session) getChunk(k int64, reqSize int) (data []byte, st byte, dead bool) {
\ts.mu.Lock()
\tdefer s.mu.Unlock()
\tep := s.epoch

\tif ref, ok := s.served[k]; ok {
\t\ts.dlReplayCount++
\t\tif ref.start >= s.dlBase && ref.end <= s.dlBase+int64(len(s.dlBuf)) {
\t\t\tout := make([]byte, ref.end-ref.start)
\t\t\tcopy(out, s.dlBuf[ref.start-s.dlBase:ref.end-s.dlBase])
\t\t\tvlog("getChunk(%d,%d) -> replay %dB", k, reqSize, len(out))
\t\t\treturn out, 0, false
\t\t}
\t\treturn []byte{}, 0, false
\t}

\tif s.firstDLAt.IsZero() {
\t\ts.firstDLAt = time.Now()
\t}
\t// Espera COMMUM desde o primeiro pedido: cada goroutine tem o mesmo
\t// deadline, entao um ordinal que chega tarde ainda pode ser o menor.
\tif !s.anchored && k > 0 {
\t\twaitStart := time.Now()
\t\tfor !s.anchored {
\t\t\tif s.dead || s.epoch != ep {
\t\t\t\ts.dlDeadCount++
\t\t\t\treturn []byte{}, 0, false
\t\t\t}
\t\t\tminK := int64(-1)
\t\t\tfirst := true
\t\t\tfor kk := range s.dlPending {
\t\t\t\tif first || kk < minK {
\t\t\t\t\tminK = kk
\t\t\t\t\tfirst = false
\t\t\t\t}
\t\t\t}
\t\t\tif k == minK && (time.Since(s.firstDLAt) >= 200*time.Millisecond ||
\t\t\t\ttime.Since(waitStart) >= time.Second) {
\t\t\t\tbreak
\t\t\t}
\t\t\ts.dlPending[k] = struct{}{}
\t\t\ts.cond.Wait()
\t\t}
\t\tdelete(s.dlPending, k)
\t\ts.cond.Broadcast()
\t}

\tif !s.anchored {
\t\ts.anchored = true
\t\ts.anchorIdx = k
\t\ts.nextIdx = k
\t\ts.nextOff = s.dlBase
\t}
\tif k < s.nextIdx {
\t\t// ordinal obsoleto: NAO reentregar (evita desync/packet corrupt).
\t\ts.dlObsoleteCnt++
\t\ts.obsGap += s.nextIdx - k
\t\ts.obsGapN++
\t\tif s.obsGapN%512 == 1 {
\t\t\tlog.Printf("sessao %x: obs k=%d atras nextIdx=%d (gap=%d, avg=%.1f)", s.key[:4], k, s.nextIdx, s.nextIdx-k, float64(s.obsGap)/float64(s.obsGapN))
\t\t}
\t\treturn []byte{}, 0, false
\t}
\tif _, ok := s.dlPending[k]; !ok {
\t\ts.dlPending[k] = struct{}{}
\t}
\twaitStart := time.Now()
\tfor {
\t\tif s.dead || s.epoch != ep {
\t\t\tdelete(s.dlPending, k)
\t\t\ts.dlDeadCount++
\t\t\treturn []byte{}, 0, false
\t\t}
\t\tif s.dlEOF && s.nextOff >= s.dlBase+int64(len(s.dlBuf)) {
\t\t\tdelete(s.dlPending, k)
\t\t\tlog.Printf("sessao %x: pull %d apos EOF do stream -> reset", s.key[:4], k)
\t\t\ts.resetLocked()
\t\t\treturn []byte{}, 0, false
\t\t}
\t\tminK := int64(-1)
\t\tfirst := true
\t\tfor kk := range s.dlPending {
\t\t\tif first || kk < minK {
\t\t\t\tminK = kk
\t\t\t\tfirst = false
\t\t\t}
\t\t}
\t\tgap := k != minK
\t\t// Apos ancorar, k > nextIdx significa que ainda faltam ordinais
\t\t// menores chegarem (corrida entre conexoes). Servir agora faria os
\t\t// futuros menores virarem obsoletos. Espera curta quando somos o
\t\t// menor pendente; mais longa quando outro detem a vez.
\t\tif s.anchored && k > s.nextIdx {
\t\t\tgap = true
\t\t}
\t\tif gap {
\t\t\tlimit := time.Second
\t\t\tif k == minK {
\t\t\t\tlimit = 200 * time.Millisecond
\t\t\t}
\t\t\tif time.Since(waitStart) > limit {
\t\t\t\tdelete(s.dlPending, k)
\t\t\t\ts.dlBailCount++
\t\t\t\ts.cond.Broadcast()
\t\t\t\tvlog("sessao %x: getChunk(%d) baiilou apos espera (minK=%d)", s.key[:4], k, minK)
\t\t\t\treturn []byte{}, 0, false
\t\t\t}
\t\t\ts.cond.Wait()
\t\t\tcontinue
\t\t}
\t\tbreak
\t}
\tdelete(s.dlPending, k)
\tstart := s.nextOff
\tavail := s.dlBase + int64(len(s.dlBuf))
\trem := avail - start
\tn := int64(reqSize)
\tif rem < n {
\t\tn = rem
\t}
\ts.served[k] = chunkSpan{start: start, end: start + n}
\ts.nextIdx = k + 1
\tif n > 0 {
\t\tout := make([]byte, n)
\t\tcopy(out, s.dlBuf[start-s.dlBase:start-s.dlBase+n])
\t\ts.nextOff = start + n
\t\ts.dlOutBytes += n
\t\ts.lastDLAdvance = time.Now()
\t\ts.cond.Broadcast()
\t\tvlog("getChunk(%d,%d) -> %dB", k, reqSize, n)
\t\treturn out, 0, false
\t}
\ts.dlEmptyHits++
\ts.cond.Broadcast()
\treturn []byte{}, 0, false
}

'''

# NEW e' string raw para preservar os escapes de Go (%d, %q); converte os
# \t usados como indentacao em TABs reais antes de escrever no .go.
NEW = NEW.replace('\\t', '\t')


def apply(path):
    with open(path, 'r', encoding='utf-8') as fh:
        src = fh.read()
    if 'janela COMMUM desde o primeiro pedido' in src:
        print('  ja aplicado:', path)
        return 0
    if FIELD_OLD not in src or RESET_OLD not in src:
        print('ERRO: marcadores firstDLAt/reset nao encontrados em', path, file=sys.stderr)
        return 2
    if MARK_START not in src or MARK_END not in src:
        print('ERRO: marcadores getChunk/getBatch nao encontrados em', path, file=sys.stderr)
        return 3
    src = src.replace(FIELD_OLD, FIELD_NEW, 1)
    src = src.replace(RESET_OLD, RESET_NEW, 1)
    a = src.index(MARK_START)
    b = src.index(MARK_END, a)
    src = src[:a] + NEW + src[b:]
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(src)
    print('  patch aplicado:', path)
    return 0


if __name__ == '__main__':
    rc = 0
    for p in sys.argv[1:]:
        rc |= apply(p)
    sys.exit(rc)
