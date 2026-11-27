#!/usr/bin/env python3
"""PATCH10: ciclo de vida estilo dtproto no proxy Go.

- idle padrao 120s (client_inactive_timeout do proto-server)
- limite de bytes na fila de upload (NormalizedMaxUploadQueueBytes)
- orcamento GLOBAL de dlBuf com trim das sessoes menos ativas primeiro
- replayRetain escala com o numero de sessoes (sem piso de 12MB por sessao)
"""
import io
import sys


def apply(path):
    with io.open(path, 'r', encoding='utf-8') as f:
        src = f.read()
    orig = src

    def rep(old, new, tag):
        nonlocal src
        if old not in src:
            raise SystemExit('PATCH10 failed: %s' % tag)
        src = src.replace(old, new, 1)

    rep(
        '\tidleSessionTTL  = 15 * time.Minute // zumbi (app sumiu sem fechar limpo) e liberado logo; ajustavel via --idle\n',
        '\tidleSessionTTL  = 120 * time.Second // dtproto client_inactive_timeout: zumbi sem bytes reais ha 120s e liberado; ajustavel via --idle\n',
        'idleTTL')

    rep(
        '\tmaxConnOutQ     = 32768 // slots na fila de resposta por conexao (app 5.0.0: 32 connections)\n',
        '\tmaxConnOutQ     = 32768 // slots na fila de resposta por conexao (app 5.0.0: 32 connections)\n'
        '\tupQueueBytesMax = 8 << 20 // limite de bytes na fila de upload (dtproto NormalizedMaxUploadQueueBytes)\n',
        'upQueueBytesMax')

    rep(
        '\tupQ    chan upItem\n'
        '\tupDone chan struct{} // fechado em kill/reset p/ encerrar o worker\n',
        '\tupQ      chan upItem\n'
        '\tupQBytes int64       // bytes pendentes na fila de upload (backpressure por bytes)\n'
        '\tupDone   chan struct{} // fechado em kill/reset p/ encerrar o worker\n',
        'session-field')

    rep(
        '\ts.nextSeq = 0\n'
        '\ts.pending = map[uint64][]byte{}\n',
        '\ts.nextSeq = 0\n'
        '\ts.upQBytes = 0\n'
        '\ts.pending = map[uint64][]byte{}\n',
        'reset-upQBytes')

    rep(
        '\t\t\tif _, err := conn.Write(it.data); err != nil {\n'
        '\t\t\t\tlog.Printf("sessao %x: erro escrevendo SSH (gen=%d): %v — readLoop reconecta", s.key, gen, err)\n'
        '\t\t\t\treturn // readLoop ja setou s.ssh=nil; ensureSSH reconecta\n'
        '\t\t\t}\n',
        '\t\t\tif _, err := conn.Write(it.data); err != nil {\n'
        '\t\t\t\tlog.Printf("sessao %x: erro escrevendo SSH (gen=%d): %v — readLoop reconecta", s.key, gen, err)\n'
        '\t\t\t\treturn // readLoop ja setou s.ssh=nil; ensureSSH reconecta\n'
        '\t\t\t}\n'
        '\t\t\ts.mu.Lock()\n'
        '\t\t\tif s.upQBytes > int64(len(it.data)) {\n'
        '\t\t\t\ts.upQBytes -= int64(len(it.data))\n'
        '\t\t\t} else {\n'
        '\t\t\t\ts.upQBytes = 0\n'
        '\t\t\t}\n'
        '\t\t\ts.cond.Broadcast()\n'
        '\t\t\ts.mu.Unlock()\n',
        'upWorker-dec')

    rep(
        '\t\ts.mu.Unlock()\n'
        '\t\ts.upQ <- upItem{gen: ep, data: d}\n'
        '\t\ts.mu.Lock()\n'
        '\t\ts.lastUpWrite = time.Now()\n',
        '\t\t// Backpressure por bytes: a fila nao pode crescer sem limite\n'
        '\t\t// (dtproto tem NormalizedMaxUploadQueueBytes). O cond acorda\n'
        '\t\t// quando o upWorker termina de escrever no SSH.\n'
        '\t\ts.mu.Unlock()\n'
        '\t\ts.mu.Lock()\n'
        '\t\tfor s.upQBytes+int64(len(d)) > upQueueBytesMax && !s.dead && s.epoch == ep {\n'
        '\t\t\ts.cond.Wait()\n'
        '\t\t}\n'
        '\t\tif s.dead || s.epoch != ep {\n'
        '\t\t\ts.mu.Unlock()\n'
        '\t\t\treturn false\n'
        '\t\t}\n'
        '\t\ts.upQBytes += int64(len(d))\n'
        '\t\ts.mu.Unlock()\n'
        '\t\ts.upQ <- upItem{gen: ep, data: d}\n'
        '\t\ts.mu.Lock()\n'
        '\t\ts.lastUpWrite = time.Now()\n',
        'pushUpload-bytes')

    rep(
        '\t// reserva 50% da RAM disponivel pro conjunto de buffers de download;\n'
        '\t// o resto fica pra SO, goroutines, outros buffers do processo etc.\n'
        '\tbudget := int64(float64(ram.Available) * 0.8)\n'
        '\tper := budget / int64(nSessions)\n'
        '\tif per > dlSoftCapMax {\n'
        '\t\tper = dlSoftCapMax\n'
        '\t}\n'
        '\tif per < dlSoftCapMin {\n'
        '\t\tper = dlSoftCapMin\n'
        '\t}\n'
        '\t// retem pelo menos a janela do app (8MB) para o re-pull nao\n'
        '\t// devolver vazio e encolher a janela durante rajadas.\n'
        '\tretain := per * 2 / 3\n'
        '\tif retain > replayRetainMax {\n'
        '\t\tretain = replayRetainMax\n'
        '\t}\n'
        '\tif retain < replayRetainMin {\n'
        '\t\tretain = replayRetainMin\n'
        '\t}\n',
        '\t// ORCAMENTO GLOBAL: o conjunto de dlBuf nao pode passar de 60%\n'
        '\t// da RAM disponivel. O piso antigo (12MB por sessao) derrotava\n'
        '\t// esse limite quando havia milhares de sessoes — agora o cap\n'
        '\t// por sessao realmente divide o orcamento (estilo dtproto).\n'
        '\tbudget := int64(float64(ram.Available) * 0.60)\n'
        '\tper := budget / int64(nSessions)\n'
        '\tif per > dlSoftCapMax {\n'
        '\t\tper = dlSoftCapMax\n'
        '\t}\n'
        '\tif per < 1<<20 {\n'
        '\t\tper = 1 << 20\n'
        '\t}\n'
        '\t// Replay acompanha o cap por sessao. Com poucos usuarios continua\n'
        '\t// bem acima da janela de 8MB do app; com muitos, encolhe junto.\n'
        '\tretain := per * 2 / 3\n'
        '\tif retain > replayRetainMax {\n'
        '\t\tretain = replayRetainMax\n'
        '\t}\n'
        '\tif retain < 256<<10 {\n'
        '\t\tretain = 256 << 10\n'
        '\t}\n',
        'dynamic-caps')

    rep(
        '\t\ttype sinfo struct {\n'
        '\t\t\ts       *Session\n'
        '\t\t\tdlBytes int64\n'
        '\t\t\tlast    time.Time\n'
        '\t\t}\n',
        '\t\ttype sinfo struct {\n'
        '\t\t\ts       *Session\n'
        '\t\t\tdlBytes int64\n'
        '\t\t\tlast    time.Time\n'
        '\t\t\tlastAct time.Time\n'
        '\t\t}\n',
        'sinfo-field')

    rep(
        '\t\tvar stale, gapStuck, dlFrozen []*Session\n'
        '\t\tvar candidates []sinfo // candidatas a trim por excesso de dlBuf (ordinario + pressao de RAM)\n'
        '\t\tfor _, s := range registry.m {\n',
        '\t\tvar stale, gapStuck, dlFrozen []*Session\n'
        '\t\tvar candidates []sinfo // candidatas a trim por excesso de dlBuf (ordinario + pressao de RAM)\n'
        '\t\tvar totalDL int64\n'
        '\t\tfor _, s := range registry.m {\n',
        'totalDL-decl')

    rep(
        '\t\t\tif !s.dead && len(s.served) > 0 && len(s.dlBuf) > 0 {\n'
        '\t\t\t\tcandidates = append(candidates, sinfo{s, int64(len(s.dlBuf)), s.last})\n'
        '\t\t\t}\n',
        '\t\t\tif !s.dead && len(s.served) > 0 && len(s.dlBuf) > 0 {\n'
        '\t\t\t\tcandidates = append(candidates, sinfo{s, int64(len(s.dlBuf)), s.last, lastAct})\n'
        '\t\t\t\ttotalDL += int64(len(s.dlBuf))\n'
        '\t\t\t}\n',
        'totalDL-acc')

    rep(
        '\t\tfor _, ci := range candidates {\n'
        '\t\t\tci.s.mu.Lock()\n'
        '\t\t\tci.s.compactDLBufLocked(4 << 20)\n'
        '\t\t\tci.s.mu.Unlock()\n'
        '\t\t}\n',
        '\t\t// Teto global: se o somatorio dos buffers passou do orcamento,\n'
        '\t\t// corta primeiro as sessoes sem atividade real (mesma logica do\n'
        '\t\t// client_cleanup do dtproto), ate o total voltar para o limite.\n'
        '\t\tif totalDL > budgetBytes(ram) {\n'
        '\t\t\tsort.Slice(candidates, func(i, j int) bool {\n'
        '\t\t\t\treturn candidates[i].lastAct.Before(candidates[j].lastAct)\n'
        '\t\t\t})\n'
        '\t\t\tfor _, ci := range candidates {\n'
        '\t\t\t\tif totalDL <= budgetBytes(ram) {\n'
        '\t\t\t\t\tbreak\n'
        '\t\t\t\t}\n'
        '\t\t\t\tci.s.mu.Lock()\n'
        '\t\t\t\tcut := ci.s.trimServedLocked()\n'
        '\t\t\t\tci.s.mu.Unlock()\n'
        '\t\t\t\tif cut > 0 {\n'
        '\t\t\t\t\ttotalDL -= cut\n'
        '\t\t\t\t\tci.s.cond.Broadcast()\n'
        '\t\t\t\t}\n'
        '\t\t\t}\n'
        '\t\t}\n'
        '\n'
        '\t\tfor _, ci := range candidates {\n'
        '\t\t\tci.s.mu.Lock()\n'
        '\t\t\tci.s.compactDLBufLocked(4 << 20)\n'
        '\t\t\tci.s.mu.Unlock()\n'
        '\t\t}\n',
        'global-trim')

    rep(
        '//────────────────────────── reaper ─────────────────────────\n',
        'func budgetBytes(ram ramInfo) int64 {\n'
        '\treturn int64(float64(ram.Available) * 0.60)\n'
        '}\n'
        '\n'
        '//────────────────────────── reaper ─────────────────────────\n',
        'budget-helper')

    if src == orig:
        raise SystemExit('PATCH10: nenhuma alteracao')
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(src)
    print('PATCH10 dtproto-lifecycle aplicado:', path)


if __name__ == '__main__':
    apply(sys.argv[1] if len(sys.argv) > 1 else '/tmp/vpnfull/src/vpnproxy/main.go')
