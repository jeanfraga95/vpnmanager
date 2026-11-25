package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// proxygo — reescrita em Go do proxy CloudJF da porta 8080.
// Mantém o protocolo bruto (não usa net/http nem frames WebSocket):
// 101 aos 50ms, --auto-200, filtro de decoys até o banner SSH,
// CONNECT/SOCKS4/5, TLS/SNI e DPI dos primeiros bytes.

type Config struct {
	Port         int
	Bind         string
	ToPort       int
	ToAddr       string
	Response     string
	DPI          bool
	DPIBytes     int
	DPIChunk     int
	DPIDelayMS   int
	Legacy101    bool
	Immediate101 bool
	WaitMagic    bool
	Keepalive    bool
	SocksLocal   bool
	TLSHost      string
	TLSPort      int
	SNIAllow     string
	AuthToken    string
}

type State uint8

const (
	stInit State = iota
	stWSMagic
	stSocks5Methods
	stSocks5Auth
	stSocks5Req
	stSocks4Req
	stTLS
	stRelay
)

type proxyConn struct {
	cfg *Config
	cli net.Conn
	rmt net.Conn

	state       State
	sent101     bool
	bannerSent  bool
	inControl   bool
	rawTunnel   bool
	magicReady  bool
	delayed     bool
	fragIn      int
	fragOut     int
	clientBuf   []byte // pendente cliente -> remoto (antes do relay)
	pendingSSH  []byte // carry do gate "SSH-" fragmentado
	reply       []byte // resposta enfileirada para o cliente (CONNECT/SOCKS)
	pending     []byte // ClientHello enfileirado para o remoto
	writeMu     sync.Mutex
	closeOnce   sync.Once
	magicTimer  *time.Timer
}

func main() {
	cfg := parseFlags()
	addr := net.JoinHostPort(cfg.Bind, strconv.Itoa(cfg.Port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("proxygo: listen %s: %v", addr, err)
	}
	defer ln.Close()
	log.Printf("proxygo: escutando %s -> %s:%d (auto200=%v dpi=%v)",
		addr, cfg.ToAddr, cfg.ToPort, !cfg.WaitMagic, cfg.DPI)

	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("proxygo: accept: %v", err)
			continue
		}
		go handleConn(c, cfg)
	}
}

func parseFlags() *Config {
	port := flag.Int("port", 80, "porta de escuta")
	bind := flag.String("bind", "0.0.0.0", "endereco de escuta")
	toPort := flag.Int("to-port", 22, "porta SSH destino")
	to := flag.String("to", "", "destino numerico (alias de --to-port) ou host:porta")
	response := flag.String("response", "OK", "texto das respostas 101/200")
	noDPI := flag.Bool("no-dpi", false, "desliga fragmentacao anti-DPI")
	legacy101 := flag.Bool("legacy-101", false, "101 basico sem headers")
	noImmediate := flag.Bool("no-immediate-101", false, "nao envia 101 apos 50ms")
	auto200 := flag.Bool("auto-200", false, "envia 200 imediatamente")
	socksLocal := flag.Bool("socks-force-local", false, "forca CONNECT/SOCKS para 127.0.0.1:<to-port>")
	noKeepalive := flag.Bool("no-keepalive", false, "desliga TCP keepalive")
	tlsTarget := flag.String("tls-target", "127.0.0.1:443", "destino do ClientHello")
	sniAllow := flag.String("sni-allow", "", "SNI permitido")
	token := flag.String("token", "", "token opcional")
	dpiBytes := flag.Int("dpi-bytes", 48, "bytes iniciais fragmentados")
	dpiChunk := flag.Int("dpi-chunk", 8, "tamanho do chunk DPI")
	dpiDelay := flag.Int("dpi-delay", 12, "delay DPI em ms")
	flag.Parse()

	c := &Config{
		Port:         *port,
		Bind:         *bind,
		ToPort:       *toPort,
		ToAddr:       "127.0.0.1",
		Response:     *response,
		DPI:          !*noDPI,
		DPIBytes:     *dpiBytes,
		DPIChunk:     *dpiChunk,
		DPIDelayMS:   *dpiDelay,
		Legacy101:    *legacy101,
		Immediate101: !*noImmediate,
		WaitMagic:    !*auto200,
		Keepalive:    !*noKeepalive,
		SocksLocal:   *socksLocal,
		TLSHost:      "127.0.0.1",
		TLSPort:      443,
		SNIAllow:     *sniAllow,
		AuthToken:    *token,
	}
	if h, p, err := net.SplitHostPort(*tlsTarget); err == nil {
		c.TLSHost = h
		if n, err := strconv.Atoi(p); err == nil {
			c.TLSPort = n
		}
	}
	if *to != "" {
		if h, p, err := net.SplitHostPort(*to); err == nil {
			c.ToAddr = h
			if n, err := strconv.Atoi(p); err == nil {
				c.ToPort = n
			}
		} else if n, err := strconv.Atoi(*to); err == nil {
			c.ToPort = n
		}
	}
	if c.DPIChunk < 1 {
		c.DPIChunk = 8
	}
	if c.DPIBytes < 0 {
		c.DPIBytes = 0
	}
	if c.Port < 1 || c.Port > 65535 || c.ToPort < 1 || c.ToPort > 65535 {
		log.Fatalf("proxygo: porta fora do intervalo 1..65535")
	}
	return c
}

