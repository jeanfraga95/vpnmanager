package main

import (
	"bufio"
	"io"
	"log"
	"net"
	"strings"
)

var (
	hcrTarget   = "127.0.0.1:18082"
	wsTarget    = "127.0.0.1:8080"
	xhttpTarget = "127.0.0.1:11443"
	bhttpTarget = "127.0.0.1:18083"
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
		// Cliente nao enviou nada ou desconectou
		return bhttpTarget, client, nil
	}
	peekBuf = append(peekBuf, b)

	first := b

	// HCR plain: byte 0 = Operation (1-6), byte 1 = Version (0x01)
	if isHCRPlainOperation(first) {
		b2, err2 := reader.ReadByte()
		if err2 == nil && b2 == 0x01 {
			peekBuf = append(peekBuf, b2)
			log.Printf("proxy80: detectado HCR plain (op=%d) de %s", first, client.RemoteAddr())
			return hcrTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
		}
		// Nao e HCR (versao nao e 0x01), devolve os bytes lidos e assume BHTTP
		log.Printf("proxy80: byte 0x%02x mas versao 0x%02x nao e HCR de %s, assume BHTTP", first, b2, client.RemoteAddr())
		return bhttpTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
	}

	// HCR TLS: 0x16 (TLS ClientHello)
	if first == 0x16 {
		// Ler mais alguns bytes para confirmar TLS
		rest, _ := reader.Peek(3)
		if len(rest) > 0 {
			peekBuf = append(peekBuf, rest...)
		}
		log.Printf("proxy80: detectado HCR TLS de %s", client.RemoteAddr())
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
			log.Printf("proxy80: detectado WebSocket de %s", client.RemoteAddr())
			return wsTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
		}
		log.Printf("proxy80: detectado HTTP/XHTTP de %s", client.RemoteAddr())
		return xhttpTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
	}

	// Nao reconhecido: assume BHTTP, devolve o primeiro byte lido
	log.Printf("proxy80: nao reconhecido (0x%02x) de %s, assume BHTTP", first, client.RemoteAddr())
	return bhttpTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
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
		log.Printf("proxy80: erro detecao protocolo %s: %v", client.RemoteAddr(), err)
		target = bhttpTarget
		src = client
	}

	targetConn, err := net.Dial("tcp", target)
	if err != nil {
		log.Printf("proxy80: erro conectar %s: %v", target, err)
		return
	}
	defer targetConn.Close()

	log.Printf("proxy80: cliente %s -> %s", client.RemoteAddr(), target)

	done := make(chan error, 2)
	go copyConn(targetConn, src, done)
	go copyConn(client, targetConn, done)
	<-done
}

func main() {
	listener, err := net.Listen("tcp", "0.0.0.0:80")
	if err != nil {
		log.Fatalf("proxy80: erro escutando na porta 80: %v", err)
	}
	defer listener.Close()
	log.Printf("proxy80: escutando na porta 80 (HCR=%s, WS=%s, XHTTP=%s, BHTTP=%s)", hcrTarget, wsTarget, xhttpTarget, bhttpTarget)

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("proxy80: erro accept: %v", err)
			continue
		}
		go handleConn(conn)
	}
}
