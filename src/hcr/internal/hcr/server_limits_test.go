package hcr

import (
	"net"
	"testing"
)

func TestSessionLimits(t *testing.T) {
	target, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	go func() {
		for {
			connection, err := target.Accept()
			if err != nil {
				return
			}
			go func() {
				defer connection.Close()
				buffer := make([]byte, 1)
				_, _ = connection.Read(buffer)
			}()
		}
	}()
	server, err := NewServer(Config{TargetAddress: target.Addr().String(), Transport: TransportPlain, MaxSessions: 2, MaxSessionsPerIP: 1})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { server.Close(); server.Wait() }()
	create := func(id byte, sourceIP string) Response {
		var request Request
		request.SessionID[0] = id
		return server.create(request, sourceIP)
	}
	if result := create(1, "192.0.2.1"); result.Status != StatusOK {
		t.Fatalf("first session: %v", result)
	}
	if result := create(2, "192.0.2.1"); result.Status != StatusError || string(result.Payload) != "SESSION_LIMIT" {
		t.Fatalf("per-IP limit: %v", result)
	}
	if result := create(3, "192.0.2.2"); result.Status != StatusOK {
		t.Fatalf("second source: %v", result)
	}
	if result := create(4, "192.0.2.3"); result.Status != StatusError || string(result.Payload) != "SESSION_LIMIT" {
		t.Fatalf("global limit: %v", result)
	}
}
