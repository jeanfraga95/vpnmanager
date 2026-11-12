//============================================================
// clienttest - cliente BHTTP minimo que replica o app DTunnel
// (pj/c8/hk/wj) para validar o servidor bhttpssh:
//   1) probe 512B e 70000B (echo exato, multi-bloco SHA)
//   2) upload seq0 vazio (abertura de sessao do pj.a)
//   3) uploads FORA DE ORDEM (seq2 antes de seq1)
//   4) downloads sequenciais ate EOF -> conteudo exato esperado
//   5) batch tipo 3 re-pedindo chunks ja servidos -> mesmos bytes
//   6) ACK chunk 2 -> chunk 3 ainda servivel; chunk 0 -> fecha
//============================================================
package main

import (
	"bytes"
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

// padrao de probe do app (tv0.k): "BHP1" + flag + tipo + len + filler
func probePattern(typ byte, size int) []byte {
	sz := size
	if sz < 10 {
		sz = 10
	}
	p := make([]byte, sz)
	copy(p, []byte{66, 72, 80, 49})
	p[4] = 1
	p[5] = typ
	binary.BigEndian.PutUint32(p[6:10], uint32(size))
	for i := 10; i < sz; i++ {
		p[i] = byte(i * 31)
	}
	return p
}

func must(err error, what string) {
	if err != nil {
		fmt.Println("FALHA", what+":", err)
		os.Exit(1)
	}
}

func main() {
	addr := os.Args[1]
	key := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}

	c, err := net.Dial("tcp", addr)
	must(err, "dial")
	defer c.Close()

	// 1) probes
	for _, size := range []int{512, 70000} {
		pat := probePattern(0, size)
		must(writeFrame(c, key, 0, uint64(len(pat)), uint32(len(pat)), pat), "probe write")
		echo, err := readResp(c, key, 0, uint64(len(pat)))
		must(err, "probe read")
		if !bytes.Equal(echo, pat) {
			fmt.Printf("FALHA probe echo %dB\n", size)
			os.Exit(1)
		}
		fmt.Printf("OK probe echo %dB\n", size)
	}

	// 2) abertura de sessao: upload seq0 vazio
	must(writeFrame(c, key, 1, 0, 0, nil), "upload seq0")
	_, err = readResp(c, key, 1, 0)
	must(err, "ack seq0")
	fmt.Println("OK upload ack seq0")

	// 3) uploads fora de ordem: seq2 antes de seq1
	must(writeFrame(c, key, 1, 2, 5, []byte("WORLD")), "upload seq2")
	_, err = readResp(c, key, 1, 2)
	must(err, "ack seq2")
	must(writeFrame(c, key, 1, 1, 6, []byte("HELLO ")), "upload seq1")
	_, err = readResp(c, key, 1, 1)
	must(err, "ack seq1")
	fmt.Println("OK uploads fora de ordem")

	time.Sleep(500 * time.Millisecond) // deixa o eco estabilizar

	// 4) downloads sequenciais ate o servidor fechar (EOF do stream)
	banner := []byte("ECHO-SRV-READY v1\r\n")
	expected := make([]byte, 0, len(banner)+11+5000)
	expected = append(expected, banner...)
	expected = append(expected, []byte("HELLO WORLD")...)
	for i := 0; i < 5000; i++ {
		expected = append(expected, byte(i*31))
	}
	var all []byte
	k := uint64(0)
	for {
		must(writeFrame(c, key, 2, k, 1350, nil), "dl write")
		b, err := readResp(c, key, 2, k)
		if err != nil {
			fmt.Printf("(stream fechado no chunk %d: %v)\n", k, err)
			break
		}
		all = append(all, b...)
		k++
		if int64(len(all)) > int64(len(expected)) {
			fmt.Println("FALHA: dados a mais no download")
			os.Exit(1)
		}
	}
	if !bytes.Equal(all, expected) {
		fmt.Printf("FALHA: conteudo difere (got %d bytes, want %d)\n", len(all), len(expected))
		for i := 0; i < len(all) && i < len(expected); i++ {
			if all[i] != expected[i] {
				fmt.Printf("primeira diferenca no offset %d\n", i)
				break
			}
		}
		os.Exit(1)
	}
	fmt.Printf("OK download encadeado completo (%d bytes, %d chunks)\n", len(all), k)

	// 5) batch re-pedindo chunks 1..3 (sem ACK => nada aparado):
	//    fronteiras deterministicas pois chunk0 veio completo (1350)
	c2, err := net.Dial("tcp", addr)
	must(err, "dial2")
	defer c2.Close()
	batch := make([]byte, 6)
	binary.BigEndian.PutUint32(batch[0:4], 1350)
	binary.BigEndian.PutUint16(batch[4:6], 3)
	must(writeFrame(c2, key, 3, 1, 6, batch), "batch write")
	var reb []byte
	for i := 0; i < 3; i++ {
		b, err := readResp(c2, key, 3, uint64(1+i))
		must(err, fmt.Sprintf("batch resp %d", i))
		reb = append(reb, b...)
	}
	if !bytes.Equal(reb, expected[1350:]) {
		fmt.Println("FALHA: batch retry difere do original")
		os.Exit(1)
	}
	fmt.Println("OK batch retry consistente (chunks 1..3)")

	// 6) ACK do chunk 2 -> trim abaixo de 4050:
	//    - chunk 3 ainda servivel
	//    - chunk 0 deve fechar a conexao (regiao liberada)
	must(writeFrame(c2, key, 4, 2, 0, nil), "ack write")
	_, err = readResp(c2, key, 4, 2)
	must(err, "ack resp")
	must(writeFrame(c2, key, 2, 3, 1350, nil), "dl pos-ack write")
	b, err := readResp(c2, key, 2, 3)
	must(err, "dl pos-ack")
	if !bytes.Equal(b, expected[4050:]) {
		fmt.Println("FALHA: chunk 3 pos-ACK difere")
		os.Exit(1)
	}
	fmt.Println("OK chunk 3 servivel apos ACK")

	c3, err := net.Dial("tcp", addr)
	must(err, "dial3")
	defer c3.Close()
	must(writeFrame(c3, key, 2, 0, 1350, nil), "dl aparado write")
	_, err = readResp(c3, key, 2, 0)
	if err == nil {
		fmt.Println("FALHA: chunk 0 deveria ter sido aparado (fechar)")
		os.Exit(1)
	}
	fmt.Println("OK chunk 0 aparado apos ACK (conexao fechada)")

	fmt.Println("TODOS OS TESTES PASSARAM")
}
