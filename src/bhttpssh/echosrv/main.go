package main

import (
	"io"
	"log"
	"net"
	"os"
)

// roteiro deterministico:
// 1 - le exatamente 11 bytes ("HELLO WORLD")
// 2 - escreve banner + eco + padrao(5000)
// 3 - half-close (FIN) e drena o resto
func main() {
	ln, err := net.Listen("tcp", "127.0.0.1:18021")
	if err != nil {
		log.Fatal(err)
	}
	for {
		c, err := ln.Accept()
		if err != nil {
			os.Exit(0)
		}
		go func(c net.Conn) {
			defer c.Close()
			banner := []byte("ECHO-SRV-READY v1\r\n")
			in := make([]byte, 11)
			if _, err := io.ReadFull(c, in); err != nil {
				return
			}
			out := make([]byte, 0, len(banner)+11+5000)
			out = append(out, banner...)
			out = append(out, in...)
			for i := 0; i < 5000; i++ {
				out = append(out, byte(i*31))
			}
			c.Write(out)
			c.(*net.TCPConn).CloseWrite()
			io.Copy(io.Discard, c)
		}(c)
	}
}