func handleConn(c net.Conn, cfg *Config) {
	p := &proxyConn{
		cfg:     cfg,
		cli:     c,
		state:   stInit,
		fragIn:  cfg.DPIBytes,
		fragOut: cfg.DPIBytes,
	}
	defer func() {
		if !p.delayed {
			p.close()
		}
	}()
	setSockOpts(c, cfg.Keepalive)

	buf := make([]byte, 8192)
	c.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
	n, err := c.Read(buf)
	if n > 0 {
		p.clientBuf = append(p.clientBuf, buf[:n]...)
	}
	if err != nil {
		ne, timeout := err.(net.Error)
		if timeout && ne.Timeout() && p.state == stInit && cfg.Immediate101 &&
			cfg.AuthToken == "" && !p.sent101 && n == 0 {
			// Cliente silenciou: 101 exato do proxy original e passa a
			// aguardar dados. Não processa ST_WS_MAGIC agora (o C só responde
			// ao próximo read callback).
			p.sendImmediate101()
			p.sent101 = true
			p.state = stWSMagic
			p.armMagicTimer()
		} else if n == 0 {
			return
		}
		// Se n > 0, processa os bytes recebidos mesmo com erro de leitura.
	}
	c.SetReadDeadline(time.Time{})

	if len(p.clientBuf) > 0 {
		if !p.processPreRelay() {
			return
		}
	}

	for {
		n, err = c.Read(buf)
		if n > 0 {
			if p.rmt != nil {
				b := append(p.clientBuf, buf[:n]...)
				p.clientBuf = nil
				if e := p.forwardClient(b); e != nil {
					return
				}
			} else {
				p.clientBuf = append(p.clientBuf, buf[:n]...)
				if !p.processPreRelay() {
					return
				}
			}
		}
		if err != nil {
			return
		}
	}
}

func (p *proxyConn) processPreRelay() bool {
	b := p.clientBuf
	switch p.state {
	case stInit:
		if len(b) == 0 {
			return true
		}
		switch {
		case b[0] == 0x05:
			p.state = stSocks5Methods
		case b[0] == 0x04:
			p.state = stSocks4Req
		case b[0] == 0x16 && len(b) > 1 && b[1] == 0x03:
			p.state = stTLS
		case startsHTTP(b):
			return p.handleHTTP(b)
		default:
			// Fluxo legado: cliente falou primeiro sem HTTP/SOCKS/TLS.
			if !p.sent101 {
				p.sendWS101("")
				p.sent101 = true
			}
			p.state = stWSMagic
			p.armMagicTimer()
			return p.processWSMagic()
		}
		return p.processPreRelay()

	case stSocks5Methods:
		return p.socks5Methods(b)
	case stSocks5Auth:
		return p.socks5Auth(b)
	case stSocks5Req:
		return p.socks5Request(b)
	case stSocks4Req:
		return p.socks4Request(b)
	case stTLS:
		return p.handleTLS(b)
	case stWSMagic:
		return p.processWSMagic()
	}
	return true
}

