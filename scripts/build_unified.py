#!/usr/bin/env python3
# Gera /tmp/vpnfull/src/vpnproxy a partir de bhttpssh + proxygo, sem tocar nos originais.
import os, re, shutil, sys

ROOT = '/tmp/vpnfull/src'
DST  = ROOT + '/vpnproxy'
WS   = DST + '/internal/wsproxy'

shutil.rmtree(DST, ignore_errors=True)
os.makedirs(WS, exist_ok=True)

# 1) copia base bhttpssh
for f in ('main.go', 'dtproto.go', 'go.mod', 'go.sum'):
    shutil.copyfile(ROOT + '/bhttpssh/' + f, DST + '/' + f)

with open(DST + '/go.mod', 'r') as fh:
    gm = fh.read()
gm = gm.replace('module bhttpssh', 'module vpnproxy', 1)
with open(DST + '/go.mod', 'w') as fh:
    fh.write(gm)

# 2) wsproxy: transforma proxygo/main.go em pacote importavel
with open(ROOT + '/proxygo/main.go', 'r') as fh:
    ws = fh.read()
ws = ws.replace('package main\n', 'package wsproxy\n', 1)
ws = ws.replace('\t"flag"\n', '', 1)
start = ws.index('func main() {')
end = ws.index('func handleConn(c net.Conn, cfg *Config) {')
ws = ws[:start] + 'func Serve(c net.Conn, cfg *Config) {' + ws[end + len('func handleConn(c net.Conn, cfg *Config) {'):]
ws += '''

// DefaultConfig reproduz exactamente os flags de producao do proxy C:
// --auto-200 (WaitMagic=false), 101 aos 50ms, DPI 48/8/12ms.
func DefaultConfig(toAddr string, toPort int) *Config {
	return &Config{
		ToAddr:       toAddr,
		ToPort:       toPort,
		Response:     "OK",
		DPI:          true,
		DPIBytes:     48,
		DPIChunk:     8,
		DPIDelayMS:   12,
		Legacy101:    false,
		Immediate101: true,
		WaitMagic:    false,
		Keepalive:    true,
	}
}
'''
with open(WS + '/wsproxy.go', 'w') as fh:
    fh.write(ws)

# 3) troca os 4 redials para 19080 pelo dispatcher interno
with open(DST + '/main.go', 'r') as fh:
    mn = fh.read()
before = mn
mn = mn.replace('pipeFallback(c, fallback, one)', 'routeNonBHTTP(c, fallback, one)')
mn = mn.replace('pipeFallback(c, fallback, hdr)', 'routeNonBHTTP(c, fallback, hdr)')
if mn == before:
    print('ERRO: nenhuma chamada pipeFallback substituida', file=sys.stderr)
    sys.exit(3)
if 'pipeFallback(c, fallback' in mn:
    print('ERRO: ainda restam chamadas pipeFallback', file=sys.stderr)
    sys.exit(4)
# O sniff era condicionado ao --fallback-target; agora o dispatcher e interno.
if 'if fallback != "" && !isQUIC {' not in mn:
    print('ERRO: condicao de sniff nao encontrada', file=sys.stderr)
    sys.exit(5)
mn = mn.replace('if fallback != "" && !isQUIC {', 'if !isQUIC {', 1)
# No ramo fragmentado o io.ReadFull retornava os bytes parciais em 'rest'
# mas o codigo so reinjetava 'one' — SOCKS4/5 e TLS perdiam os bytes.
old_frag = '''			rest := make([]byte, hdrSize-1)
			c.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
			_, err2 := io.ReadFull(c, rest)
			c.SetReadDeadline(time.Time{})'''
new_frag = '''			rest := make([]byte, hdrSize-1)
			c.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
			n2, err2 := io.ReadFull(c, rest)
			c.SetReadDeadline(time.Time{})'''
if old_frag not in mn:
    print('ERRO: bloco de sniff fragmentado nao encontrado', file=sys.stderr)
    sys.exit(6)
mn = mn.replace(old_frag, new_frag, 1)
old_replay = '''				c = &prefixConn{Conn: c, prefix: append([]byte(nil), one...)}
			} else {'''
new_replay = '''				pfx := append(append([]byte(nil), one...), rest[:n2]...)
				if one[0] > frameResume {
					routeNonBHTTP(c, fallback, pfx)
					return
				}
				// SOCKS4 (0x04) e SOCKS5 (0x05) colidem com os tipos de frame
				// BHTTP 4/5. Um greeting SOCKS tem o 3o byte 0x00 (metodo
				// noauth ou porta alta); frames BHTTP fragmentados nao tem
				// essa assinatura. Envia direto ao wsproxy, sem teste HCR.
				if len(pfx) >= 3 && (pfx[0] == 0x04 || pfx[0] == 0x05) && pfx[2] == 0x00 {
					routeWS(c, pfx)
					return
				}
				c = &prefixConn{Conn: c, prefix: pfx}
			} else {'''
if old_replay not in mn:
    print('ERRO: replay fragmentado nao encontrado', file=sys.stderr)
    sys.exit(7)
mn = mn.replace(old_replay, new_replay, 1)
with open(DST + '/main.go', 'w') as fh:
    fh.write(mn)

