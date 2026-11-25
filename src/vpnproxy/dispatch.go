package main

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