func (p *proxyConn) handleHTTP(b []byte) bool {
	end, term := findHeaderEnd(b)
	if end < 0 {
		if len(b) > 8192 {
			p.sendDecoy()
			return false
		}
		return true
	}
	consumed := end + term
	hdr := string(b[:consumed])
	line := firstLine(hdr)

	if strings.HasPrefix(line, "CONNECT ") {
		return p.handleConnect(line, b, consumed)
	}
	if !tokenOK(hdr, line, p.cfg.AuthToken) {
		p.send403()
		return false
	}
	if strings.Contains(strings.ToLower(hdr), "npv-x") {
		p.magicReady = true
	}

	if p.cfg.Immediate101 && p.sent101 {
		// O app envia um preâmbulo HTTP "quebrado" depois do 101 imediato.
		// O C descarta o bloco inteiro e processa o que sobrou.
		p.clientBuf = append([]byte(nil), b[consumed:]...)
		p.state = stWSMagic
		p.armMagicTimer()
		return p.processWSMagic()
	}

	hasWS := strings.Contains(strings.ToLower(hdr), "upgrade:") &&
		strings.Contains(strings.ToLower(hdr), "websocket")
	if !hasWS {
		p.sendDecoy()
		return false
	}
	if !p.sent101 {
		p.sendWS101(hdr)
		p.sent101 = true
	}
	p.clientBuf = append([]byte(nil), b[consumed:]...)
	p.state = stWSMagic
	p.armMagicTimer()
	return p.processWSMagic()
}

func (p *proxyConn) handleConnect(line string, b []byte, consumed int) bool {
	if !tokenOK(string(b[:consumed]), line, p.cfg.AuthToken) {
		p.send403()
		return false
	}
	fields := strings.Fields(line)
	if len(fields) < 2 {
		p.sendDecoy()
		return false
	}
	target := fields[1]
	colon := strings.LastIndexByte(target, ':')
	if colon < 0 {
		p.sendDecoy()
		return false
	}
	host := target[:colon]
	port, err := strconv.Atoi(target[colon+1:])
	if err != nil || port < 1 || port > 65535 {
		p.sendDecoy()
		return false
	}
	p.reply = []byte("HTTP/1.1 200 Connection Established\r\nProxy-Agent: nginx\r\n\r\n")
	p.clientBuf = append([]byte(nil), b[consumed:]...)
	if p.cfg.SocksLocal {
		host, port = p.cfg.ToAddr, p.cfg.ToPort
	}
	return p.startRelay(host, port, true)
}

func (p *proxyConn) processWSMagic() bool {
	b := p.clientBuf
	if !p.cfg.WaitMagic { // --auto-200: modo de produção
		if i := bytes.Index(b, []byte("npv-x")); i >= 0 {
			if i == 0 && len(b) >= 5 {
				b = b[5:]
			} else if i > 0 && i < 64 && i+5 <= len(b) {
				b = append(append([]byte(nil), b[:i]...), b[i+5:]...)
			}
		}
		p.clientBuf = b
		p.send200()
		return p.startRelay(p.cfg.ToAddr, p.cfg.ToPort, false)
	}

	// Modo híbrido: 200 só após npv-x (header/payload) ou banner SSH-.
	if p.magicReady {
		p.magicReady = false
		p.send200()
		return p.startRelay(p.cfg.ToAddr, p.cfg.ToPort, false)
	}
	if i := bytes.Index(b, []byte("SSH-")); i >= 0 {
		p.clientBuf = append([]byte(nil), b[i:]...)
		p.send200()
		return p.startRelay(p.cfg.ToAddr, p.cfg.ToPort, false)
	}
	if i := bytes.Index(b, []byte("npv-x")); i >= 0 {
		end := i + 5
		if end > len(b) {
			end = len(b)
		}
		// O C descarta tudo até o fim do npv-x, inclusive um SSH- no mesmo pacote.
		p.clientBuf = append([]byte(nil), b[end:]...)
		p.send200()
		return p.startRelay(p.cfg.ToAddr, p.cfg.ToPort, false)
	}
	// Decoy descartado sem 200. Não aplica aqui o gate do banner: isso
	// acontecerá no connect remoto (event_cb no C).
	p.clientBuf = p.stripWSControl(b)
	return true
}

