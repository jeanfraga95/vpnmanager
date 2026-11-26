#!/usr/bin/env python3
"""Patch reproducivel: ordenacao de turno no getBatch (batch=true + conexoes paralelas).

Sem dlPending/minK, um batch com base maior pode tomar o cursor nextOff
antes dos ordinais menores; o app monta o stream SSH fora de ordem e
reporta "packet corrupt". Aplica o mesmo mecanismo do getChunk.
"""
import sys

MARK_START = '// getBatch serve N chunks contiguos'
MARK_END = '// trimServedLocked remove do inicio do dlBuf'

NEW = r'''// getBatch serve N chunks contiguos em uma UNICA aquisicao do mutex,
// eliminando a contencao O(N²) do getChunk individual com 32 conexoes.
// Retorna slices paralelas: datas[i] corresponde a ordinal base+i.
// Chamado SEM s.mu; internamente segura uma vez e drena tudo.
//
// ORDENACAO (batch=true, connections>1): todos os batches chegam ao mesmo
// tempo. Sem turno, um batch com base maior tomava o cursor nextOff antes
// dos ordinais menores, o app montava o stream fora de ordem e reportava
// "packet corrupt". Usa o mesmo mecanismo dlPending/minK do getChunk.
func (s *Session) getBatch(base int64, reqSize int, n int) (datas [][]byte, dead bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ep := s.epoch
	datas = make([][]byte, n)

	// Replay idempotente de batch inteiro ja servido: nao precisa de turno.
	allServed := n > 0
	for i := 0; i < n; i++ {
		ref, ok := s.served[base+int64(i)]
		if !ok || ref.start < s.dlBase || ref.end > s.dlBase+int64(len(s.dlBuf)) {
			allServed = false
			break
		}
	}
	if allServed {
		for i := 0; i < n; i++ {
			ref := s.served[base+int64(i)]
			out := make([]byte, ref.end-ref.start)
			copy(out, s.dlBuf[ref.start-s.dlBase:ref.end-s.dlBase])
			datas[i] = out
			s.dlReplayCount++
		}
		return datas, false
	}

	// Registra a vez do batch e espera ate ser o menor ordinal pendente.
	// Compartilha dlPending com getChunk: um chunk individual no meio do
	// batch serve primeiro se tiver ordinal menor, e o batch reentrega o
	// span ja servido via s.served.
	if _, ok := s.dlPending[base]; !ok {
		s.dlPending[base] = struct{}{}
	}
	waitStart := time.Now()
	for {
		if s.dead || s.epoch != ep {
			delete(s.dlPending, base)
			s.dlDeadCount++
			return datas, true
		}
		if s.dlEOF && s.nextOff >= s.dlBase+int64(len(s.dlBuf)) {
			delete(s.dlPending, base)
			log.Printf("sessao %x: batch %d apos EOF do stream -> reset", s.key[:4], base)
			s.resetLocked()
			return datas, false
		}
		minK := int64(-1)
		first := true
		for kk := range s.dlPending {
			if first || kk < minK {
				minK = kk
				first = false
			}
		}
		// Uma lacuna de ordinal nao pode ser servida na hora: o app envia
		// os batches das 4 conexoes quase ao mesmo tempo e as goroutines do
		// Go podem processar base=8 antes de base=0. Se servirmos 8 primeiro,
		// os bytes vao para o ordinal errado e o app reporta packet corrupt.
		// Espera breve para os ordinais menores chegarem e registrarem a vez.
		gap := base != minK
		if !s.anchored && base > 0 {
			gap = true
		}
		if s.anchored && base > s.nextIdx {
			gap = true
		}
		if gap {
			// Espera curta quando so falta o ordinal menor chegar; mais
			// longa quando outro batch detem a vez (pode estar servindo).
			limit := 150 * time.Millisecond
			if base != minK {
				limit = 1 * time.Second
			}
			if time.Since(waitStart) > limit {
				delete(s.dlPending, base)
				s.dlBailCount++
				s.cond.Broadcast()
				vlog("sessao %x: getBatch(%d) baiilou apos espera (minK=%d, gap=%v)", s.key[:4], base, minK, gap)
				return datas, false
			}
			s.cond.Wait()
			continue
		}
		break
	}
	delete(s.dlPending, base)

	for i := 0; i < n; i++ {
		k := base + int64(i)
		// replay se ja servido (ex.: getChunk individual neste ordinal)
		if ref, ok := s.served[k]; ok {
			if ref.start >= s.dlBase && ref.end <= s.dlBase+int64(len(s.dlBuf)) {
				out := make([]byte, ref.end-ref.start)
				copy(out, s.dlBuf[ref.start-s.dlBase:ref.end-s.dlBase])
				datas[i] = out
			} else {
				datas[i] = []byte{}
			}
			continue
		}
		if !s.anchored {
			s.anchored = true
			s.anchorIdx = k
			s.nextIdx = k
			s.nextOff = s.dlBase
		}
		if k < s.nextIdx {
			// ordinal obsoleto: reentrega span vivo em vez de vazio
			if ref, still := s.served[k]; still &&
				ref.start >= s.dlBase && ref.end <= s.dlBase+int64(len(s.dlBuf)) {
				out := make([]byte, ref.end-ref.start)
				copy(out, s.dlBuf[ref.start-s.dlBase:ref.end-s.dlBase])
				s.dlReplayCount++
				datas[i] = out
			} else {
				datas[i] = []byte{}
			}
			continue
		}
		start := s.nextOff
		avail := s.dlBase + int64(len(s.dlBuf))
		rem := avail - start
		n64 := int64(reqSize)
		if rem < n64 {
			n64 = rem
		}
		s.served[k] = chunkSpan{start: start, end: start + n64}
		s.nextIdx = k + 1
		if n64 > 0 {
			out := make([]byte, n64)
			copy(out, s.dlBuf[start-s.dlBase:start-s.dlBase+n64])
			s.nextOff = start + n64
			s.dlOutBytes += n64
			s.lastDLAdvance = time.Now()
			datas[i] = out
		} else {
			datas[i] = []byte{}
		}
		if s.dead || s.epoch != ep {
			return datas[:i+1], true
		}
		if s.dlEOF && s.nextOff >= s.dlBase+int64(len(s.dlBuf)) {
			log.Printf("sessao %x: batch pull %d apos EOF -> reset", s.key[:4], k)
			s.resetLocked()
			return datas[:i+1], false
		}
	}
	s.cond.Broadcast()
	return datas, false
}

'''


def apply(path):
    with open(path, 'r', encoding='utf-8') as fh:
        src = fh.read()
    if 'ORDENACAO (batch=true' in src:
        print('  ja aplicado:', path)
        return 0
    if MARK_START not in src or MARK_END not in src:
        print('ERRO: marcadores getBatch nao encontrados em', path, file=sys.stderr)
        return 2
    a = src.index(MARK_START)
    b = src.index(MARK_END, a)
    out = src[:a] + NEW + src[b:]
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(out)
    print('  patch aplicado:', path)
    return 0


if __name__ == '__main__':
    rc = 0
    for p in sys.argv[1:]:
        rc |= apply(p)
    sys.exit(rc)
