package main

import (
	"bytes"
	"testing"
)

func TestFindHeaderEnd(t *testing.T) {
	cases := []struct {
		name       string
		in         []byte
		wantPos    int
		wantTerm   int
	}{
		{"crlfcrlf", []byte("GET / HTTP/1.1\r\nHost: x\r\n\r\nBODY"), 23, 4},
		{"lfcrlf", []byte("GET / HTTP/1.1\nHost: x\n\r\nBODY"), 22, 3},
		{"lflf", []byte("GET / HTTP/1.1\nHost: x\n\nBODY"), 22, 2},
		{"none", []byte("GET / HTTP/1.1\r\nHost: x"), -1, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pos, term := findHeaderEnd(tc.in)
			if pos != tc.wantPos || term != tc.wantTerm {
				t.Fatalf("findHeaderEnd() = (%d,%d), want (%d,%d)", pos, term, tc.wantPos, tc.wantTerm)
			}
		})
	}
	// Prioridade do C: CRLFCRLF vence mesmo aparecendo depois de LFLF.
	b := []byte("A\n\nB\r\n\r\nC")
	pos, term := findHeaderEnd(b)
	if pos != 4 || term != 4 {
		t.Fatalf("precedência: got (%d,%d), want (4,4)", pos, term)
	}
}

func TestStartsHTTPExactPrefixes(t *testing.T) {
	for _, s := range []string{"GET /", "POST /", "HEAD /", "PUT /", "CONNECT 1.2.3.4:22 ", "OPTIONS /", "DELETE /", "PATCH /"} {
		if !startsHTTP([]byte(s)) {
			t.Errorf("startsHTTP(%q) = false", s)
		}
	}
	for _, s := range []string{"POLL / HTTP/1.1", "ACL /", "get /", "GET", "PRI * HTTP/2.0", "", "SSH-2.0-X"} {
		if startsHTTP([]byte(s)) {
			t.Errorf("startsHTTP(%q) = true", s)
		}
	}
}

func TestMakeWSAccept(t *testing.T) {
	got := makeWSAccept("dGhlIHNhbXBsZSBub25jZQ==")
	want := "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
	if got != want {
		t.Fatalf("makeWSAccept() = %q, want %q", got, want)
	}
}

func TestHeaderValueAndTokenOK(t *testing.T) {
	hdr := "GET /?token=abc HTTP/1.1\nHost: x\nx-auth-token: abc123\naUtHoRiZaTiOn: bearer tok\r\n\r\n"
	if got := headerValue(hdr, "X-Auth-Token"); got != "abc123" {
		t.Fatalf("X-Auth-Token = %q", got)
	}
	if got := headerValue(hdr, "Authorization"); got != "bearer tok" {
		t.Fatalf("Authorization = %q", got)
	}
	if !tokenOK(hdr, firstLine(hdr), "abc123") {
		t.Fatal("X-Auth-Token token falhou")
	}
	if !tokenOK(hdr, firstLine(hdr), "tok") {
		t.Fatal("Bearer token falhou")
	}
	if !tokenOK(hdr, firstLine(hdr), "abc") {
		t.Fatal("query token falhou")
	}
	if tokenOK(hdr, firstLine(hdr), "errado") {
		t.Fatal("token inválido aceito")
	}
}