func (p *proxyConn) socks5Methods(b []byte) bool {
	if len(b) < 2 {
		return true
	}
	nm := int(b[1])
	if nm < 1 || nm > 255 || len(b) < 2+nm {
		return true
	}
	noauth, userpass := false, false
	for _, m := range b[2 : 2+nm] {
		if m == 0x00 {
			noauth = true
		}
		if m == 0x02 {
			userpass = true
		}
	}
	if p.cfg.AuthToken != "" {
		noauth = false
	}
	p.clientBuf = append([]byte(nil), b[2+nm:]...)
	if !noauth && !userpass {
		p.writeClient([]byte{0x05, 0xff})
		p.closeAfterWrite()
		return false
	}
	if noauth {
		p.writeClient([]byte{0x05, 0x00})
		p.state = stSocks5Req
	} else {
		p.writeClient([]byte{0x05, 0x02})
		p.state = stSocks5Auth
	}
	return p.processPreRelay()
}

func (p *proxyConn) socks5Auth(b []byte) bool {
	if len(b) < 2 || b[0] != 0x01 {
		p.writeClient([]byte{0x05, 0xff})
		p.closeAfterWrite()
		return false
	}
	ulen := int(b[1])
	need := 2 + ulen
	if len(b) < need+1 {
		return true
	}
	plen := int(b[need])
	need2 := need + 1 + plen
	if len(b) < need2 {
		return true
	}
	user := string(b[2 : 2+ulen])
	p.clientBuf = append([]byte(nil), b[need2:]...)
	if p.cfg.AuthToken != "" && user != p.cfg.AuthToken {
		p.writeClient([]byte{0x01, 0x01})
		p.closeAfterWrite()
		return false
	}
	p.writeClient([]byte{0x01, 0x00})
	p.state = stSocks5Req
	return p.processPreRelay()
}

