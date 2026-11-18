package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"io"
	"log"
	"net"
	"time"

	quic "github.com/quic-go/quic-go"
)

var (
	hcrTarget   = "127.0.0.1:18082"
	quicListen  = "0.0.0.0:8443" // UDP 8443 para QUIC (80 TCP ja eh usado pelo proxy80)
)

// quicStreamAdapter adapta *quic.Stream para io.ReadWriter
type quicStreamAdapter struct {
	stream *quic.Stream
}

func (a *quicStreamAdapter) Read(p []byte) (int, error) {
	return a.stream.Read(p)
}

func (a *quicStreamAdapter) Write(p []byte) (int, error) {
	return a.stream.Write(p)
}

func generateSelfSignedCert() *tls.Certificate {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		log.Fatalf("gerar chave RSA: %v", err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkixName(),
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(3650 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		log.Fatalf("criar certificado: %v", err)
	}
	return &tls.Certificate{
		Certificate: [][]byte{certDER},
		PrivateKey:  key,
	}
}

func pkixName() pkix.Name {
	return pkix.Name{
		CommonName:         "hcr-quic-proxy",
		Country:            []string{"BR"},
		Organization:       []string{"VPNManager"},
		OrganizationalUnit: []string{"HCR-QUIC"},
	}
}

func main() {
	cert := generateSelfSignedCert()
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{*cert},
		NextProtos:   []string{"hcr-quic"},
	}

	quicConfig := &quic.Config{
		MaxIdleTimeout:               5 * time.Minute,
		KeepAlivePeriod:              10 * time.Second,
		MaxIncomingStreams:           1000,
		MaxIncomingUniStreams:        -1,
		InitialStreamReceiveWindow:    1 << 20,
		MaxStreamReceiveWindow:        16 << 20,
		InitialConnectionReceiveWindow: 1 << 20,
		MaxConnectionReceiveWindow:    16 << 20,
	}

	listener, err := quic.ListenAddr(quicListen, tlsConfig, quicConfig)
	if err != nil {
		log.Fatalf("QUIC listen addr %s: %v", quicListen, err)
	}
	defer listener.Close()

	log.Printf("hcr-quic-proxy: escutando QUIC na porta UDP %s -> TCP %s", quicListen, hcrTarget)

	for {
		conn, err := listener.Accept(context.Background())
		if err != nil {
			log.Printf("QUIC accept: %v", err)
			continue
		}
		go handleQUICConn(conn)
	}
}

func handleQUICConn(conn *quic.Conn) {
	defer func() { _ = conn.CloseWithError(0, "closing") }()
	remoteAddr := conn.RemoteAddr().String()
	log.Printf("hcr-quic-proxy: nova conexao QUIC de %s", remoteAddr)

	for {
		stream, err := conn.AcceptStream(context.Background())
		if err != nil {
			log.Printf("hcr-quic-proxy: aceitar stream de %s: %v", remoteAddr, err)
			return
		}
		go handleQUICStream(stream, remoteAddr)
	}
}

func handleQUICStream(stream *quic.Stream, remoteAddr string) {
	defer stream.Close()

	targetConn, err := net.DialTimeout("tcp", hcrTarget, 5*time.Second)
	if err != nil {
		log.Printf("hcr-quic-proxy: erro conectar TCP %s: %v", hcrTarget, err)
		return
	}
	defer targetConn.Close()

	if tcp, ok := targetConn.(*net.TCPConn); ok {
		_ = tcp.SetNoDelay(true)
		_ = tcp.SetReadBuffer(256 * 1024)
		_ = tcp.SetWriteBuffer(256 * 1024)
		_ = tcp.SetKeepAlive(true)
		_ = tcp.SetKeepAlivePeriod(20 * time.Second)
	}

	log.Printf("hcr-quic-proxy: stream de %s -> TCP %s", remoteAddr, hcrTarget)

	adapter := &quicStreamAdapter{stream: stream}
	done := make(chan error, 2)
	go func() {
		_, err := io.Copy(targetConn, adapter)
		done <- err
	}()
	go func() {
		_, err := io.Copy(adapter, targetConn)
		done <- err
	}()
	<-done
}
