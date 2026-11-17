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
	xhttpTarget = "127.0.0.1:10443"
	bhttpTarget = "127.0.0.1:18083"
)

func detectProtocol(r *bufio.Reader) (string, []byte) {
	b, err := r.Peek(1)
	if err != nil {
		return bhttpTarget, nil
	}

	if len(b) >= 1 && b[0] == 0x01 {
		b2, _ := r.Peek(2)
		if len(b2) >= 2 && b2[0] == 0x01 && b2[1] == 0x01 {
			peekAll, _ := r.Peek(r.Buffered())
			return hcrTarget, peekAll
		}
	}

	if len(b) >= 1 && b[0] == 0x16 {
		peekAll, _ := r.Peek(r.Buffered())
		return hcrTarget, peekAll
	}

	peek, err := r.Peek(1024)
	if err != nil && err != bufio.ErrBufferFull {
		return bhttpTarget, nil
	}

	for _, method := range []string{"GET ", "POST ", "CONNECT ", "HEAD ", "OPTIONS ", "PUT ", "DELETE ", "PATCH "} {
		if strings.HasPrefix(string(peek), method) {
			lower := strings.ToLower(string(peek))
			if strings.Contains(lower, "upgrade: websocket") {
				return wsTarget, peek
			}
			return xhttpTarget, peek
		}
	}

	return bhttpTarget, peek
}

func copyConn(dst io.Writer, src io.Reader, done chan<- error) {
	_, err := io.Copy(dst, src)
	done <- err
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

func handleConn(client net.Conn) {
	defer client.Close()

	reader := bufio.NewReaderSize(client, 4096)
	target, peekData := detectProtocol(reader)

	targetConn, err := net.Dial("tcp", target)
	if err != nil {
		log.Printf("proxy80: erro conectar %s: %v", target, err)
		return
	}
	defer targetConn.Close()

	log.Printf("proxy80: cliente %s -> %s", client.RemoteAddr(), target)

	var src io.Reader = client
	if len(peekData) > 0 {
		src = io.MultiReader((*bytesReader)(&peekData), client)
	}

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
