package main

import (
	"bufio"
	"io"
	"log"
	"net"
	"strings"
	"time"
)

var (
	hcrTarget   = "127.0.0.1:18082"
	wsTarget    = "127.0.0.1:8080"
	xhttpTarget = "127.0.0.1:11443"
)

// isHCRPlainOperation verifica se o byte e uma operacao HCR valida (1-6)
func isHCRPlainOperation(b byte) bool {
	return b >= 1 && b <= 6
}

func detectProtocol(client net.Conn) (string, io.Reader, error) {
	reader := bufio.NewReaderSize(client, 8192)

	var peekBuf []byte

	// Ler primeiro byte (bloqueia ate ter dados)
	b, err := reader.ReadByte()
	if err != nil {
		return hcrTarget, client, nil
	}
	peekBuf = append(peekBuf, b)

	first := b

	// HCR plain: byte 0 = Operation (1-6), byte 1 = Version (0x01)
	if isHCRPlainOperation(first) {
		b2, err2 := reader.ReadByte()
		if err2 == nil && b2 == 0x01 {
			peekBuf = append(peekBuf, b2)
			log.Printf("fallback-proxy: detectado HCR plain (op=%d) de %s", first, client.RemoteAddr())
			return hcrTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
		}
		return hcrTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
	}

	// HCR TLS: 0x16 (TLS ClientHello)
	if first == 0x16 {
		rest, _ := reader.Peek(3)
		if len(rest) > 0 {
			peekBuf = append(peekBuf, rest...)
		}
		log.Printf("fallback-proxy: detectado HCR TLS de %s", client.RemoteAddr())
		return hcrTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
	}

	// HTTP: ler linha por linha
	isHTTPMethod := false
	for _, m := range []byte{'G', 'P', 'C', 'H', 'O', 'U', 'D'} {
		if first == m {
			isHTTPMethod = true
			break
		}
	}

	if isHTTPMethod {
		var headers strings.Builder
		isWebSocket := false
		headers.WriteByte(first)
		for {
			line, err := reader.ReadString('\n')
			headers.WriteString(line)
			if err != nil {
				break
			}
			if line == "\r\n" || line == "\n" {
				break
			}
			if strings.Contains(strings.ToLower(headers.String()), "upgrade: websocket") {
				isWebSocket = true
			}
		}
		peekBuf = []byte(headers.String())
		rest, _ := reader.Peek(reader.Buffered())
		if len(rest) > 0 {
			peekBuf = append(peekBuf, rest...)
			reader.Discard(len(rest))
		}
		if isWebSocket {
			log.Printf("fallback-proxy: detectado WebSocket de %s", client.RemoteAddr())
			return wsTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
		}
		log.Printf("fallback-proxy: detectado HTTP/XHTTP de %s", client.RemoteAddr())
		return xhttpTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
	}

	// Padrao: enviar para HCR (mais provavel ser HCR do que outra coisa)
	log.Printf("fallback-proxy: nao reconhecido (0x%02x) de %s, envia para HCR", first, client.RemoteAddr())
	return hcrTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
}

type bytesReader []byte

func (b *bytesReader) Read(p []byte) (int, error) {
	if len(*b) == 0 {
		return 0, io.EOF
	}
	n := copy(p, *b)
	*b = (*b)[n:]
	return n, nil
}

func copyConn(dst io.Writer, src io.Reader, done chan<- error) {
	_, err := io.Copy(dst, src)
	done <- err
}

func handleConn(client net.Conn) {
	defer client.Close()

	target, src, err := detectProtocol(client)
	if err != nil {
		log.Printf("fallback-proxy: erro detecao protocolo %s: %v", client.RemoteAddr(), err)
		target = hcrTarget
		src = client
	}

	targetConn, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		log.Printf("fallback-proxy: erro conectar %s: %v", target, err)
		return
	}
	defer targetConn.Close()

	log.Printf("fallback-proxy: cliente %s -> %s", client.RemoteAddr(), target)

	done := make(chan error, 2)
	go copyConn(targetConn, src, done)
	go copyConn(client, targetConn, done)
	<-done
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	listener, err := net.Listen("tcp", "0.0.0.0:19080")
	if err != nil {
		log.Fatalf("fallback-proxy: erro escutando na porta 19080: %v", err)
	}
	defer listener.Close()
	log.Printf("fallback-proxy: escutando na porta 19080 (HCR=%s, WS=%s, XHTTP=%s)", hcrTarget, wsTarget, xhttpTarget)

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("fallback-proxy: erro accept: %v", err)
			continue
		}
		go handleConn(conn)
	}
}
