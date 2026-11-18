package main

import (
	"io"
	"log"
	"net"
	"time"
)

var (
	hcrTarget = "127.0.0.1:18082"
	listen    = "0.0.0.0:8443"
)

func copyConn(dst io.Writer, src io.Reader, done chan<- error) {
	_, err := io.Copy(dst, src)
	done <- err
}

func handleConn(client net.Conn) {
	defer client.Close()

	if tcp, ok := client.(*net.TCPConn); ok {
		_ = tcp.SetNoDelay(true)
		_ = tcp.SetReadBuffer(256 * 1024)
		_ = tcp.SetWriteBuffer(256 * 1024)
		_ = tcp.SetKeepAlive(true)
		_ = tcp.SetKeepAlivePeriod(15 * time.Second)
	}

	targetConn, err := net.DialTimeout("tcp", hcrTarget, 5*time.Second)
	if err != nil {
		log.Printf("hcr-tcp-proxy: erro conectar %s: %v", hcrTarget, err)
		return
	}
	defer targetConn.Close()

	if tcp, ok := targetConn.(*net.TCPConn); ok {
		_ = tcp.SetNoDelay(true)
		_ = tcp.SetReadBuffer(256 * 1024)
		_ = tcp.SetWriteBuffer(256 * 1024)
		_ = tcp.SetKeepAlive(true)
		_ = tcp.SetKeepAlivePeriod(15 * time.Second)
	}

	log.Printf("hcr-tcp-proxy: cliente %s -> %s", client.RemoteAddr(), hcrTarget)

	done := make(chan error, 2)
	go copyConn(targetConn, client, done)
	go copyConn(client, targetConn, done)
	<-done
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	listener, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatalf("hcr-tcp-proxy: erro escutando em %s: %v", listen, err)
	}
	defer listener.Close()
	log.Printf("hcr-tcp-proxy: escutando TCP em %s -> %s", listen, hcrTarget)

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("hcr-tcp-proxy: erro accept: %v", err)
			continue
		}
		go handleConn(conn)
	}
}