func (p *proxyConn) socks5Request(b []byte) bool {
	if len(b) < 4 {
		return true
	}
	replyFail := func(code byte) bool {
		p.writeClient([]byte{0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		p.closeAfterWrite()
		return false
	}
	if b[0] != 0x05 {
		return false
	}
	if b[1] != 0x01 {
		return replyFail(0x07)
	}
	atyp := b[3]
	var host string
	var port int
	switch atyp {
	case 0x01:
		if len(b) < 10 {
			return true
		}
		host = net.IPv4(b[4], b[5], b[6], b[7]).String()
		port = int(b[8])<<8 | int(b[9])
		p.clientBuf = append([]byte(nil), b[10:]...)
	case 0x03:
		if len(b) < 5 {
			return true
		}
		l := int(b[4])
		if len(b) < 7+l {
			return true
		}
		host = string(b[5 : 5+l])
		port = int(b[5+l])<<8 | int(b[6+l])
		p.clientBuf = append([]byte(nil), b[7+l:]...)
	case 0x04:
		if len(b) < 22 {
			return true
		}
		host = "ipv6"
		port = int(b[20])<<8 | int(b[21])
		p.clientBuf = append([]byte(nil), b[22:]...)
	default:
		return replyFail(0x08)
	}
	p.reply = []byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}
	if p.cfg.SocksLocal {
		host, port = p.cfg.ToAddr, p.cfg.ToPort
	}
	return p.startRelay(host, port, true)
}

func (p *proxyConn) socks4Request(b []byte) bool {
	if len(b) < 9 {
		return true
	}
	if b[0] != 0x04 || b[1] != 0x01 {
		return false
	}
	i := bytes.IndexByte(b[8:], 0)
	if i < 0 {
		if len(b) > 512 {
			return false
		}
		return true
	}
	nul := 8 + i
	user := string(b[8:nul])
	port := int(b[2])<<8 | int(b[3])
	a, bb, cc, d := b[4], b[5], b[6], b[7]
	host := net.IPv4(a, bb, cc, d).String()
	off := nul + 1
	if a == 0 && bb == 0 && cc == 0 && d != 0 {
		j := bytes.IndexByte(b[off:], 0)
		if j < 0 {
			if len(b) > 512 {
				return false
			}
			return true
		}
		host = string(b[off : off+j])
		off += j + 1
	}
	p.clientBuf = append([]byte(nil), b[off:]...)
	if p.cfg.AuthToken != "" && user != p.cfg.AuthToken {
		return false
	}
	p.reply = append([]byte{0x00, 0x5a, byte(port >> 8), byte(port)}, a, bb, cc, d)
	if p.cfg.SocksLocal {
		host, port = p.cfg.ToAddr, p.cfg.ToPort
	}
	return p.startRelay(host, port, true)
}

func (p *proxyConn) handleTLS(b []byte) bool {
	if len(b) < 5 {
		return true
	}
	recLen := int(b[3])<<8 | int(b[4])
	need := 5 + recLen
	if need > 8192 {
		return false
	}
	if len(b) < need {
		return true
	}
	if p.cfg.SNIAllow != "" {
		sni, have := extractSNI(b[:need])
		if !have || sni != p.cfg.SNIAllow {
			p.sendDecoy()
			return false
		}
	}
	p.pending = append([]byte(nil), b[:need]...)
	p.clientBuf = append([]byte(nil), b[need:]...)
	return p.startRelay(p.cfg.TLSHost, p.cfg.TLSPort, true)
}

func (p *proxyConn) startRelay(host string, port int, raw bool) bool {
	addr := net.JoinHostPort(normalizeHost(host), strconv.Itoa(port))
	rmt, err := net.DialTimeout("tcp", addr, 10*time.Second)
	if err != nil {
		log.Printf("proxygo: dial %s: %v", addr, err)
		return false
	}
	setSockOpts(rmt, p.cfg.Keepalive)
	p.rmt = rmt
	p.state = stRelay
	p.rawTunnel = raw
	if raw || !p.cfg.DPI {
		p.fragIn, p.fragOut = 0, 0
	} else {
		p.fragIn, p.fragOut = p.cfg.DPIBytes, p.cfg.DPIBytes
	}
	if p.magicTimer != nil {
		p.magicTimer.Stop()
		p.magicTimer = nil
	}
	if len(p.reply) > 0 {
		if err := p.writeClient(p.reply); err != nil {
			return false
		}
		p.reply = nil
	}
	if len(p.pending) > 0 {
		if err := p.writeRemote(p.pending); err != nil {
			return false
		}
		p.pending = nil
	}
	if len(p.clientBuf) > 0 {
		b := p.clientBuf
		p.clientBuf = nil
		if !raw {
			b = p.filterClientToSSH(b)
		}
		if len(b) > 0 {
			if err := p.relayWithDPI(p.rmt, b, &p.fragIn); err != nil {
				return false
			}
		}
	}
	go p.remoteLoop()
	return true
}

func (p *proxyConn) remoteLoop() {
	defer p.close()
	buf := make([]byte, 32768)
	for {
		n, err := p.rmt.Read(buf)
		if err != nil {
			return
		}
		if err := p.relayWithDPI(p.cli, buf[:n], &p.fragOut); err != nil {
			return
		}
	}
}

func (p *proxyConn) forwardClient(b []byte) error {
	if !p.rawTunnel {
		b = p.filterClientToSSH(b)
	}
	if len(b) == 0 {
		return nil
	}
	return p.relayWithDPI(p.rmt, b, &p.fragIn)
}

func (p *proxyConn) relayWithDPI(dst net.Conn, b []byte, remaining *int) error {
	if len(b) == 0 {
		return nil
	}
	if !p.cfg.DPI || *remaining <= 0 {
		_, err := dst.Write(b)
		return err
	}
	n := len(b)
	if n > *remaining {
		n = *remaining
	}
	for i := 0; i < n; {
		chunk := p.cfg.DPIChunk
		if i+chunk > n {
			chunk = n - i
		}
		if _, err := dst.Write(b[i : i+chunk]); err != nil {
			return err
		}
		i += chunk
		if i < n && p.cfg.DPIDelayMS > 0 {
			time.Sleep(time.Duration(p.cfg.DPIDelayMS) * time.Millisecond)
		}
	}
	*remaining -= n
	if n < len(b) {
		_, err := dst.Write(b[n:])
		return err
	}
	return nil
}

var controlMethods = map[string]bool{
	"GET": true, "POST": true, "PUT": true, "PATCH": true, "PATH": true,
	"DELETE": true, "HEAD": true, "OPTIONS": true, "CONNECT": true,
	"TRACE": true, "ACL": true, "UNLOCK": true, "LOCK": true, "MKCOL": true,
	"COPY": true, "MOVE": true, "PROPFIND": true, "PROPPATCH": true,
	"PROPATH": true, "POLL": true, "SEARCH": true, "MERGE": true,
	"BASELINE-CONTROL": true, "REPORT": true, "MKACTIVITY": true,
	"CHECKOUT": true, "UPDATE": true, "VERSION-CONTROL": true, "BIND": true,
	"UNBIND": true, "REBIND": true, "LINK": true, "UNLINK": true, "PURGE": true,
	"MKCALENDAR": true, "SUBSCRIBE": true, "UNSUBSCRIBE": true, "NOTIFY": true,
	"PUBLISH": true, "M-SEARCH": true, "SOURCE": true, "QUERY": true,
	"INDEX": true, "SCAN": true, "PING": true, "BASELINE": true, "LABEL": true,
	"ORDERPATCH": true, "ACL-ANSWER": true,
}

// stripWSControl remove npv-x e blocos de controle HTTP do payload do túnel.
// Não faz o gate do banner SSH (isso é feito por filterClientToSSH).
func (p *proxyConn) stripWSControl(b []byte) []byte {
	out := make([]byte, 0, len(b))
	for len(b) > 0 {
		if p.inControl {
			if end, term := findHeaderEnd(b); end >= 0 {
				b = b[end+term:]
				p.inControl = false
				continue
			}
			break
		}
		if len(b) >= 5 && bytes.Equal(b[:5], []byte("npv-x")) {
			b = b[5:]
			continue
		}
		if b[0] < 'A' || b[0] > 'Z' {
			out = append(out, b...)
			break
		}
		peek := b
		if len(peek) > 255 {
			peek = peek[:255]
		}
		first := string(peek)
		if i := bytes.IndexAny(peek, "\r\n"); i >= 0 {
			first = string(peek[:i])
		}
		method := first
		if i := strings.IndexByte(method, ' '); i >= 0 {
			method = method[:i]
		}
		if !strings.Contains(first, "HTTP/") && !controlMethods[method] {
			out = append(out, b...)
			break
		}
		if end, term := findHeaderEnd(b); end >= 0 {
			b = b[end+term:]
			continue
		}
		p.inControl = true
		break
	}
	return out
}

// filterClientToSSH reproduz filter_client_to_ssh do C: descarta tudo antes
// do banner SSH- e depois aplica stripWSControl continuamente. Mantém um
// carry de 3 bytes para não perder um banner fragmentado.
func (p *proxyConn) filterClientToSSH(data []byte) []byte {
	b := append(p.pendingSSH, data...)
	p.pendingSSH = nil
	if !p.bannerSent {
		i := bytes.Index(b, []byte("SSH-"))
		if i < 0 {
			keep := len(b)
			if keep > 3 {
				keep = 3
			}
			p.pendingSSH = append([]byte(nil), b[len(b)-keep:]...)
			return nil
		}
		if i > 0 {
			b = b[i:]
		}
		p.bannerSent = true
	}
	return p.stripWSControl(b)
}

func (p *proxyConn) sendImmediate101() {
	p.writeClient([]byte(fmt.Sprintf("HTTP/1.1 101 %s\r\n\r\n", p.cfg.Response)))
}

func (p *proxyConn) send200() {
	p.writeClient([]byte(fmt.Sprintf("HTTP/1.1 200 %s\r\n\r\n", p.cfg.Response)))
}

func (p *proxyConn) sendWS101(hdr string) {
	if p.cfg.Legacy101 {
		p.sendImmediate101()
		return
	}
	key := headerValue(hdr, "Sec-WebSocket-Key")
	var rid [4]byte
	_, _ = rand.Read(rid[:])
	var resp string
	if key != "" {
		resp = fmt.Sprintf("HTTP/1.1 101 Switching Protocols\r\n"+
			"Upgrade: websocket\r\n"+
			"Connection: Upgrade\r\n"+
			"Sec-WebSocket-Accept: %s\r\n"+
			"Server: nginx\r\n"+
			"X-Request-Id: %s\r\n\r\n", makeWSAccept(key), hex.EncodeToString(rid[:]))
	} else {
		resp = fmt.Sprintf("HTTP/1.1 101 %s\r\n"+
			"Upgrade: websocket\r\n"+
			"Connection: Upgrade\r\n"+
			"Server: nginx\r\n"+
			"X-Request-Id: %s\r\n\r\n", p.cfg.Response, hex.EncodeToString(rid[:]))
	}
	p.writeClient([]byte(resp))
}

func (p *proxyConn) send403() {
	p.writeClient([]byte("HTTP/1.1 403 Forbidden\r\nServer: nginx\r\n" +
		"Content-Length: 0\r\nConnection: close\r\n\r\n"))
	p.closeAfterWrite()
}

func (p *proxyConn) sendDecoy() {
	body := "<!DOCTYPE html><html><head><title>Welcome to nginx!</title></head>" +
		"<body><h1>Welcome to nginx!</h1>" +
		"<p>If you see this page, the nginx web server is successfully installed " +
		"and working. Further configuration is required.</p>" +
		"<p>For online documentation and support please refer to " +
		"<a href=\"http://nginx.org/\">nginx.org</a>.</p></body></html>"
	p.writeClient([]byte(fmt.Sprintf("HTTP/1.1 200 OK\r\n"+
		"Server: nginx\r\n"+
		"Content-Type: text/html; charset=UTF-8\r\n"+
		"Content-Length: %d\r\n"+
		"Cache-Control: no-cache\r\n"+
		"Connection: close\r\n\r\n%s", len(body), body)))
	p.closeAfterWrite()
}

func (p *proxyConn) closeAfterWrite() {
	p.delayed = true
	p.cli.SetWriteDeadline(time.Now().Add(3 * time.Second))
	time.AfterFunc(3*time.Second, p.close)
}

func (p *proxyConn) armMagicTimer() {
	p.magicTimer = time.AfterFunc(24*time.Hour, func() {
		if p.state == stWSMagic && p.rmt == nil {
			p.close()
		}
	})
}

func (p *proxyConn) writeClient(b []byte) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	_, err := p.cli.Write(b)
	return err
}

