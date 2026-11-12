//============================================================
// bhttpssh - Servidor do protocolo "Binary BHTTP" (DTunnel)
//
// Implementa o protocolo reverso-engenhado do app DTunnel 4.6.7
// (classes c8/hk/qj/wj/ok/pj/dk do DEX): conexao TCP crua onde
// cada frame tem cabecalho de 29 bytes:
//
//   [tipo(1)][chave-sessao(16)][sequencia(8 BE)][tamanho(4 BE)]
//
// seguido de payload cifrado com XOR de keystream SHA-256:
//   seed(30) = chave(16) || tipo(1) || seq(8) || direcao(1) || contador(4)
//   bloco_i  = SHA256(seed || contador_BE32)   (blocos de 32 bytes)
//   direcao: 0 = cliente->servidor, 1 = servidor->cliente
//
// Respostas tem cabecalho de 5 bytes: [status(1)][tamanho(4 BE)]
// (payload de erro vem em texto puro; status 0 = OK).
//
// Tipos de frame:
//   0 = probe  (echo exato do payload; seq = tamanho candidato;
//               usado pelo cliente p/ medir MTU/RTT - dk.c)
//   1 = upload (dados SSH cliente->servidor, reordenados por seq;
//               seq 0 vazio = abertura de sessao - pj.a)
//   2 = download de 1 chunk: SEM payload; o campo "tamanho" do
//       header carrega o chunk size pedido (qj.b / dk.a)
//   3 = download em lote: payload [chunkSize(4BE)][qtd(2BE)];
//       seq no cabecalho = primeiro indice (ec.H); N respostas
//       em ordem, cada uma cifrada com seu proprio indice
//   4 = ACK de fluxo (seq = indice consumido; responde vazio;
//       libera memoria abaixo da marca - sj/wj.a)
//
// Modelo de download (wj): os chunks sao consumidos SEQUENCIAL-
// MENTE por indice e cada resposta continua exatamente onde a
// anterior parou (encadeamento contiguo). O servidor mantem, por
// sessao, o fim absoluto de cada chunk servido (chunkEnds). Chunk
// curto e valido (ex.: banner SSH chega antes de completar o
// tamanho pedido). Apos o EOF do SSH, pedido de chunk alem do fim
// => fecha a conexao (cliente interpreta como fim do stream).
// Memoria so e liberada abaixo do ultimo ACK recebido.
//
// Uso: bhttpssh --port <PORTA> --to <DESTINO>   (padrao: 22)
//============================================================
package main

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"os"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/quic-go/quic-go"
)

const (
	frameProbe    = 0
	frameUpload   = 1
	frameDownload = 2
	frameBatch    = 3
	frameAck      = 4
	frameResume   = 5

	hdrSize     = 29
	respHdrSize = 5
	maxPayload  = 160 * 1024 // probes chegam a 131072+29 (dk.c)
	maxBatch       = 1024
	// dlSoftCapMax/dlSoftCapMin: teto e piso do buffer de download POR
	// SESSAO. Com 1 usuario o servidor pode dar o teto inteiro (folga p/
	// speedtest pesado); com N usuarios simultaneos o cap efetivo (curDLCap)
	// e recalculado a cada tick do reaper dividindo a RAM disponivel pelo
	// numero de sessoes vivas — assim nenhum usuario sozinho consegue
	// "encher" o servidor e derrubar os outros. Ver updateDynamicCaps().
	dlSoftCapMax   = 256 << 20 // buffer p/ transfers pesados (speedtest 5.0.1 encostou em 64MB em 1s; folga maior evita backpressure precoce)
	dlSoftCapMin   = 12 << 20  // piso: abaixo disso um download normal ja engasga
	// margem de reentrega: o trim NUNCA corta o dlBuf alem de deixar estes
	// ultimos bytes vivos, para que ordinais re-puxados fora de ordem pelo
	// app (speedtest multi-conexao) ainda tenham seu span reentregue em vez
	// de virar vazio e encolher a janela (congelamento pos-speedtest).
	// tambem escala com curDLCap() (ver curReplayRetain).
	replayRetainMax = 64 << 20
	replayRetainMin = 2 << 20
	idleSessionTTL  = 15 * time.Minute // zumbi (app sumiu sem fechar limpo) e liberado logo; ajustavel via --idle
	connIdleTO     = 150 * time.Second
	connWriteTO    = 30 * time.Second  // timeout de escrita no app (mobile CGNAT precisa de mais tempo)
	chunkWait      = 300 * time.Millisecond
	maxPendingUp   = 4096 // frames de upload fora de ordem (sanidade)
	maxConnOutQ    = 32768 // slots na fila de resposta por conexao (app 5.0.0: 32 connections)
)

var (
	flagPort     = flag.Int("port", 0, "porta local para escutar")
	flagBind     = flag.String("bind", "", "endereco local opcional (ip:porta ou :porta); sobrepoe --port")
	flagStatic   = flag.String("static-target", "", "destino host:porta (compat painel)")
	flagUdpgw    = flag.Bool("udpgw-enable", true, "ignorado (compat painel)")
	flagSSHen    = flag.Bool("ssh-enable", true, "ignorado (compat painel)")
	flagTo       = flag.String("to", "127.0.0.1:22", "destino local (host:porta)")
	flagFallback = flag.String("fallback-target", "", "se 1o frame nao for BHTTP, repassa a conexao crua para este host:porta")
	flagTun      = flag.String("tun", "dtp0", "interface TUN do modo dtproto")
	flagIdle     = flag.Duration("idle", idleSessionTTL, "tempo de vida de sessao ociosa")
	flagVerbose  = flag.Bool("verbose", false, "log detalhado")
	flagQUICPort = flag.Int("quic-port", 0, "porta UDP para QUIC (0 = desabilitado)")
	flagTLSCert  = flag.String("tls-cert", "", "caminho para certificado TLS (para QUIC)")
	flagTLSKey   = flag.String("tls-key", "", "caminho para chave TLS (para QUIC)")

	dtLn    net.Listener
	dtAddr  string
	tlsServer *tls.Config // config TLS para aceitar ClientHello na porta 80

	// caps dinamicos por-sessao, recalculados a cada tick do reaper
	// (updateDynamicCaps) em funcao da RAM disponivel e do numero de
	// sessoes ativas. Comecam no teto (uso solo/poucos usuarios).
	dynCapMu     sync.RWMutex
	dynDLCap     int64 = dlSoftCapMax
	dynReplayRet int64 = replayRetainMax
)

func curDLCap() int64 {
	dynCapMu.RLock()
	defer dynCapMu.RUnlock()
	return dynDLCap
}

func curReplayRetain() int64 {
	dynCapMu.RLock()
	defer dynCapMu.RUnlock()
	return dynReplayRet
}

// updateDynamicCaps recalcula o orcamento de buffer por-sessao dividindo
// uma fatia da RAM disponivel pelo numero de sessoes vivas. Isso e o que
// faz o "tunnel encher com o tempo" parar de acontecer com varios
// usuarios: quanto mais sessoes conectadas, menor o buffer que cada uma
// pode reter — nenhum usuario sozinho consegue consumir RAM suficiente
// pra derrubar os outros. Com poucos usuarios, cada um ganha ate o teto
// (dlSoftCapMax) igual antes.
func updateDynamicCaps(ram ramInfo, nSessions int) {
	if nSessions < 1 {
		nSessions = 1
	}
	// reserva 50% da RAM disponivel pro conjunto de buffers de download;
	// o resto fica pra SO, goroutines, outros buffers do processo etc.
	budget := int64(float64(ram.Available) * 0.5)
	per := budget / int64(nSessions)
	if per > dlSoftCapMax {
		per = dlSoftCapMax
	}
	if per < dlSoftCapMin {
		per = dlSoftCapMin
	}
	retain := per / 4
	if retain > replayRetainMax {
		retain = replayRetainMax
	}
	if retain < replayRetainMin {
		retain = replayRetainMin
	}
	dynCapMu.Lock()
	changed := dynDLCap != per
	dynDLCap = per
	dynReplayRet = retain
	dynCapMu.Unlock()
	if changed {
		vlog("caps dinamicos: %d sessoes, RAM disp=%.0fMB -> dlCap=%.1fMB replayRetain=%.1fMB",
			nSessions, float64(ram.Available)/(1<<20), float64(per)/(1<<20), float64(retain)/(1<<20))
	}
}

func vlog(f string, a ...any) {
	if *flagVerbose {
		log.Printf(f, a...)
	}
}

// throttledLog limita emissoes por segundos por-chave: em speedtest o
// fluxo gera milhares de frames/s — logar cada um inunda o journal,
// queima CPU e rotaciona logs (perdemos diagnosticos). 4/s e suficiente.
var throttleMu sync.Mutex
var throttleMap = map[string]time.Time{}

func throttledLogEvery(key, msg string, every time.Duration, args ...any) {
	now := time.Now()
	throttleMu.Lock()
	last, ok := throttleMap[key]
	if ok && now.Sub(last) < every {
		throttleMu.Unlock()
		return
	}
	throttleMap[key] = now
	throttleMu.Unlock()
	if len(throttleMap) > 8192 {
		throttleMu.Lock()
		for k := range throttleMap {
			if now.Sub(throttleMap[k]) > time.Minute {
				delete(throttleMap, k)
			}
		}
		throttleMu.Unlock()
	}
	log.Printf(msg, args...)
}

func throttledLog(key, msg string, args ...any) {
	throttledLogEvery(key, msg, 250*time.Millisecond, args...)
}

//────────────────────────── RAM monitoring ──────────────────

