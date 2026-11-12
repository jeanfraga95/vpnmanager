//============================================================
// bhttpcli - proxy BHTTP <-> stdio para validar o servidor com
// o cliente ssh REAL (estilo ProxyCommand):
//
//   ssh -o ProxyCommand='./bhttpcli HOST:PORTA %h %p' ...
//
// stdin  -> frames de upload (seq crescente, chunks <= 32768)
// stdout <- downloads sequenciais (tipo 2) ate o fim do stream
//============================================================
package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

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

func writeFrame(c net.Conn, key []byte, typ byte, seq uint64, length uint32, payload []byte) error {
	hdr := make([]byte, 29)
	hdr[0] = typ
	copy(hdr[1:17], key)
	binary.BigEndian.PutUint64(hdr[17:25], seq)
	binary.BigEndian.PutUint32(hdr[25:29], length)
	if _, err := c.Write(hdr); err != nil {
		return err
	}
	if len(payload) > 0 {
		if _, err := c.Write(crypt(payload, key, typ, seq, false)); err != nil {
			return err
		}
	}
	return nil
}

func readResp(c net.Conn, key []byte, typ byte, seq uint64) ([]byte, error) {
	h := make([]byte, 5)
	if _, err := io.ReadFull(c, h); err != nil {
		return nil, err
	}
	status := h[0]
	n := binary.BigEndian.Uint32(h[1:5])
	body := make([]byte, n)
	if n > 0 {
		if _, err := io.ReadFull(c, body); err != nil {
			return nil, err
		}
	}
	if status != 0 && status != 2 {
		return nil, fmt.Errorf("status %d: %q", status, string(body))
	}
	return crypt(body, key, typ, seq, true), nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "use: bhttpcli HOST:PORTA")
		os.Exit(2)
	}
	c, err := net.Dial("tcp", os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "dial:", err)
		os.Exit(1)
	}
	defer c.Close()
	key := make([]byte, 16)
	rand.Read(key)

	// abre a sessao (upload seq0 vazio, como pj.a)
	if err := writeFrame(c, key, 1, 0, 0, nil); err != nil {
		fmt.Fprintln(os.Stderr, "sessao:", err)
		os.Exit(1)
	}
	if _, err := readResp(c, key, 1, 0); err != nil {
		fmt.Fprintln(os.Stderr, "sessao ack:", err)
		os.Exit(1)
	}

	// conexao dedicada ao UPLOAD (como ok.java) e outra ao DOWNLOAD
	// (como wj.java): respostas sao correlacionadas por ordem em
	// cada conexao, entao nao podem ser compartilhadas
	up, err := net.Dial("tcp", os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "dial up:", err)
		os.Exit(1)
	}
	defer up.Close()
	if err := writeFrame(up, key, 1, 0, 0, nil); err != nil {
		fmt.Fprintln(os.Stderr, "sessao up:", err)
		os.Exit(1)
	}
	if _, err := readResp(up, key, 1, 0); err != nil {
		fmt.Fprintln(os.Stderr, "sessao up ack:", err)
		os.Exit(1)
	}

	// uploader: stdin -> uploads na conexao dedicada
	go func() {
		seq := uint64(1)
		buf := make([]byte, 32768)
		for {
			n, err := os.Stdin.Read(buf)
			if n > 0 {
				if werr := writeFrame(up, key, 1, seq, uint32(n), buf[:n]); werr == nil {
					_, rerr := readResp(up, key, 1, seq)
					if rerr == nil {
						seq++
						continue
					}
					err = rerr
				} else {
					err = werr
				}
			}
			if err != nil {
				return // fim do stdin: para de enviar, sessao continua
			}
		}
	}()

	// downloader: downloads sequenciais -> stdout, ACK periodico
	k := uint64(0)
	for {
		if err := writeFrame(c, key, 2, k, 1350, nil); err != nil {
			break
		}
		b, err := readResp(c, key, 2, k)
		if err != nil {
			break // fim do stream
		}
		if _, err := os.Stdout.Write(b); err != nil {
			break
		}
		k++
		if k%194 == 0 {
			writeFrame(c, key, 4, k-1, 0, nil)
			readResp(c, key, 4, k-1)
		}
	}
	// drena o uploader antes de sair
	time.Sleep(200 * time.Millisecond)
}