func TestStripWSControl(t *testing.T) {
	p := &proxyConn{}
	// npv-x no início é removido.
	if got := p.stripWSControl([]byte("npv-xSSH-2.0-A\r\n")); string(got) != "SSH-2.0-A\r\n" {
		t.Fatalf("npv-x: %q", got)
	}
	// Banner SSH passa integralmente.
	if got := p.stripWSControl([]byte("SSH-2.0-OpenSSH_8.9p1\r\n")); string(got) != "SSH-2.0-OpenSSH_8.9p1\r\n" {
		t.Fatalf("banner: %q", got)
	}
	// Binário com primeiro byte fora de A-Z passa.
	bin := []byte{0x01, 0x02, 0x03, 'A'}
	if got := p.stripWSControl(bin); !bytes.Equal(got, bin) {
		t.Fatalf("binário: %v", got)
	}
	// POLL com header completo é descartado; resto continua.
	in := []byte("POLL / HTTP/1.1\r\nHost: x\r\n\r\nREST")
	if got := p.stripWSControl(in); string(got) != "REST" {
		t.Fatalf("POLL: %q", got)
	}
	// Header parcial entra em modo descarte e não vaza bytes.
	p = &proxyConn{}
	if got := p.stripWSControl([]byte("ACL / HTTP/1.1\r\nHost: x\r\n")); len(got) != 0 || !p.inControl {
		t.Fatalf("parcial: got=%q inControl=%v", got, p.inControl)
	}
	if got := p.stripWSControl([]byte("Cookie: a=b\r\n\r\nDEPOIS")); string(got) != "DEPOIS" || p.inControl {
		t.Fatalf("continuação: got=%q inControl=%v", got, p.inControl)
	}
	// Todos os métodos relevantes são removidos.
	for _, m := range []string{"GET", "POST", "PUT", "PATCH", "PATH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "TRACE", "ACL", "UNLOCK", "LOCK", "MKCOL", "COPY", "MOVE", "PROPFIND", "PROPPATCH", "PROPATH", "POLL", "SEARCH", "MERGE", "REPORT", "POLL / HTTP/1.1"} {
		p = &proxyConn{}
		payload := []byte(m + " / HTTP/1.1\nHost: x\n\nOK")
		if got := p.stripWSControl(payload); string(got) != "OK" {
			t.Errorf("método %q não removido: %q", m, got)
		}
	}
}

func TestFilterClientToSSHCarry(t *testing.T) {
	p := &proxyConn{}
	// Descarta lixo antes do banner, preservando banner fragmentado.
	if got := p.filterClientToSSH([]byte("LIXO-ABCSS")); len(got) != 0 {
		t.Fatalf("pré-banner vazou: %q", got)
	}
	got := p.filterClientToSSH([]byte("H-2.0-Frag\r\n"))
	if string(got) != "SSH-2.0-Frag\r\n" {
		t.Fatalf("banner fragmentado: %q", got)
	}
	// Após o banner, npv-x tardio é removido.
	if got := p.filterClientToSSH([]byte("npv-xDEPOIS")); string(got) != "DEPOIS" {
		t.Fatalf("npv-x tardio: %q", got)
	}
	// Prefixo antes do banner é descartado junto.
	p = &proxyConn{}
	if got := p.filterClientToSSH([]byte("XXXXSSH-2.0-A")); string(got) != "SSH-2.0-A" {
		t.Fatalf("prefixo: %q", got)
	}
}

func TestExtractSNI(t *testing.T) {
	makeHello := func(sni string) []byte {
		extData := []byte{0, byte(3 + len(sni)), 0x00, byte(len(sni) >> 8), byte(len(sni))}
		extData = append(extData, []byte(sni)...)
		ext := []byte{0x00, 0x00, byte(len(extData) >> 8), byte(len(extData))}
		ext = append(ext, extData...)
		body := []byte{0x03, 0x03}
		body = append(body, make([]byte, 32)...)
		body = append(body, 0x00)             // session id length
		body = append(body, 0x00, 0x02, 0x13, 0x01) // cipher suites
		body = append(body, 0x01, 0x00)       // compression
		body = append(body, byte(len(ext)>>8), byte(len(ext)))
		body = append(body, ext...)
		hs := []byte{0x01, byte(len(body) >> 16), byte(len(body) >> 8), byte(len(body))}
		hs = append(hs, body...)
		rec := []byte{0x16, 0x03, 0x01, byte(len(hs) >> 8), byte(len(hs))}
		return append(rec, hs...)
	}
	hello := makeHello("portalrecarga.vivo.com.br")
	got, ok := extractSNI(hello)
	if !ok || got != "portalrecarga.vivo.com.br" {
		t.Fatalf("SNI = %q, %v", got, ok)
	}
	if _, ok := extractSNI(hello[:8]); ok {
		t.Fatal("ClientHello truncado aceito")
	}
	if _, ok := extractSNI([]byte{0x16, 0x03, 0x01, 0x00, 0x00, 0x01}); ok {
		t.Fatal("ClientHello inválido aceito")
	}
}

func TestNormalizeHost(t *testing.T) {
	if got := normalizeHost("127.0.0.1"); got != "127.0.0.1" {
		t.Fatalf("IPv4 = %q", got)
	}
	if got := normalizeHost("portal.vivo.com.br"); got != "127.0.0.1" {
		t.Fatalf("hostname = %q", got)
	}
}
