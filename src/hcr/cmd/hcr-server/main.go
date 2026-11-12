package main

import (
	"crypto/tls"
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"bilola/internal/hcr"
)

func main() {
	listen := flag.String("listen", ":8080", "listen address")
	target := flag.String("target", "127.0.0.1:22", "TCP target address")
	transport := flag.String("transport", "auto", "transport: plain, tls, or auto")
	tlsCertificate := flag.String("tls-cert", "", "TLS certificate")
	tlsKey := flag.String("tls-key", "", "TLS private key")
	maxDownloadFrame := flag.Int("max-download-frame", 6144, "maximum target-read frame size")
	downloadPollTimeout := flag.Duration("download-poll-timeout", 8*time.Second, "download long-poll timeout")
	sessionTimeout := flag.Duration("session-timeout", 2*time.Minute, "idle session timeout")
	sessionStatsInterval := flag.Duration("session-stats-interval", 0, "periodic aggregate session statistics (0 disables)")
	maxConnections := flag.Int("max-connections", 2048, "maximum concurrent client connections")
	maxSessions := flag.Int("max-sessions", 32, "maximum concurrent HCR sessions")
	maxSessionsPerIP := flag.Int("max-sessions-per-ip", 16, "maximum concurrent HCR sessions per source IP")
	flag.Parse()

	mode := hcr.TransportMode(strings.ToLower(strings.TrimSpace(*transport)))
	var tlsConfig *tls.Config
	if mode != hcr.TransportPlain {
		if *tlsCertificate == "" || *tlsKey == "" {
			log.Fatal("--tls-cert and --tls-key are required for tls/auto transport")
		}
		certificate, err := tls.LoadX509KeyPair(*tlsCertificate, *tlsKey)
		if err != nil {
			log.Fatalf("load TLS certificate: %v", err)
		}
		tlsConfig = &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{certificate}}
	}
	server, err := hcr.NewServer(hcr.Config{TargetAddress: *target, Transport: mode, TLSConfig: tlsConfig, SessionTimeout: *sessionTimeout, DownloadPollTimeout: *downloadPollTimeout, MaxDownloadFrame: *maxDownloadFrame, SessionStatsInterval: *sessionStatsInterval, MaxConnections: *maxConnections, MaxSessions: *maxSessions, MaxSessionsPerIP: *maxSessionsPerIP, Logger: log.Default()})
	if err != nil {
		log.Fatal(err)
	}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("HCR listening (%s) on %s -> %s", mode, listener.Addr(), *target)
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-stop:
	case err := <-done:
		if err != nil {
			log.Printf("HCR server stopped: %v", err)
		}
	}
	_ = listener.Close()
	server.Close()
	server.Wait()
}
