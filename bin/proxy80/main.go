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
	xhttpTarget = "127.0.0.1:10443"
	bhttpTarget = "127.0.0.1:18083"
)

func detectProtocol(client net.Conn) (string, io.Reader, error) {
	client.SetReadDeadline(time.Now().Add(3 * time.Second))
	defer client.SetReadDeadline(time.Time{})

	reader := bufio.NewReaderSize(client, 8192)

	var peekBuf []byte

	b, err := reader.Peek(1)
	if err != nil {
		buf := make([]byte, 1)
		n, readErr := reader.Read(buf)
		if readErr != nil || n == 0 {
			return bhttpTarget, client, nil
		}
		b = buf[:n]
		peekBuf = append(peekBuf, b...)
	}

	if len(b) >= 1 {
		first := b[0]

		// HCR plain: 0x01 0x01
		if first == 0x01 {
			b2, err2 := reader.Peek(2)
			if err2 == nil && len(b2) >= 2 && b2[0] == 0x01 && b2[1] == 0x01 {
				reader.Discard(2)
				peekBuf = append(peekBuf, 0x01, 0x01)
				rest, _ := reader.Peek(reader.Buffered())
				if len(rest) > 0 {
					peekBuf = append(peekBuf, rest...)
					reader.Discard(len(rest))
				}
				return hcrTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
			}
			return bhttpTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
		}

		// HCR TLS: 0x16
		if first == 0x16 {
			rest, _ := reader.Peek(reader.Buffered())
			if len(rest) > 0 {
				peekBuf = append(peekBuf, rest...)
				reader.Discard(len(rest))
			}
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
				return wsTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
			}
			return xhttpTarget, io.MultiReader((*bytesReader)(&peekBuf), reader), nil
		}
	}

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