# 4) dispatcher
dispatch = r'''package main

// Dispatcher interno: substitui o fallback-proxy (19080). Nenhum redial
// externo; HCR e XHTTP continuam como modulos loopback, WS/CONNECT/SOCKS
// rodam dentro deste processo via wsproxy.

import (
	"flag"
	"io"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"vpnproxy/internal/wsproxy"
)

var (
	flagHCRTarget   = flag.String("hcr-target", "127.0.0.1:18082", "destino HCR interno")
	flagXHTTPTarget = flag.String("xhttp-target", "127.0.0.1:11443", "destino XHTTP interno")
	flagWSTo        = flag.String("ws-to", "127.0.0.1:22", "destino SSH para WS/CONNECT/SOCKS")

	dispatchOnce sync.Once
	dispatchCfg  *wsproxy.Config
)

func wsConfig() *wsproxy.Config {
	dispatchOnce.Do(func() {
		host, port, err := net.SplitHostPort(*flagWSTo)
		if err != nil {
			host, port = "127.0.0.1", *flagWSTo
		}
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			n = 22
		}
		dispatchCfg = wsproxy.DefaultConfig(host, n)
	})
	return dispatchCfg
}

// rawPipe encaminha a conexao para um modulo loopback, reinjetando os bytes
// ja consumidos pelo sniff antes de abrir o túnel.
func rawPipe(c net.Conn, prefix []byte, target, label string) {
	if target == "" {
		log.Printf("dispatch: %s sem destino, fechando %s", label, c.RemoteAddr())
		_ = c.Close()
		return
	}
	up, err := net.DialTimeout("tcp", target, 10*time.Second)
	if err != nil {
		log.Printf("dispatch: %s -> %s falhou: %v", label, target, err)
		_ = c.Close()
		return
	}
	rc := &prefixConn{Conn: c, prefix: append([]byte(nil), prefix...)}
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(up, rc); done <- struct{}{} }()
	go func() { _, _ = io.Copy(c, up); done <- struct{}{} }()
	<-done
	_ = c.Close()
	_ = up.Close()
	<-done
}

// routeWS entrega a conexao direto ao proxy WS/CONNECT/SOCKS, sem passar
// pelo teste de HCR (usado quando o greeting SOCKS ja foi identificado).
func routeWS(c net.Conn, prefix []byte) {
	wsproxy.Serve(&prefixConn{Conn: c, prefix: prefix}, wsConfig())
}

// routeNonBHTTP recebe a conexao com os primeiros 'prefix' bytes ja lidos
// pelo sniff do bhttpssh e decide o destino sem passar pelo 19080.
func routeNonBHTTP(c net.Conn, legacy string, prefix []byte) {
	// HCR plain: Operation 1-6, Version 0x01 (mesmo teste do fallback antigo).
	if len(prefix) >= 2 && prefix[0] >= 1 && prefix[0] <= 6 && prefix[1] == 1 {
		log.Printf("dispatch: HCR plain op=%d de %s -> %s", prefix[0], c.RemoteAddr(), *flagHCRTarget)
		rawPipe(c, prefix, *flagHCRTarget, "hcr")
		return
	}

	// HTTP: ler o que ja esta no socket (10ms) para achar o header de sessao.
	// Nao usar Peek(N): ele bloquearia esperando N bytes quando o cliente
	// envia apenas o request HTTP e fica aguardando resposta.
	if len(prefix) > 0 && prefix[0] >= 'A' && prefix[0] <= 'Z' {
		extra := make([]byte, 16<<10)
		_ = c.SetReadDeadline(time.Now().Add(10 * time.Millisecond))
		n, _ := c.Read(extra)
		_ = c.SetReadDeadline(time.Time{})
		all := append(append([]byte(nil), prefix...), extra[:n]...)
		lower := strings.ToLower(string(all))
		if strings.Contains(lower, "x-http-sid") || strings.Contains(lower, "x-session-id") {
			log.Printf("dispatch: XHTTP de %s -> %s", c.RemoteAddr(), *flagXHTTPTarget)
			rawPipe(c, all, *flagXHTTPTarget, "xhttp")
			return
		}
		wsproxy.Serve(&prefixConn{Conn: c, prefix: all}, wsConfig())
		return
	}

	// SOCKS4/5, TLS direto, WS legado e decoys.
	wsproxy.Serve(&prefixConn{Conn: c, prefix: prefix}, wsConfig())
}
'''
with open(DST + '/dispatch.go', 'w') as fh:
    fh.write(dispatch)

print('gerado:', DST)
for f in ('main.go', 'dtproto.go', 'dispatch.go', 'go.mod', 'internal/wsproxy/wsproxy.go'):
    print(' ', f, os.path.getsize(DST + '/' + f))

# 3) patch reprodutivel --silent-ws (comportamento do proxy C na 8080).
PATCH = '/tmp/vpnfull/scripts/apply_silent_ws.py'
if os.path.exists(PATCH):
    ns = {'DST': DST, '__name__': '__main__'}
    exec(compile(open(PATCH).read(), PATCH, 'exec'), ns)
else:
    print('AVISO: patch silent-ws nao encontrado:', PATCH)

# 3b) patch reprodutivel do caminho silent sem 200 extra (proxyjf-like).
PATCH2 = '/tmp/vpnfull/scripts/apply_nomagic200.py'
if os.path.exists(PATCH2):
    ns2 = {'DST': DST, '__name__': '__main__'}
    exec(compile(open(PATCH2).read(), PATCH2, 'exec'), ns2)
else:
    print('AVISO: patch nomagic200 nao encontrado:', PATCH2)

# gofmt para manter o fonte versionado estavel entre rebuilds.
import subprocess
subprocess.check_call(['/usr/local/go/bin/gofmt', '-w',
    DST + '/main.go', DST + '/dispatch.go', DST + '/internal/wsproxy/wsproxy.go'])