func (p *proxyConn) writeRemote(b []byte) error {
	_, err := p.rmt.Write(b)
	return err
}

func (p *proxyConn) close() {
	p.closeOnce.Do(func() {
		if p.magicTimer != nil {
			p.magicTimer.Stop()
		}
		if p.cli != nil {
			p.cli.Close()
		}
		if p.rmt != nil {
			p.rmt.Close()
		}
	})
}

// ── helpers ────────────────────────────────────────────────────────────────

var httpPrefixes = [][]byte{
	[]byte("GET "), []byte("POST "), []byte("HEAD "), []byte("PUT "),
	[]byte("CONNECT "), []byte("OPTIONS "), []byte("DELETE "), []byte("PATCH "),
}

func startsHTTP(b []byte) bool {
	for _, pre := range httpPrefixes {
		if bytes.HasPrefix(b, pre) {
			return true
		}
	}
	return false
}

func firstLine(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func findHeaderEnd(b []byte) (int, int) {
	if len(b) > 8192 {
		b = b[:8192]
	}
	for _, seq := range [][]byte{[]byte("\r\n\r\n"), []byte("\n\r\n"), []byte("\n\n")} {
		if i := bytes.Index(b, seq); i >= 0 {
			return i, len(seq)
		}
	}
	return -1, 0
}

func headerValue(hdr, name string) string {
	for _, line := range strings.Split(strings.ReplaceAll(hdr, "\r\n", "\n"), "\n") {
		i := strings.IndexByte(line, ':')
		if i < 0 {
			continue
		}
		if strings.EqualFold(strings.TrimSpace(line[:i]), name) {
			return strings.TrimSpace(line[i+1:])
		}
	}
	return ""
}

func tokenOK(hdr, line, token string) bool {
	if token == "" {
		return true
	}
	if headerValue(hdr, "X-Auth-Token") == token {
		return true
	}
	v := headerValue(hdr, "Authorization")
	if len(v) >= 7 && strings.EqualFold(v[:7], "Bearer ") &&
		strings.TrimSpace(v[7:]) == token {
		return true
	}
	return strings.Contains(line, "token="+token)
}

func makeWSAccept(key string) string {
	h := sha1.Sum([]byte(strings.TrimSpace(key) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(h[:])
}

func normalizeHost(host string) string {
	if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
		return host
	}
	return "127.0.0.1"
}

func extractSNI(b []byte) (string, bool) {
	if len(b) < 5 || b[0] != 0x16 || b[1] != 0x03 {
		return "", false
	}
	rec := int(b[3])<<8 | int(b[4])
	if rec < 4 || len(b) < 5+rec {
		return "", false
	}
	hs := 5
	if b[hs] != 0x01 || len(b) < hs+4 {
		return "", false
	}
	bodylen := int(b[hs+1])<<16 | int(b[hs+2])<<8 | int(b[hs+3])
	if bodylen+4 > rec || hs+4+bodylen > len(b) {
		return "", false
	}
	p := hs + 4
	end := p + bodylen
	if p+2+32 > end {
		return "", false
	}
	p += 2 + 32 // client_version + random
	if p >= end {
		return "", false
	}
	sid := int(b[p])
	p++
	if p+sid > end {
		return "", false
	}
	p += sid
	if p+2 > end {
		return "", false
	}
	cs := int(b[p])<<8 | int(b[p+1])
	p += 2
	if p+cs > end {
		return "", false
	}
	p += cs
	if p+1 > end {
		return "", false
	}
	comp := int(b[p])
	p++
	if p+comp > end {
		return "", false
	}
	p += comp
	if p+2 > end {
		return "", false
	}
	ext := int(b[p])<<8 | int(b[p+1])
	p += 2
	eend := p + ext
	if eend > end {
		eend = end
	}
	for p+4 <= eend {
		typ := int(b[p])<<8 | int(b[p+1])
		l := int(b[p+2])<<8 | int(b[p+3])
		p += 4
		if p+l > eend {
			break
		}
		if typ == 0 && l >= 5 {
			llen := int(b[p])<<8 | int(b[p+1])
			s := p + 2
			if llen >= 3 && s+3 <= p+l && b[s] == 0x00 {
				nl := int(b[s+1])<<8 | int(b[s+2])
				s += 3
				if nl > 0 && s+nl <= p+l {
					return string(b[s : s+nl]), true
				}
			}
		}
		p += l
	}
	return "", false
}

func setSockOpts(c net.Conn, keepalive bool) {
	tcp, ok := c.(*net.TCPConn)
	if !ok {
		return
	}
	tcp.SetNoDelay(true)
	if !keepalive {
		return
	}
	tcp.SetKeepAlive(true)
	tcp.SetKeepAlivePeriod(60 * time.Second)
	if raw, err := tcp.SyscallConn(); err == nil {
		raw.Control(func(fd uintptr) {
			syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, syscall.TCP_KEEPIDLE, 60)
			syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, syscall.TCP_KEEPINTVL, 30)
			syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, syscall.TCP_KEEPCNT, 3)
		})
	}
}