type ramInfo struct {
	Total     uint64
	Available uint64
	Used      uint64
	UsedPct   float64
}

func getRAMInfo() ramInfo {
	// Usa /proc/meminfo (MemAvailable) que contabiliza pagina de cache
	// reclamaivel — Sysinfo so olha free+buffer e finge 93% com 7GB livre.
	total := readUintFrom("/proc/meminfo", "MemTotal")
	if total <= 0 {
		total = 11933 << 20 // fallback
	}
	avail := readUintFrom("/proc/meminfo", "MemAvailable")
	if avail < 0 {
		avail = readUintFrom("/proc/meminfo", "MemFree")
	}
	used := total - avail
	if used < 0 {
		used = 0
	}
	return ramInfo{
		Total:     uint64(total),
		Available: uint64(avail),
		Used:      uint64(used),
		UsedPct:   float64(used) / float64(total) * 100,
	}
}

func readUintFrom(path, key string) int64 {
	f, err := os.Open(path)
	if err != nil {
		return -1
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, key+":") {
			var v int64
			fmt.Sscanf(line, key+": %d", &v)
			return v * 1024
		}
	}
	return -1
}

// logRAM loga o uso de RAM periodicamente (chamado pelo reaper).
func logRAM() {
	ram := getRAMInfo()
	var totalDL int64
	registry.mu.Lock()
	sessions := len(registry.m)
	var top []*Session
	for _, s := range registry.m {
		s.mu.Lock()
		totalDL += int64(len(s.dlBuf))
		if s.upInBytes+s.dlInBytes > 0 {
			top = append(top, s)
		}
		s.mu.Unlock()
	}
	registry.mu.Unlock()
	if len(top) > 0 {
		// loga as sessoes mais relevantes: primeiro as com download recente
		// (lastDLAdvance) ou buffer parado grande (congelamento suspeito),
		// para diagnosticar a sessao de speedtest; depois por bytes totais.
		sort.Slice(top, func(i, j int) bool {
			top[i].mu.Lock()
			defer top[i].mu.Unlock()
			top[j].mu.Lock()
			defer top[j].mu.Unlock()
			ri := top[i].lastDLAdvance.UnixNano()
			rj := top[j].lastDLAdvance.UnixNano()
			if ri != rj {
				return ri > rj // mais recém-ativa primeiro
			}
			return len(top[i].dlBuf) > len(top[j].dlBuf)
		})
		show := top
		if len(show) > 6 {
			show = show[:6]
		}
		for _, s := range show {
			s.mu.Lock()
			bal := s.upInBytes - s.upOutBytes
log.Printf("SESSAO %x: UP in=%d out=%d (bal=%d) DL in=%d out=%d empty=%d dlBuf=%d dlReq=%d rpl=%d obs=%d bail=%d dialfail=%d dead=%d resume=%d",
			s.key[:4],
			s.upInBytes, s.upOutBytes, bal,
			s.dlInBytes, s.dlOutBytes, s.dlEmptyHits, len(s.dlBuf),
			s.dlReqCount, s.dlReplayCount, s.dlObsoleteCnt, s.dlBailCount, s.dlDialFailCnt, s.dlDeadCount, s.dlResumeCnt)
			s.mu.Unlock()
		}
	}
	log.Printf("RAM: %.1f%% usada (%.1fMB/%.1fMB) disponivel=%.1fMB sessoes=%d dlBuf_total=%.1fMB",
		ram.UsedPct,
		float64(ram.Used)/(1024*1024),
		float64(ram.Total)/(1024*1024),
		float64(ram.Available)/(1024*1024),
		sessions,
		float64(totalDL)/(1024*1024))
}

// getMemStats retorna estatisticas Go runtime para debug.
func getMemStats() runtime.MemStats {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return m
}

//────────────────────────── cripto (hk.a) ──────────────────

func crypt(data, key []byte, typ byte, seq uint64, resp bool) []byte {
	out := make([]byte, len(data))
	if len(data) == 0 {
		return out
	}
	var seed [30]byte
	copy(seed[0:16], key)
	seed[16] = typ
	binary.BigEndian.PutUint64(seed[17:25], seq)
	if resp {
		seed[25] = 1
	}
	var ks [32]byte
	for i, ctr := 0, uint32(0); i < len(data); ctr++ {
		binary.BigEndian.PutUint32(seed[26:30], ctr)
		ks = sha256.Sum256(seed[:])
		n := len(data) - i
		if n > 32 {
			n = 32
		}
		for j := 0; j < n; j++ {
			out[i+j] = data[i+j] ^ ks[j]
		}
		i += n
	}
	return out
}

// crypt com subslice a partir do BYTE `off` do data original.
// Equivale a crypt(data, key, typ, seq, resp)[off:], porque o keystream
// e posicional (blocos de 32 bytes): para o resume do app 5.0.1 o tail
// entregue deve ser BYTE-IDENTICO ao ciphertext original a partir de off.
func cryptOff(data, key []byte, typ byte, seq uint64, resp bool, off int) []byte {
	if off < 0 {
		off = 0
	}
	if off >= len(data) {
		return []byte{}
	}
	out := make([]byte, len(data)-off)
	if len(out) == 0 {
		return out
	}
	var seed [30]byte
	copy(seed[0:16], key)
	seed[16] = typ
	binary.BigEndian.PutUint64(seed[17:25], seq)
	if resp {
		seed[25] = 1
	}
	var ks [32]byte
	startBlock := off / 32
	startSkip := off % 32
	for i, ctr := 0, uint32(startBlock); i < len(out); ctr++ {
		binary.BigEndian.PutUint32(seed[26:30], ctr)
		ks = sha256.Sum256(seed[:])
		for j := startSkip; j < 32 && i < len(out); j++ {
			out[i] = data[off+i] ^ ks[j]
			i++
		}
		startSkip = 0
	}
	return out
}

type Session struct {
	key  [16]byte
	ip   string // ip de origem do app (para reatachar apos reconexao)
	dest string
	mu   sync.Mutex
	cond *sync.Cond // sinaliza: dados novos / eof / dead / dial ok
	ssh  net.Conn
	dialing    bool
	dead       bool
	// upload (reordenacao por sequencia)
	nextSeq uint64
	pending map[uint64][]byte
	// download: buffer append-only com base absoluta
	dlBuf    []byte
	dlBase   int64 // offset absoluto de dlBuf[0]
	dlEOF    bool
	everData bool // upstream ja produziu >=1 byte nesta conversa
	// mapa esparso indice->trecho absoluto servido (p/ replay e ACK)
	served    map[int64]chunkSpan
	dlPending map[int64]struct{} // ordinais aguardando a vez (minK)

	// cursor ordinal global: proximo indice a servir e onde ele comeca.
	// Ordinais sao CONTADORES de requisicao do app: a 1a janela da
	// conversa ancora o cursor na base que vier (0 em conversa nova,
	// contador acumulado em reconexao) — nao e posicao absoluta.
	anchorIdx int64  // ordinal da 1a janela desta conversa
	nextIdx   int64  // proximo ordinal a tomar a vez (minK)
	nextOff   int64  // cursor: offset do proximo byte a entregar
	anchored bool
	// fila de upload desacoplada: reader nunca espera o upstream
	upQ    chan upItem
	upDone chan struct{} // fechado em kill/reset p/ encerrar o worker
	// geracao do ciclo de conversa: sobe a cada reset (novo upload seq=0)
	epoch       uint64
	lastUpWrite time.Time // ultima escrita bem-sucedida ao upstream
	firstPendAt time.Time // quando o pending ficou nao-vazio (detecao de gap)
	bannerBy    net.Conn  // conexao TCP que entregou o 1o upload do ciclo
	firstUp     []byte    // conteudo desse primeiro upload
	last       time.Time
	// contadores de bytes por ciclo (telemetria de gargalo)
	dlInBytes   int64 // bytes recebidos de sshd (readLoop)
	dlOutBytes  int64 // bytes servidos ao app (getChunk)
	upInBytes   int64 // bytes recebidos do app (pushUpload)
	upOutBytes  int64 // bytes escritos em sshd (upWorker)
	dlEmptyHits int64 // servico vazio (ordinal sem dados no cursor)
	// contadores de diagnostico do pipeline de download
	dlReqCount    int64 // frameDownload recebido do app
	dlReplayCount int64 // resposta = replay de trecho ja servido
	dlObsoleteCnt int64 // ordinal obsoleto (k < nextIdx) servido vazio
	obsGap        int64 // soma de (nextIdx - k) nos obs, p/ diagnosticar desalinhamento
	obsGapN       int64 // n de obs amostrados em obsGap
	dlBailCount   int64 // getChunk baiilou apos espera 3s (nao era minK)
	dlDialFailCnt int64 // ensureSSH() retornou false (dial falhou) -> serviu vazio
	dlDeadCount   int64 // sessao morta/epoch mudou -> serviu vazio
	dlResumeCnt   int64 // type=5 (resume) recebido — nao suportado, resposta vazia
	lastDLAdvance time.Time // ultima vez que bytes reais fluíram ao app (getChunk/getBatch n>0)
}

// resetLocked zera todo o estado do ciclo anterior. chamador segura s.mu.
func (s *Session) resetLocked() {
	s.epoch++
	if s.upDone != nil {
		close(s.upDone)
		s.upDone = nil
	}
	if s.ssh != nil {
		s.ssh.Close()
	}
	s.ssh = nil
	s.dialing = false
	s.nextSeq = 0
	s.pending = map[uint64][]byte{}
	s.dlBuf = nil
	s.dlBase = 0
	s.dlEOF = false
	s.everData = false
	s.served = map[int64]chunkSpan{}
	s.dlPending = map[int64]struct{}{}
	s.anchorIdx = 0
	s.nextIdx = 0
	s.nextOff = 0
	s.anchored = false
	s.bannerBy = nil
	s.firstUp = nil
	s.firstPendAt = time.Time{}
	s.dlInBytes = 0
	s.dlOutBytes = 0
	s.upInBytes = 0
	s.upOutBytes = 0
	s.dlEmptyHits = 0
	s.dlReqCount = 0
	s.dlReplayCount = 0
	s.dlObsoleteCnt = 0
	s.dlBailCount = 0
	s.dlDialFailCnt = 0
	s.dlDeadCount = 0
	s.dlResumeCnt = 0
	s.lastDLAdvance = time.Time{}
	s.cond.Broadcast()
	vlog("sessao %x: estado resetado (epoch=%d)", s.key, s.epoch)
}

// item da fila de upload; gen descarta dados de ciclo velho
type upItem struct {
	gen  uint64
	data []byte
}

type chunkSpan struct{ start, end int64 }

type Registry struct {
	mu sync.Mutex
	m  map[string]*Session
}

var registry = Registry{m: map[string]*Session{}}

func getOrCreateSession(key [16]byte, dest string, ip string) *Session {
	ks := string(key[:])
	registry.mu.Lock()
	defer registry.mu.Unlock()
	if s, ok := registry.m[ks]; ok {
		return s
	}
	s := &Session{
		key:      key,
		ip:       ip,
		dest:     dest,
		pending:   map[uint64][]byte{},
		served:    map[int64]chunkSpan{},
		dlPending: map[int64]struct{}{},
		upQ:       make(chan upItem, 8192),
		last:      time.Now(),
	}
	s.cond = sync.NewCond(&s.mu)
	registry.m[ks] = s
	log.Printf("sessao nova %x (ip=%s)", key, ip)
	return s
}

func (s *Session) dlEOFFlag() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dlEOF
}

func (s *Session) incDialFail() {
	s.mu.Lock()
	s.dlDialFailCnt++
	s.mu.Unlock()
}

func (s *Session) incDLReq() {
	s.mu.Lock()
	s.dlReqCount++
	s.mu.Unlock()
}

func (s *Session) touch() {
	s.mu.Lock()
	s.last = time.Now()
	s.mu.Unlock()
}

// dropConn: a conexao que carregava o ciclo morreu (app desconectou).
func (s *Session) dropConn(c net.Conn) {
	s.mu.Lock()
	if s.bannerBy == c {
		s.bannerBy = nil
		log.Printf("sessao %x: carrier do ciclo saiu (app desconectou)", s.key)
	}
	s.mu.Unlock()
}

func (s *Session) kill(reason string) {
	s.mu.Lock()
	if s.dead {
		s.mu.Unlock()
		return
	}
	s.dead = true
	if s.ssh != nil {
		s.ssh.Close()
	}
	if s.upDone != nil {
		close(s.upDone)
		s.upDone = nil
	}
	s.cond.Broadcast()
	s.mu.Unlock()
	log.Printf("sessao %x encerrada: %s", s.key, reason)

	ks := string(s.key[:])
	registry.mu.Lock()
	delete(registry.m, ks)
	registry.mu.Unlock()
}

// ensureSSH abre o SSH local na primeira necessidade real.
func (s *Session) ensureSSH() bool {
	s.mu.Lock()
	// se SSH morreu (readLoop setou ssh=nil), reseta estado e reconecta
	if s.ssh == nil && !s.dialing && !s.dead {
		s.resetLocked()
	}
	for {
		if s.dead {
			s.mu.Unlock()
			return false
		}
		if s.ssh != nil {
			s.mu.Unlock()
			return true
		}
		if !s.dialing {
			break
		}
		s.cond.Wait() // outro goroutine esta discando
	}
	if s.ssh != nil { // discou enquanto esperavamos
		s.mu.Unlock()
		return true
	}
	s.dialing = true
	s.mu.Unlock()

	var conn net.Conn
	var err error
	if s.dest == "dtproto" && dtAddr != "" {
		conn, err = net.DialTimeout("tcp", dtAddr, 10*time.Second)
	} else {
		conn, err = net.DialTimeout("tcp", s.dest, 10*time.Second)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.dialing = false
	if err != nil {
		s.dead = true
		s.cond.Broadcast()
		log.Printf("sessao %x: falha ao conectar %s: %v", s.key, s.dest, err)
		return false
	}
	s.ssh = conn
	d := make(chan struct{})
	s.upDone = d
	s.cond.Broadcast()
	gen := s.epoch
	go s.readLoop(conn, gen)
	go s.upWorker(conn, gen, d)
	vlog("sessao %x: SSH conectado (%s)", s.key, s.dest)
	return true
}

// upWorker drena a fila de uploads escrevendo ao upstream EM ORDEM.
// Uploads nunca mais bloqueiam o reader das conexoes do app.
func (s *Session) upWorker(conn net.Conn, gen uint64, done chan struct{}) {
	log.Printf("UPWORKER start gen=%d", gen)
	for {
		select {
		case it, ok := <-s.upQ:
			if !ok {
				return
			}
			if it.gen != gen {
				log.Printf("UPWORKER descarta gen antigo (%d != %d)", it.gen, gen)
				continue // dado de ciclo anterior: descarta
			}
			throttledLog(fmt.Sprintf("wr-%x", s.key[:4]), "WRITE->SSHD %d bytes (gen=%d)", len(it.data), gen)
			s.mu.Lock()
			s.upOutBytes += int64(len(it.data))
			s.lastUpWrite = time.Now()
			s.mu.Unlock()
			if _, err := conn.Write(it.data); err != nil {
				log.Printf("sessao %x: erro escrevendo SSH (gen=%d): %v — readLoop reconecta", s.key, gen, err)
				return // readLoop ja setou s.ssh=nil; ensureSSH reconecta
			}
		case <-done:
			return
		}
	}
}

// readLoop alimenta o buffer de download com a saida do upstream.
// gen = epoch capturado no dial; se mudar, este ciclo ficou obsoleto.
func (s *Session) readLoop(conn net.Conn, gen uint64) {
	vlog("sessao %x: readLoop iniciado (gen=%d)", s.key, gen)
	buf := make([]byte, 32*1024)
	for {
		n, err := conn.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			s.mu.Lock()
			if s.epoch != gen {
				s.mu.Unlock()
				return
			}
			// trim agressivo: 75% do cap ATUAL (evita bloquear readLoop durante
			// speedtest). O cap e dinamico (curDLCap) — encolhe conforme mais
			// sessoes se conectam, pra nenhuma sessao sozinha reter RAM demais.
			dlCap := curDLCap()
			var softLimit int64 = dlCap * 3 / 4
			if int64(len(s.dlBuf)) >= softLimit {
				trimmed := s.trimServedLocked()
				if trimmed > 0 {
					vlog("sessao %x: readLoop trim %dB do dlBuf", s.key, trimmed)
				}
			}
			// se dlBuf no hard cap, bloqueia o readLoop (backpressure).
			// NUNCA descartar bytes do stream SSH: descarte = corrupcao =
			// desconexao. A espera e no cond; onAck/trim acordam. Reconsulta
			// curDLCap() a cada volta: se mais sessoes entrarem enquanto
			// esperamos, o cap pode ter encolhido ainda mais.
			for !s.dead && int64(len(s.dlBuf)) >= curDLCap() {
				trimmed := s.trimServedLocked()
				if trimmed > 0 {
					break
				}
				s.cond.Wait()
				if s.epoch != gen || s.dead {
					s.mu.Unlock()
					return
				}
			}
			if s.dead || s.epoch != gen {
				s.mu.Unlock()
				return
			}
			s.dlBuf = append(s.dlBuf, chunk...)
			s.everData = true
			s.dlInBytes += int64(n)
			s.cond.Broadcast()
			s.mu.Unlock()
			vlog("sessao %x: +%d bytes do upstream (gen=%d buffer=%d)", s.key, n, gen, func() int { s.mu.Lock(); defer s.mu.Unlock(); return len(s.dlBuf) }())
		}
		if err != nil {
			s.mu.Lock()
			if s.epoch == gen && !s.dead {
				s.dlEOF = true
				s.ssh = nil // force ensureSSH a reconectar
				s.cond.Broadcast()
			}
			s.mu.Unlock()
			vlog("sessao %x: SSH EOF (epoch %d): %v", s.key, gen, err)
			return
		}
	}
}

// pushUpload insere dados com reordenacao por sequencia.
func (s *Session) pushUpload(seq uint64, data []byte, c net.Conn) bool {
	if len(data) == 0 {
		// upload vazio = ping/keepalive do app: nao ocupa slot na
		// sequencia (o 5.0.0 manda vazio seq=0 antes do hello real!)
		vlog("sessao %x: upload vazio seq=%d ignorado", s.key, seq)
		return true
	}
	// upload seq=0 nao-vazio = inicio de conversa nova (banner JSch/hello).
	// MAS conexoes paralelas podem ter espaco de seq proprio e mandar
	// seq=0 no MEIO de uma conversa saudavel: resetar nesses casos derruba
	// o tunnel em loop (flap). So reseta se o ciclo anterior estiver
	// morto (EOF/dead) ou parado ha mais de 5s.
	s.mu.Lock()
	throttledLog(fmt.Sprintf("up-%x", s.key[:4]), "UP k=%.8x r=%s seq=%d plen=%d %q", s.key[:4], c.RemoteAddr(), seq, len(data), data[:min(len(data), 32)])
	s.upInBytes += int64(len(data))
	progress := s.nextSeq > 0 || s.dlBase > 0 || len(s.served) > 0
	if seq == 0 && progress && len(s.firstUp) > 0 {
		wrote := !s.lastUpWrite.IsZero()
		// SO reseta se o ciclo anterior morreu DE VERDADE (upstream EOF/
		// morto). Carrier saindo e normal em multi-conexao (16 streams
		// abrem/fecham independentemente) — NAO pode causar reset.
		stale := s.dead || s.dlEOF || (wrote && time.Since(s.lastUpWrite) > 10*time.Second)
		if stale {
			log.Printf("sessao %x: reconexao real detectada (eof=%v wrote=%v idle=%.1fs) -> reset",
				s.key[:4], s.dlEOF, wrote, time.Since(s.lastUpWrite).Seconds())
			s.resetLocked()
		} else {
			vlog("sessao %x: seq=0 duplicado ignorado (tunnel vivo, mesma conversa)", s.key)
		}
	}
	if len(s.firstUp) == 0 {
		s.firstUp = append([]byte(nil), data...)
		s.bannerBy = c
	}
	s.mu.Unlock()
	if !s.ensureSSH() {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.dead {
		return false
	}
	if seq < s.nextSeq { // duplicata antiga (retry ja atendido)
		return true
	}
	if seq-s.nextSeq >= maxPendingUp {
		// longe demais da janela: quase sempre sinal de que ja existe um
		// buraco permanente no meio do stream de upload (um frame anterior
		// se perdeu/atrasou numa conexao paralela do speedtest e o app
		// desistiu, pulando pra frente). Descartar SEM avisar o app deixa
		// o hole aberto para sempre: o app acha que entregou (ACK=0) e
		// nunca reenvia o que faltou, e o upload fica morto ate o reaper
		// perceber (~8s) e resetar do zero. Em vez de esperar, resincroniza
		// AGORA: mata o ciclo atual (fecha SSH real, limpa pending/dlBuf) e
		// fecha esta conexao, forcando o app a abrir uma nova ja contra
		// sessao limpa. Corta o tempo de recuperacao de ~8s+reconexao SSH
		// completa para o minimo necessario.
		log.Printf("sessao %x: seq=%d fora da janela [%d,%d) -> hole permanente detectado, resincronizando ja", s.key[:4], seq, s.nextSeq, s.nextSeq+maxPendingUp)
		s.resetLocked()
		return false
	}
	s.pending[seq] = data
	ep := s.epoch
	for {
		d, ok := s.pending[s.nextSeq]
		if !ok {
			break
		}
		delete(s.pending, s.nextSeq)
		// Bloqueante de proposito: byte SSH descartado = stream corrompido
		// = desconecta (speed test!). Backpressure aqui segura o frame do
		// app no socket (TCP) — o app retransmite se precisar.
		s.mu.Unlock()
		s.upQ <- upItem{gen: ep, data: d}
		s.mu.Lock()
		s.lastUpWrite = time.Now()
		s.nextSeq++
	}
	if len(s.pending) == 0 {
		s.firstPendAt = time.Time{}
	} else if s.firstPendAt.IsZero() {
		s.firstPendAt = time.Now()
	}
	return true
}

// getChunk — semantica PROVADA (autenticou e fluiu): o chunk k e uma
// vez unica na sequencia global; vazio responde NA HORA, COMITA (span
// vazio gravado) e avanca o cursor — o app alimenta o JSch com o que
// vier e segue puxando. Fora da vez: espera a VEZ (minK), nunca os
// dados. Replay idempotente p/ re-pedidos; EOF drenado = dead.
// getChunk — modelo POSICIONAL puro: cada ordinal tem posicao unica e
// fixa no stream (ancora + stride). Leitura instantanea sob mutex, SEM
// esperas: dado presente = serve; ausente = comita vazio e o BACKFILL
// no re-pull traz os bytes quando chegarem. Sem turnos => sem deadlock.
// getChunk — modelo CURSOR/TURNOS (semantica A/C provada em producao:
// autenticava e fluiu por horas): cada ordinal entrega, NA SUA VEZ
// (minK), os bytes que estiverem no cursor; vazio comita e avanca a vez;
// parcial sai imediato. Toda saida deleta pending => sem deadlock.
func (s *Session) getChunk(k int64, reqSize int) (data []byte, st byte, dead bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ep := s.epoch
if ref, ok := s.served[k]; ok {
			s.dlReplayCount++
			if ref.start >= s.dlBase && ref.end <= s.dlBase+int64(len(s.dlBuf)) {
				out := make([]byte, ref.end-ref.start)
				copy(out, s.dlBuf[ref.start-s.dlBase:ref.end-s.dlBase])
				vlog("getChunk(%d,%d) -> replay %dB", k, reqSize, len(out))
				return out, 0, false
			}
			return []byte{}, 0, false
		}
		if !s.anchored {
			s.anchored = true
			s.anchorIdx = k
			s.nextIdx = k
			s.nextOff = s.dlBase
		}
		if k < s.nextIdx {
			// ordinal obsoleto (re-pull de janela ja consumida/ACKada/apagada)
			// Hoje devolve VAZIO p/ nunca tomar a vez no cursor atual. Mas no
			// speedtest multi-conexao isso enche o app de vazios e encolhe a
			// janela dele (congelamento). Se o span ainda estiver vivo em
			// served[k] (nao foi trimmado) e estiver DENTRO da janela ja
			// carregada, REENTREGAMOS em vez de vazio — o app recebe os bytes
			// que esperava sem corromper o stream (bytes ja emitidos sob k).
			if ref, still := s.served[k]; still &&
				ref.start >= s.dlBase && ref.end <= s.dlBase+int64(len(s.dlBuf)) {
				s.dlReplayCount++
				out := make([]byte, ref.end-ref.start)
				copy(out, s.dlBuf[ref.start-s.dlBase:ref.end-s.dlBase])
				vlog("getChunk(%d,%d) -> obsoleto reentregue %dB (window)", k, reqSize, len(out))
				return out, 0, false
			}
			s.dlObsoleteCnt++
			s.obsGap += s.nextIdx - k
			s.obsGapN++
			if s.obsGapN%512 == 1 {
				log.Printf("sessao %x: obs k=%d atras nextIdx=%d (gap=%d, avg=%.1f)", s.key[:4], k, s.nextIdx, s.nextIdx-k, float64(s.obsGap)/float64(s.obsGapN))
			}
			return []byte{}, 0, false
		}
	if _, ok := s.dlPending[k]; !ok {
		s.dlPending[k] = struct{}{}
	}
	waitStart := time.Now()
	for {
		if s.dead || s.epoch != ep {
			delete(s.dlPending, k)
			s.dlDeadCount++
			return []byte{}, 0, false
		}
		if s.dlEOF && s.nextOff >= s.dlBase+int64(len(s.dlBuf)) {
			delete(s.dlPending, k)
			log.Printf("sessao %x: pull %d apos EOF do stream -> reset", s.key[:4], k)
			s.resetLocked()
			return []byte{}, 0, false
		}
		minK := int64(-1)
		first := true
		for kk := range s.dlPending {
			if first || kk < minK {
				minK = kk
				first = false
			}
		}
		if k != minK {
			// nunca sera a vez: espera com timeout. Se a conexao que
			// detinha minK morreu, sem timeout travaria TODOS os downloads
			// desta sessao para sempre (sshd enche, app nunca expande a
			// janela SSH → speedtest de upload engasga/congela).
			if time.Since(waitStart) > 3*time.Second {
				delete(s.dlPending, k)
				s.dlBailCount++
				s.cond.Broadcast()
				vlog("sessao %x: getChunk(%d) baiilou apos espera (minK=%d)", s.key[:4], k, minK)
				return []byte{}, 0, false
			}
			s.cond.Wait()
			continue
		}
		start := s.nextOff
		avail := s.dlBase + int64(len(s.dlBuf))
		rem := avail - start
		n := int64(reqSize)
		if rem < n {
			n = rem
		}
		delete(s.dlPending, k)
		s.served[k] = chunkSpan{start: start, end: start + n}
		s.nextIdx = k + 1
		if n > 0 {
			out := make([]byte, n)
			copy(out, s.dlBuf[start-s.dlBase:start-s.dlBase+n])
			s.nextOff = start + n
			s.dlOutBytes += n
			s.lastDLAdvance = time.Now()
			s.cond.Broadcast()
			vlog("getChunk(%d,%d) -> %dB", k, reqSize, n)
			return out, 0, false
		}
		s.dlEmptyHits++
		s.cond.Broadcast()
		return []byte{}, 0, false
	}
}

// getBatch serve N chunks contiguos em uma UNICA aquisicao do mutex,
// eliminando a contencao O(N²) do getChunk individual com 32 conexoes.
// Retorna slices paralelas: datas[i] corresponde a ordinal base+i.
// Chamado SEM s.mu; internamente segura uma vez e drena tudo.
func (s *Session) getBatch(base int64, reqSize int, n int) (datas [][]byte, dead bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ep := s.epoch
	datas = make([][]byte, n)
	for i := 0; i < n; i++ {
		k := base + int64(i)
		// replay se ja servido
		if ref, ok := s.served[k]; ok {
			if ref.start >= s.dlBase && ref.end <= s.dlBase+int64(len(s.dlBuf)) {
				out := make([]byte, ref.end-ref.start)
				copy(out, s.dlBuf[ref.start-s.dlBase:ref.end-s.dlBase])
				datas[i] = out
				continue
			}
			datas[i] = []byte{}
			continue
		}
		if !s.anchored {
			s.anchored = true
			s.anchorIdx = k
			s.nextIdx = k
			s.nextOff = s.dlBase
		}
		if k < s.nextIdx {
			// mesmo pareamento do getChunk: reentrega o span vivo em vez de
			// encher o batch de vazios (janela do app encolhe e congela)
			if ref, still := s.served[k]; still &&
				ref.start >= s.dlBase && ref.end <= s.dlBase+int64(len(s.dlBuf)) {
				out := make([]byte, ref.end-ref.start)
				copy(out, s.dlBuf[ref.start-s.dlBase:ref.end-s.dlBase])
				s.dlReplayCount++
				datas[i] = out
				continue
			}
			datas[i] = []byte{}
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

// trimServedLocked remove do inicio do dlBuf todos os chunks ja servidos.
// Chamado com s.mu HOLD. Retorna bytes removidos (0 = nada servido para trimar).
func (s *Session) trimServedLocked() int64 {
	if len(s.served) == 0 {
		return 0
	}
	// encontra o maior ordinal servido contíguo
	var maxServed int64 = -1
	for k := range s.served {
		if k > maxServed {
			maxServed = k
		}
	}
	if maxServed < 0 {
		return 0
	}
	ref, ok := s.served[maxServed]
	if !ok || ref.end <= s.dlBase {
		return 0
	}
	// corte avancado ate o maior ordinal, MAS retendo curReplayRetain() bytes
	// finais vivos (reentrega). Nao corta span ainda nao reentregavel.
	retain := curReplayRetain()
	cut := ref.end - s.dlBase
	if keep := int64(len(s.dlBuf)) - cut; keep < retain {
		over := retain - keep
		if over >= cut {
			return 0
		}
		cut -= over
	}
	if cut > int64(len(s.dlBuf)) {
		cut = int64(len(s.dlBuf))
	}
	if cut <= 0 {
		return 0
	}
	s.dlBuf = s.dlBuf[cut:]
	s.dlBase += cut
	// limpa served map abaixo do corte
	for i := range s.served {
		if s.served[i].end <= s.dlBase {
			delete(s.served, i)
		}
	}
	return cut
}

func (s *Session) onAck(j int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ref, ok := s.served[j]
	if !ok || ref.end <= s.dlBase {
		return
	}
	cut := ref.end - s.dlBase
	if cut > int64(len(s.dlBuf)) {
		cut = int64(len(s.dlBuf))
	}
	// Mantem a margem replayRetain viva mesmo apos ACK: o app re-puxa
	// ordinais recém-servidos (janela movel), e se o span for cortado
	// aqui, o re-pull vira obs/empty e ENCOLHE a janela do app — o que
	// trava o download (dlBuf cheio) e depois o upload no speedtest.
	// Sempre deixar pelo menos curReplayRetain() bytes finais reentregaveis.
	retain := curReplayRetain()
	if keep := int64(len(s.dlBuf)) - cut; keep < retain {
		over := retain - keep
		if over < cut {
			cut -= over
		} else {
			cut = 0
		}
	}
	if cut > 0 {
		s.dlBuf = s.dlBuf[cut:]
		s.dlBase += cut
	}
	// Remove apenas spans cujos bytes ja foram de fato cortados do buffer.
	// Nao apagar tudo <= j: preserva spans ainda vivos p/ reentrega.
	for i := range s.served {
		if s.served[i].end <= s.dlBase {
			delete(s.served, i)
		}
	}
	s.cond.Broadcast() // acorda produtor pausado pelo cap
}

//─────────────────── fila de resposta ordenada ────────────────────
// Respostas sao COMPUTADAS em paralelo (workers bloqueantes) mas
// ESCRITAS em FIFO estrito de chegada dos pedidos — o cliente nao ve
// nunca uma resposta ultrapassando outra, e o reader nunca trava.

type connOut struct {
	mu     sync.Mutex
	cond   *sync.Cond
	allocN uint64
	nextW  uint64
	ready  map[uint64][]byte
	closed bool
	clogged bool // escrita bloqueada — nao aloca mais slots
}

type pendingFrame struct {
	slot uint64
	data []byte
}

func newConnOut(c net.Conn) *connOut {
	q := &connOut{ready: map[uint64][]byte{}}
	q.cond = sync.NewCond(&q.mu)
	go func() {
		retries := 0
		for {
			q.mu.Lock()
			for q.ready[q.nextW] == nil && !q.closed {
				q.cond.Wait()
			}
			if q.closed {
				q.mu.Unlock()
				return
			}
			// coleta frames consecutivos
			var batch []pendingFrame
			var buf []byte
			for q.ready[q.nextW] != nil {
				d := q.ready[q.nextW]
				batch = append(batch, pendingFrame{q.nextW, d})
				buf = append(buf, d...)
				delete(q.ready, q.nextW)
				q.nextW++
			}
			q.mu.Unlock()

			c.SetWriteDeadline(time.Now().Add(connWriteTO))
			if _, err := c.Write(buf); err != nil {
				// restaura frames na fila
				q.mu.Lock()
				if len(batch) > 0 {
					q.nextW = batch[0].slot
				}
				for _, f := range batch {
					q.ready[f.slot] = f.data
				}
				q.clogged = true
				retries++
				if retries >= 10 {
					q.mu.Unlock()
					log.Printf("connOut write falhou %d vezes — fechando conexao", retries)
					c.Close()
					q.close()
					return
				}
				q.mu.Unlock()
				backoff := time.Duration(1<<uint(retries-1)) * 500 * time.Millisecond
				if backoff > 5*time.Second {
					backoff = 5 * time.Second
				}
				log.Printf("connOut clogged — retry %d/10 em %v", retries, backoff)
				time.Sleep(backoff)
				continue
			}
			// escrita OK — limpa clogged e descarta apenas dados obsoletos
			q.mu.Lock()
			if q.clogged {
				// conexao recuperou — remove slots ja escritos, mas MANTÉM os pendentes
				log.Printf("connOut recuperou — mantendo %d frames pendentes", len(q.ready))
			}
			q.clogged = false
			retries = 0
			q.mu.Unlock()
		}
	}()
	return q
}

func (q *connOut) hasSpace(n int) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.clogged {
		return false
	}
	return q.allocN-q.nextW+uint64(n) <= uint64(maxConnOutQ)
}

// alloc reserva a posicao na ordem (chamar no reader, antes do worker).
// Retorna (slot, true) se OK; (0, false) se fila cheia ou clogged.
func (q *connOut) alloc() (uint64, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.clogged {
		return 0, false
	}
	if q.allocN-q.nextW >= uint64(maxConnOutQ) {
		return 0, false
	}
	s := q.allocN
	q.allocN++
	return s, true
}

// put entrega a resposta ja emoldurada para escrita na sua vez.
func (q *connOut) put(slot uint64, framed []byte) {
	q.mu.Lock()
	q.ready[slot] = framed
	q.cond.Broadcast()
	q.mu.Unlock()
}

func (q *connOut) close() {
	q.mu.Lock()
	if !q.closed {
		q.closed = true
		q.cond.Broadcast()
	}
	q.mu.Unlock()
}

// mkResp monta o frame [status u8][len4BE]+body completo.
func mkResp(status byte, body []byte) []byte {
	out := make([]byte, respHdrSize+len(body))
	out[0] = status
	binary.BigEndian.PutUint32(out[1:5], uint32(len(body)))
	copy(out[respHdrSize:], body)
	return out
}


// prefixConn devolve os primeiros bytes (sniffados na deteccao de protocolo)
// antes de continuar lendo do socket real. Usado quando a conexao e BHTTP.
type prefixConn struct {
	net.Conn
	prefix []byte
}

func (p *prefixConn) Read(b []byte) (int, error) {
	if len(p.prefix) > 0 {
		n := copy(b, p.prefix)
		p.prefix = p.prefix[n:]
		return n, nil
	}
	return p.Conn.Read(b)
}

// sniffBHTTP le o cabecalho do primeiro frame e decide se parece BHTTP.
// Retorna (prefixo consumido, ehBHTTP). Nao consome payload do frame.
// Timeout curto: se o app nao envia nada, assume BHTTP e deixa o loop
// principal decidir (evita mandar conexoes validas para o fallback).
func sniffBHTTP(c net.Conn, timeout time.Duration) ([]byte, bool) {
	c.SetReadDeadline(time.Now().Add(timeout))
	defer c.SetReadDeadline(time.Time{})
	hdr := make([]byte, hdrSize)
	n, err := io.ReadFull(c, hdr)
	got := hdr[:n]
	if err != nil {
		if n == 0 {
			return nil, true // sem dados = assume BHTTP (timeout curto)
		}
		return got, false
	}
	typ := hdr[0]
	if typ > frameResume {
		return got, false
	}
	plen := binary.BigEndian.Uint32(hdr[25:29])
	if typ != frameDownload && plen > maxPayload {
		return got, false
	}
	return got, true
}

// pipeFallback conecta a conexao crua ao destino alternativo (proxy cego).
func pipeFallback(c net.Conn, target string, prefix []byte) {
	throttledLogEvery("fallback", "FALLBACK %s -> %s (%dB iniciais)", 10*time.Second, c.RemoteAddr(), target, len(prefix))
	up, err := net.DialTimeout("tcp", target, 10*time.Second)
	if err != nil {
		log.Printf("fallback: falha conectando %s: %v", target, err)
		return
	}
	defer up.Close()
	if len(prefix) > 0 {
		if _, err := up.Write(prefix); err != nil {
			return
		}
	}
	done := make(chan struct{}, 2)
	go func() { io.Copy(up, c); c.Close(); done <- struct{}{} }()
	go func() { io.Copy(c, up); up.Close(); done <- struct{}{} }()
	<-done
	<-done
}

//────────────────────────── conexao ────────────────────────

func readFull(c net.Conn, n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := io.ReadFull(c, b); err != nil {
		return nil, err
	}
	return b, nil
}

func writeResp(c net.Conn, status byte, body []byte) error {
	hdr := make([]byte, respHdrSize)
	hdr[0] = status
	binary.BigEndian.PutUint32(hdr[1:5], uint32(len(body)))
	if _, err := c.Write(hdr); err != nil {
		return err
	}
	if len(body) > 0 {
		if _, err := c.Write(body); err != nil {
			return err
		}
	}
	return nil
}

func writeRespL(c net.Conn, mu *sync.Mutex, status byte, body []byte) error {
	mu.Lock()
	defer mu.Unlock()
	return writeResp(c, status, body)
}

func clampChunk(n uint32) int {
	if n < 10 {
		n = 10
	}
	if n > 2097152 {
		n = 2097152
	}
	return int(n)
}

func handleConn(c net.Conn, dest string, fallback string) {
	defer c.Close()
	isQUIC := false
	if _, ok := c.(*quicStreamConn); ok {
		isQUIC = true
	}
	if fallback != "" && !isQUIC {
		// peek no primeiro byte para detectar TLS ClientHello (0x16)
		c.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		one := make([]byte, 1)
		n, err := io.ReadFull(c, one)
		c.SetReadDeadline(time.Time{})
		if err == nil && n == 1 && one[0] == 0x16 {
			// TLS ClientHello detectado — faz handshake e processa BHTTP por cima
			log.Printf("CONN %s: TLS ClientHello detectado, handshake...", c.RemoteAddr())
			if tlsServer != nil {
				// re-injeta o byte 0x16 para o TLS ler o record completo
				sc := &prefixConn{Conn: c, prefix: append([]byte(nil), one...)}
				tlsConn := tls.Server(sc, tlsServer)
				if err := tlsConn.Handshake(); err != nil {
					log.Printf("CONN %s: TLS handshake falhou: %v", c.RemoteAddr(), err)
					return
				}
				log.Printf("CONN %s: TLS OK, aguardando BHTTP inside TLS", c.RemoteAddr())
				c = tlsConn
				// cai direto pro loop BHTTP abaixo (sem sniff — TLS já é autenticado)
			} else {
				log.Printf("CONN %s: TLS recebido mas certificado nao configurado, drop", c.RemoteAddr())
				return
			}
		} else if err == nil && n == 1 {
			// primeiro byte lido — le o resto e verifica se é BHTTP
			rest := make([]byte, hdrSize-1)
			c.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
			_, err2 := io.ReadFull(c, rest)
			c.SetReadDeadline(time.Time{})
			if err2 != nil {
				// frame fragmentado: 1o byte chegou (n==1) mas o resto demorou
				// >200ms (latencia alta / CGNAT / 4G). NAO vamos dropar: injetamos
				// o byte ja lido como prefixo e deixamos o loop principal ler o
				// restante com deadline largo (connIdleTO). Se nem o 1o byte for
				// BHTTP plausivel, cai em fallback.
				if one[0] > frameResume {
					pipeFallback(c, fallback, one)
					return
				}
				c = &prefixConn{Conn: c, prefix: append([]byte(nil), one...)}
			} else {
				hdr := append(one, rest...)
				typ := hdr[0]
				if typ > frameResume {
					pipeFallback(c, fallback, hdr)
					return
				}
				plen := binary.BigEndian.Uint32(hdr[25:29])
				if typ != frameDownload && plen > maxPayload {
					pipeFallback(c, fallback, hdr)
					return
				}
				throttledLog(fmt.Sprintf("sniff-%d", hdr[0]), "CONN %s: sniff OK %dB, type=%d", c.RemoteAddr(), len(hdr), hdr[0])
				c = &prefixConn{Conn: c, prefix: append([]byte(nil), hdr...)}
			}
		} else {
			// timeout sem dados — assume BHTTP
			log.Printf("CONN %s: sniff nil (timeout sem dados), assume BHTTP", c.RemoteAddr())
		}
	}
	var sessForDrop *Session
	defer func() {
		if sessForDrop != nil {
			sessForDrop.dropConn(c)
		}
	}()
	if tc, ok := c.(*net.TCPConn); ok {
		tc.SetKeepAlive(true)
		tc.SetKeepAlivePeriod(20 * time.Second)
		tc.SetNoDelay(true)
		_ = tc.SetReadBuffer(256 * 1024)
		_ = tc.SetWriteBuffer(256 * 1024)
	}
	var sess *Session
	var connKey [16]byte // chave DESSA conexao (pode diferir da sessao reatachada)
	haveKey := false
	out := newConnOut(c) // fila FIFO de respostas desta conexao
	defer out.close()
	hdr := make([]byte, hdrSize)
	for {
		c.SetReadDeadline(time.Now().Add(connIdleTO))
		if _, err := io.ReadFull(c, hdr); err != nil {
			return
		}
		typ := hdr[0]
		var key [16]byte
		copy(key[:], hdr[1:17])
		seq := binary.BigEndian.Uint64(hdr[17:25])
		plen := binary.BigEndian.Uint32(hdr[25:29])
		if typ != frameDownload && plen > maxPayload {
			return
		}
		var pay []byte
		if typ != frameDownload && plen > 0 {
			var err error
			if pay, err = readFull(c, int(plen)); err != nil {
				return
			}
		}

		if haveKey && connKey != key {
			return // chave trocou no meio da conexao: invalido
		}
		if !haveKey {
			connKey = key
			haveKey = true
		}
		if sess == nil {
			ra := c.RemoteAddr().String()
			if h, _, err := net.SplitHostPort(ra); err == nil {
				ra = h
			}
			sess = getOrCreateSession(key, dest, ra)
			sessForDrop = sess
		}
		sess.touch()
		if *flagVerbose {
		vlog("frame tipo=%d seq=%d plen=%d", typ, seq, plen)
	}

		switch typ {
		case frameProbe:
			// App 5.0.0 usa 4 tipos de probe:
			//   type 0 (no payload byte 5) = initial echo — 10 bytes
			//   type 1 = upload MTU probe — 10 bytes (app valida length==10)
			//   type 2 = download MTU probe — H bytes (app valida length==H, fill pattern)
			//   type 4 = batch responses probe — N x 1399 bytes (app valida fill pattern)
			dec := crypt(pay, key[:], typ, seq, false)
			probeType := byte(0)
			if len(dec) >= 6 {
				probeType = dec[5]
			}

			if probeType == 4 {
				// ── Batch probe: N respostas de 1399 bytes com fill pattern ──
				numResp := 2
				if len(dec) >= 10 {
					n := int(binary.BigEndian.Uint32(dec[6:10]))
					if n > 0 && n <= 64 {
						numResp = n
					}
				}
				respPayload := make([]byte, 1399)
				n := min(10, len(dec))
				copy(respPayload[:n], dec[:n])
				for i := 10; i < 1399; i++ {
					respPayload[i] = byte(i * 31)
				}
				resp := crypt(respPayload, key[:], typ, seq, true)
				for i := 0; i < numResp; i++ {
					sl, ok := out.alloc()
					if !ok {
						vlog("connOut entupida batch-probe — skip slot %d", i)
						continue
					}
					out.put(sl, mkResp(0, resp))
				}
				vlog("BATCH PROBE: %d responses enviado (dec[5]=4)", numResp)

			} else if probeType == 2 {
				// ── Download MTU probe: gerar H bytes com fill pattern ──
				// App valida: length==H, bytes 10..H-1 == index*31
				hdrSize := 0
				if len(dec) >= 10 {
					hdrSize = int(binary.BigEndian.Uint32(dec[6:10]))
				}
				if hdrSize < 10 {
					hdrSize = 10
				}
				respPayload := make([]byte, hdrSize)
				n := min(10, len(dec))
				copy(respPayload[:n], dec[:n])
				for i := 10; i < hdrSize; i++ {
					respPayload[i] = byte(i * 31)
				}
				resp := crypt(respPayload, key[:], typ, seq, true)
				sl, ok := out.alloc()
				if !ok {
					vlog("connOut entupida dl-probe — skip")
					continue
				}
				out.put(sl, mkResp(0, resp))
				sl, ok = out.alloc()
				if !ok {
					vlog("connOut entupida dl-probe2 — skip")
					continue
				}
				out.put(sl, mkResp(0, resp))

			} else if probeType == 5 {
				// ── Resume capability probe (app 5.0.1) ──
				// App testa suporte a resume com type=0, payload 10B:
				// dec[4]=1, dec[5]=5, dec[6..9]=int 0 (z50.x((byte)5,0)).
				// z50.l((byte)5, resp, 0) exige resp.length==10 com o
				// mesmo padrao. Echo = "accepted"; o app passa a usar
				// type=5 (resume), que o servidor honra recompondo o tail
				// exato do ciphertext via cryptOff (ver case frameResume).
				n := min(10, len(dec))
				respPayload := make([]byte, 10)
				copy(respPayload[:n], dec[:n])
				resp := crypt(respPayload, key[:], typ, seq, true)
				sl, ok := out.alloc()
				if !ok {
					vlog("connOut entupida resume-probe — skip")
					continue
				}
				out.put(sl, mkResp(0, resp))

			} else {
				// ── Initial / Upload probe: echo so primeiros 10 bytes ──
				// App valida length==10 para type 0 e 1 (q51.M: i=10)
				n := min(10, len(dec))
				respPayload := make([]byte, 10)
				copy(respPayload[:n], dec[:n])
				resp := crypt(respPayload, key[:], typ, seq, true)
				sl, ok := out.alloc()
				if !ok {
					vlog("connOut entupida probe — skip")
					continue
				}
				out.put(sl, mkResp(0, resp))
				sl, ok = out.alloc()
				if !ok {
					vlog("connOut entupida probe2 — skip")
					continue
				}
				out.put(sl, mkResp(0, resp))
			}

		case frameUpload:
			dec := crypt(pay, key[:], typ, seq, false)
			// espera breve por espaco na fila (evita descarte silencioso de ACK)
			waitStart := time.Now()
			var sl uint64
			var ok bool
			var pushed bool
			for {
				sl, ok = out.alloc()
				if ok {
					break
				}
				if time.Since(waitStart) > 5*time.Second {
					log.Printf("connOut entupida upload seq=%d — push sem ack", seq)
					sess.pushUpload(seq, dec, c)
					pushed = true
					break
				}
				time.Sleep(50 * time.Millisecond)
			}
			if !pushed {
				if !sess.pushUpload(seq, dec, c) {
					out.put(sl, mkResp(1, nil))
					return
				}
				out.put(sl, mkResp(0, nil))
			}

		case frameDownload:
			sess.incDLReq()
			// espera breve por espaco na fila (evita descarte silencioso de download)
			waitStart := time.Now()
			var sl uint64
			var allocOK bool
			for {
				sl, allocOK = out.alloc()
				if allocOK {
					break
				}
if time.Since(waitStart) > 10*time.Second {
				throttledLog(fmt.Sprintf("queue-%x", sess.key[:4]), "connOut entupida download seq=%d segurando resposta (nao descarta)", seq)
			}
			time.Sleep(50 * time.Millisecond)
			}
			if allocOK {
				go func(sr *Session, kk [16]byte, sq uint64, csz int, slot uint64) {
					if !sr.ensureSSH() {
						// dial/tempesta falhou: responde VAZIO (status 0) — nunca
						// status=1 nem fechar aqui, senao a janela do app fica
						// curta e ele derruba o canal SSH (congelamento).
						sr.incDialFail()
						out.put(slot, mkResp(0, crypt(nil, kk[:], frameDownload, sq, true)))
						return
					}
					data, st, dead := sr.getChunk(int64(sq), csz)
					if dead {
						// sessao resetada/morta a meio: resposta vazia preserva
						// a contagem da janela; próximo ordinal re-ancora.
						out.put(slot, mkResp(0, crypt(nil, kk[:], frameDownload, sq, true)))
						return
					}
					out.put(slot, mkResp(st, crypt(data, kk[:], frameDownload, sq, true)))
				}(sess, key, seq, clampChunk(plen), sl)
			}

		case frameBatch:
			dec := crypt(pay, key[:], typ, seq, false)
			vlog("PAYLOAD_BATCH hex=%x", dec)
			if len(dec) != 6 {
				return
			}
			cs := clampChunk(binary.BigEndian.Uint32(dec[0:4]))
			cnt := int(binary.BigEndian.Uint16(dec[4:6]))
			if cnt == 0 || cnt > maxBatch {
				return
			}
			throttledLog(fmt.Sprintf("batch-%x", sess.key[:4]), "BATCH k=%.8x r=%s ini=%d cnt=%d cs=%d", sess.key[:4], c.RemoteAddr(), seq, cnt, cs)
			// espera espaco na fila (nao fecha conexao)
			deadline := time.Now().Add(15 * time.Second)
			for !out.hasSpace(cnt) && time.Now().Before(deadline) {
				time.Sleep(100 * time.Millisecond)
			}
			if !out.hasSpace(cnt) {
				log.Printf("BATCH k=%.8x cnt=%d: fila cheia apos 15s — app retry em outra conexao", sess.key[:4], cnt)
				continue
			}
			slots := make([]uint64, cnt)
			allOk := true
			for i := range slots {
				sl, ok := out.alloc()
				if !ok {
					log.Printf("BATCH k=%.8x: alloc falhou slot %d", sess.key[:4], i)
					allOk = false
					break
				}
				slots[i] = sl
			}
			if !allOk {
				log.Printf("BATCH k=%.8x: alloc incompleto — skip", sess.key[:4])
				continue
			}
			go func(sr *Session, kk [16]byte, sq uint64, csz, n int, slots []uint64) {
				if !sr.ensureSSH() {
					sr.incDialFail()
					// mesmo pacto do download: janela nunca fica curta
					for i, sl := range slots {
						out.put(sl, mkResp(0, crypt(nil, kk[:], frameBatch, uint64(sq)+uint64(i), true)))
					}
					return
				}
				t0 := time.Now()
				datas, dead := sr.getBatch(int64(sq), csz, n)
				if dead {
					log.Printf("BATCH k=%.8x ini=%d: dead no batch apos %.1fs", sr.key[:4], sq, time.Since(t0).Seconds())
					for j := len(datas); j < n; j++ {
						out.put(slots[j], mkResp(0, crypt(nil, kk[:], frameBatch, uint64(sq)+uint64(j), true)))
					}
					return
				}
				for i, data := range datas {
					out.put(slots[i], mkResp(0, crypt(data, kk[:], frameBatch, uint64(sq)+uint64(i), true)))
				}
				throttledLog(fmt.Sprintf("bdone-%x", sr.key[:4]), "BATCH k=%.8x ini=%d cnt=%d completo em %.2fs (getBatch)", sr.key[:4], sq, n, time.Since(t0).Seconds())
			}(sess, key, seq, cs, cnt, slots)

		case frameAck:
			sess.onAck(int64(seq))
			sl, ok := out.alloc()
			if !ok {
				vlog("connOut entupida ack — skip")
				continue
			}
			out.put(sl, mkResp(0, nil))

		case frameResume:
			// App 5.0.1 retoma um ordinal parcialmente lido (sk): envia
			// type=5, seq=j e payload=4 bytes (offset i5, cryptado com
			// typ=5,seq=j,resp=false). O corpo esperado deve ser o tail
			// EXATO do ciphertext original da resposta de download —
			// crypt(data,key,frameDownload,seq,true)[i5:]. Como o keystream
			// e posicional, cryptOff recompoe o tail a partir do plaintext
			// ainda vivo em dlBuf (span de served[seq]).
			var off int64
			if len(pay) >= 4 {
				dec := crypt(pay[:4], key[:], frameResume, seq, false)
				off = int64(binary.BigEndian.Uint32(dec))
			}
			sess.mu.Lock()
			ref, ok := sess.served[int64(seq)]
			var tail []byte
			if ok && ref.start >= sess.dlBase && ref.end <= sess.dlBase+int64(len(sess.dlBuf)) {
				pl := sess.dlBuf[ref.start-sess.dlBase : ref.end-sess.dlBase]
				tail = cryptOff(pl, key[:], frameDownload, seq, true, int(off))
			}
			sess.dlResumeCnt++
			sess.mu.Unlock()
			if ok && tail != nil {
				vlog("RESUME k=%.8x seq=%d off=%d tail=%dB (recompoe ciphertext original)", sess.key[:4], seq, off, len(tail))
				sl, ok := out.alloc()
				if !ok {
					vlog("connOut entupida resume-tail — skip")
					continue
				}
				out.put(sl, mkResp(0, tail))
			} else {
				// Sem span vivo nao da para recompor o tail exato: responde
				// status=1 "download sequence pending" (PLANETEXT — o app
				// compara new String(flVar.b) em m()) e o q() re-puxa o
				// ordinal inteiro via type=2 (replay do span, se vivo).
				vlog("RESUME k=%.8x seq=%d off=%d indisponivel — pending", sess.key[:4], seq, off)
				sl, ok := out.alloc()
				if !ok {
					vlog("connOut entupida resume-pending — skip")
					continue
				}
				out.put(sl, mkResp(1, []byte("download sequence pending")))
			}

		default:
			return // tipo desconhecido: descarta conexao
		}
	}
}

//────────────────────────── reaper ─────────────────────────

func reaper() {
	ramTicker := 0
	for range time.Tick(1 * time.Second) {
		ramTicker++
		// RAM lida UMA VEZ por tick (nao mais por sessao — com muitas
		// sessoes simultaneas, ler /proc/meminfo por sessao a cada tick
		// era CPU/IO desperdicado e ficava pior exatamente quando mais
		// precisavamos de folga).
		ram := getRAMInfo()
		// log RAM a cada 30 segundos (30 ticks × 1s)
		if ramTicker >= 30 {
			ramTicker = 0
			logRAM()
			if ram.UsedPct > 80 {
				log.Printf("RAM > 80%% — forçando GC")
				runtime.GC()
			}
		}
		registry.mu.Lock()
		nSessions := len(registry.m)
		type sinfo struct {
			s       *Session
			dlBytes int64
			last    time.Time
		}
		var stale, gapStuck, dlFrozen []*Session
		var candidates []sinfo // candidatas a trim por excesso de dlBuf (ordinario + pressao de RAM)
		for _, s := range registry.m {
			s.mu.Lock()
			if time.Since(s.last) > *flagIdle {
				stale = append(stale, s)
			}
			if !s.firstPendAt.IsZero() && s.bannerBy != nil &&
				time.Since(s.firstPendAt) > 2*time.Second &&
				time.Since(s.lastUpWrite) > 2*time.Second {
				gapStuck = append(gapStuck, s)
			}
			// deteccao de CONGELAMENTO de download: o app encolheu a janela
			// apos uso intenso (speedtest) e parou de puxar sem ter
			// encerrado — dlBuf fica parado (ou ja foi trimmado) e o cursor
			// nao avanca; o tunnel parece "cheio". Forcamos um reset limpo
			// (banner se reancora) — mesmo tratamento do GAP de upload.
			// Sinais: ja serviu dados neste ciclo, nenhum byte de download
			// fluindo ao app ha >=20s, E o upload tambem parou (evita matar
			// um speedtest que apenas esta na fase de upload).
			if !s.dead && s.everData && !s.lastDLAdvance.IsZero() &&
				(s.dlOutBytes > 0 || len(s.dlBuf) > 0) &&
				time.Since(s.lastDLAdvance) >= 8*time.Second &&
				(s.lastUpWrite.IsZero() || time.Since(s.lastUpWrite) >= 8*time.Second) {
				dlFrozen = append(dlFrozen, s)
			}
			if !s.dead && len(s.served) > 0 && len(s.dlBuf) > 0 {
				candidates = append(candidates, sinfo{s, int64(len(s.dlBuf)), s.last})
			}
			s.mu.Unlock()
		}
		registry.mu.Unlock()

		// recalcula os caps dinamicos com o numero de sessoes vivo ANTES
		// de matar as "stale" (elas ja vao cair no proximo tick, mas nao
		// custa nada considerar o numero atual agora mesmo).
		updateDynamicCaps(ram, nSessions)
		dlCap := curDLCap()

		for _, s := range stale {
			s.kill("ociosa")
		}
		for _, s := range gapStuck {
			log.Printf("sessao %x: GAP de upload travado (%d pendentes ha %.0fs) -> reset p/ reconexao limpa",
				s.key[:4], len(s.pending), time.Since(s.firstPendAt).Seconds())
			s.resetLocked()
		}
		for _, s := range dlFrozen {
			s.mu.Lock()
			log.Printf("sessao %x: CONGELAMENTO de download (obs=%d empty=%d dlBuf=%dKB parado ha %.0fs) -> reset p/ reconexao limpa",
				s.key[:4], s.dlObsoleteCnt, s.dlEmptyHits, len(s.dlBuf)/1024, time.Since(s.lastDLAdvance).Seconds())
			s.resetLocked()
			s.mu.Unlock()
		}

		// limpeza de dlBuf: sempre tenta cortar sessoes acima de 50% do
		// cap ATUAL (dinamico); dlBuf so cresce por dados ja SERVIDOS
		// (span em s.served) mas ainda nao trimados — trimar isso e
		// sempre seguro (nao apaga nada que o app ainda vai pedir pela
		// primeira vez, so libera replay antigo alem da margem de retain).
		// Sob pressao de RAM (>70%), ordena por "menos recentemente
		// ativa primeiro" e corta MAIS agressivamente, priorizando quem
		// esta parada ha mais tempo em vez de mexer em todo mundo de
		// uma vez (evita engasgar sessoes saudaveis e ativas junto com
		// zumbis).
		ordinaryThreshold := dlCap / 2
		var toTrim []*Session
		if ram.UsedPct > 70 {
			sort.Slice(candidates, func(i, j int) bool { return candidates[i].last.Before(candidates[j].last) })
			pressureThreshold := dlCap / 8
			if pressureThreshold < 4<<20 {
				pressureThreshold = 4 << 20
			}
			for _, ci := range candidates {
				if ci.dlBytes > pressureThreshold {
					toTrim = append(toTrim, ci.s)
				}
			}
		} else {
			for _, ci := range candidates {
				if ci.dlBytes > ordinaryThreshold {
					toTrim = append(toTrim, ci.s)
				}
			}
		}
		for _, s := range toTrim {
			s.mu.Lock()
			cut := s.trimServedLocked()
			s.mu.Unlock()
			if cut > 0 {
				log.Printf("sessao %x: reaper limpou %dKB do dlBuf (%dKB -> %dKB)",
					s.key[:4], cut/1024, (cut+int64(len(s.dlBuf)))/1024, len(s.dlBuf)/1024)
				s.cond.Broadcast()
			}
		}
	}
}

//────────────────────────── QUIC TLS ───────────────────────────

func generateSelfSignedCert() (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		NotBefore:    time.Now(),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	derBytes, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: derBytes})
	keyDER, _ := x509.MarshalECPrivateKey(key)
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return tls.X509KeyPair(certPEM, keyPEM)
}

// quicToNetConn envolve um quic.Stream como net.Conn para compatibilidade
// com handleConn (TCP timeout, keepalive, etc).
type quicStreamConn struct {
	*quic.Stream
	remoteAddr net.Addr
}

func (q *quicStreamConn) RemoteAddr() net.Addr  { return q.remoteAddr }
func (q *quicStreamConn) LocalAddr() net.Addr    { return &net.UDPAddr{} }
func (q *quicStreamConn) SetReadDeadline(t time.Time) error  { return q.Stream.SetReadDeadline(t) }
func (q *quicStreamConn) SetWriteDeadline(t time.Time) error { return q.Stream.SetWriteDeadline(t) }
func (q *quicStreamConn) SetDeadline(t time.Time) error {
	q.Stream.SetReadDeadline(t)
	return q.Stream.SetWriteDeadline(t)
}

//────────────────────────── main ───────────────────────────

func main() {
	flag.Parse()
	log.SetFlags(log.LstdFlags)
	log.SetOutput(os.Stderr)

	// modo DTProto (CloudJF SSH_BHTTP): backend proprio, sem SSH
	if *flagTo == "dtproto" || *flagStatic == "dtproto" {
		dtpTunName = *flagTun
		dtpLoadUsers(dtpUsersFile)
		if err := dtpEnsure(); err != nil {
			log.Printf("dtproto: aviso: %v", err)
		}
		var lerr error
		dtLn, lerr = net.Listen("tcp", "127.0.0.1:0")
		if lerr != nil {
			log.Fatalf("dtproto: listener interno: %v", lerr)
		}
		dtAddr = dtLn.Addr().String()
		go func() {
			for {
				c, err := dtLn.Accept()
				if err != nil {
					log.Printf("dtproto: accept: %v", err)
					return
				}
				go serveDTProto(c)
			}
		}()
		*flagTo = "dtproto"
	} else {
		// aceita "--to 22" (so porta, padrao do painel) ou "host:porta"
		if _, _, err := net.SplitHostPort(*flagTo); err != nil {
			*flagTo = net.JoinHostPort("127.0.0.1", *flagTo)
		}
	}

	if *flagStatic != "" && *flagStatic != "dtproto" {
		*flagTo = *flagStatic
	}
	listenAddr := *flagBind
	if listenAddr == "" {
		if *flagPort <= 0 || *flagPort > 65535 {
			fmt.Fprintln(os.Stderr, "use: bhttpssh --port <PORTA> [--to HOST:PORTA] | --bind IP:PORTA")
			os.Exit(2)
		}
		listenAddr = fmt.Sprintf(":%d", *flagPort)
	}
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("nao foi possivel escutar na porta %d: %v", *flagPort, err)
	}
	log.Printf("bhttpssh ativo na porta %d -> %s", *flagPort, *flagTo)
	if dtLn != nil {
		log.Printf("bhttpssh: modo DTProto (CloudJF) ativo via %s", dtAddr)
	}
	go reaper()

	// ── TLS server config (para TLS-inspect na porta 80) ──
	{
		var tlsCert tls.Certificate
		var err error
		if *flagTLSCert != "" && *flagTLSKey != "" {
			tlsCert, err = tls.LoadX509KeyPair(*flagTLSCert, *flagTLSKey)
		} else {
			tlsCert, err = generateSelfSignedCert()
		}
		if err != nil {
			log.Fatalf("TLS: erro carregando certificado: %v", err)
		}
		tlsServer = &tls.Config{
			Certificates: []tls.Certificate{tlsCert},
			NextProtos:   []string{"bhttp-ssh"},
		}
		log.Printf("TLS-inspect ativo (self-signed cert gerado)")
	}

	// ── QUIC listener (opcional) ──
	if *flagQUICPort > 0 {
		quicAddr := fmt.Sprintf(":%d", *flagQUICPort)
		quicLn, err := quic.ListenAddr(quicAddr, tlsServer, &quic.Config{
			MaxIdleTimeout:        300 * time.Second,
			KeepAlivePeriod:       30 * time.Second,
			MaxIncomingStreams:     100,
			MaxIncomingUniStreams:  0,
		})
		if err != nil {
			log.Fatalf("QUIC: erro escutando em %s: %v", quicAddr, err)
		}
		log.Printf("bhttpssh QUIC ativo em %s -> %s", quicAddr, *flagTo)
		go func() {
			for {
				qconn, err := quicLn.Accept(context.Background())
				if err != nil {
					log.Printf("QUIC accept: %v", err)
					continue
				}
				go func(qconn *quic.Conn) {
					for {
						stream, err := qconn.AcceptStream(context.Background())
						if err != nil {
							return
						}
						sc := &quicStreamConn{Stream: stream, remoteAddr: qconn.RemoteAddr()}
						log.Printf("CONN %s: QUIC stream aberto", sc.remoteAddr)
						go handleConn(sc, *flagTo, *flagFallback)
					}
				}(qconn)
			}
		}()
	}

	for {
		c, err := ln.Accept()
		if err != nil {
			log.Fatalf("accept: %v", err)
		}
		go handleConn(c, *flagTo, *flagFallback)
	}
}
