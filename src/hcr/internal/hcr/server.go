package hcr

import (
	"bufio"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"time"
)

type TransportMode string

const (
	TransportPlain TransportMode = "plain"
	TransportTLS   TransportMode = "tls"
	TransportAuto  TransportMode = "auto"
)

type Config struct {
	TargetAddress        string
	Transport            TransportMode
	TLSConfig            *tls.Config
	SessionTimeout       time.Duration
	DownloadPollTimeout  time.Duration
	MaxDownloadFrame     int
	MaxReplayBytes       int
	MaxConnections       int
	MaxSessions          int
	MaxSessionsPerIP     int
	SessionStatsInterval time.Duration
	Logger               *log.Logger
}

type Server struct {
	config      Config
	mu          sync.Mutex
	sessions    map[SessionID]*session
	closed      chan struct{}
	once        sync.Once
	wait        sync.WaitGroup
	connections chan struct{}
}

type session struct {
	id       SessionID
	token    Token
	target   net.Conn
	sourceIP string

	mu             sync.Mutex
	uploadNext     uint64
	uploadPending  map[uint64][]byte
	downloadNext   uint64
	downloadBase   uint64
	downloadFrames map[uint64][]byte
	replayBytes    int
	lastSeen       time.Time
	closed         bool
	changed        chan struct{}
}

func NewServer(config Config) (*Server, error) {
	if config.TargetAddress == "" {
		config.TargetAddress = "127.0.0.1:22"
	}
	if config.Transport == "" {
		config.Transport = TransportAuto
	}
	if config.Transport != TransportPlain && config.Transport != TransportTLS && config.Transport != TransportAuto {
		return nil, fmt.Errorf("invalid HCR transport %q", config.Transport)
	}
	if config.Transport != TransportPlain && config.TLSConfig == nil {
		return nil, errors.New("HCR TLS configuration is required for tls/auto transport")
	}
	if config.SessionTimeout <= 0 {
		config.SessionTimeout = 2 * time.Minute
	}
	if config.DownloadPollTimeout <= 0 {
		config.DownloadPollTimeout = 8 * time.Second
	}
	if config.MaxDownloadFrame <= 0 {
		config.MaxDownloadFrame = 6144
	}
	if config.MaxDownloadFrame > MaxPayloadSize-4 {
		return nil, errors.New("HCR max download frame exceeds protocol limit")
	}
	if config.MaxReplayBytes <= 0 {
		config.MaxReplayBytes = 256 * 1024 * 1024
	}
	if config.MaxConnections <= 0 {
		config.MaxConnections = 2048
	}
	if config.MaxSessions <= 0 {
		config.MaxSessions = 32
	}
	if config.MaxSessionsPerIP <= 0 {
		if 16 < config.MaxSessions { config.MaxSessionsPerIP = 16 } else { config.MaxSessionsPerIP = config.MaxSessions }
	}
	return &Server{config: config, sessions: make(map[SessionID]*session), closed: make(chan struct{}), connections: make(chan struct{}, config.MaxConnections)}, nil
}

func (server *Server) Serve(listener net.Listener) error {
	server.wait.Add(1)
	go server.cleanupLoop()
	if server.config.SessionStatsInterval > 0 {
		server.wait.Add(1)
		go server.statsLoop()
	}
	for {
		connection, err := listener.Accept()
		if err != nil {
			select {
			case <-server.closed:
				return nil
			default:
				return err
			}
		}
		select {
		case server.connections <- struct{}{}:
		default:
			_ = connection.Close()
			continue
		}
		server.wait.Add(1)
		go func() {
			defer server.wait.Done()
			defer func() { <-server.connections }()
			server.handle(connection)
		}()
	}
}

func tuneConn(conn net.Conn) {
	if tcp, ok := conn.(*net.TCPConn); ok {
		_ = tcp.SetNoDelay(true)
		_ = tcp.SetReadBuffer(256 * 1024)
		_ = tcp.SetWriteBuffer(256 * 1024)
	}
}

func (server *Server) handle(connection net.Conn) {
	tuneConn(connection)
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(30 * time.Second))
	transport, err := server.negotiate(connection)
	if err != nil {
		return
	}
	request, err := ReadRequest(transport)
	if err != nil {
		return
	}
	sourceIP, _, _ := net.SplitHostPort(connection.RemoteAddr().String())
	response := server.process(request, sourceIP)
	_ = WriteResponse(transport, request, response)
}

func (server *Server) negotiate(connection net.Conn) (net.Conn, error) {
	switch server.config.Transport {
	case TransportPlain:
		return connection, nil
	case TransportTLS:
		tlsConnection := tls.Server(connection, server.config.TLSConfig)
		return tlsConnection, tlsConnection.Handshake()
	default:
		reader := bufio.NewReaderSize(connection, RequestHeaderSize)
		first, err := reader.Peek(1)
		if err != nil {
			return nil, err
		}
		buffered := &bufferedConn{Conn: connection, reader: reader}
		if first[0] != 0x16 {
			return buffered, nil
		}
		tlsConnection := tls.Server(buffered, server.config.TLSConfig)
		return tlsConnection, tlsConnection.Handshake()
	}
}

func (server *Server) process(request Request, sourceIP string) Response {
	response := Response{Status: StatusOK, Sequence: request.Sequence}
	if !validPayloadLength(request) {
		return errorResponse(request.Sequence, "INVALID_REQUEST")
	}
	if request.Operation == OperationCreate {
		return server.create(request, sourceIP)
	}
	server.mu.Lock()
	current := server.sessions[request.SessionID]
	server.mu.Unlock()
	if current == nil {
		if request.Operation == OperationClose {
			response.Status = StatusClosed
			return response
		}
		return errorResponse(request.Sequence, "AUTH_FAILED")
	}
	if subtle.ConstantTimeCompare(current.token[:], request.Token[:]) != 1 {
		return errorResponse(request.Sequence, "AUTH_FAILED")
	}
	current.touch()
	switch request.Operation {
	case OperationUpload:
		if err := current.upload(request.Sequence, request.Payload); err != nil {
			return errorResponse(request.Sequence, err.Error())
		}
	case OperationDownload:
		count := 1
		if len(request.Payload) == 2 {
			count = int(binary.BigEndian.Uint16(request.Payload))
		}
		frames, status := current.download(request.Sequence, count, server.config.DownloadPollTimeout)
		response.Status = status
		if status == StatusData {
			response.Payload, _ = EncodeDownloadFrames(frames)
		}
	case OperationAcknowledge:
		current.acknowledge(request.Sequence)
	case OperationClose:
		server.remove(request.SessionID)
	case OperationPing:
		if current.isClosed() {
			response.Status = StatusClosed
		}
	}
	return response
}

func validPayloadLength(request Request) bool {
	switch request.Operation {
	case OperationCreate:
		var zeroToken Token
		var zeroID SessionID
		return request.SessionID != zeroID && request.Sequence == 0 && len(request.Payload) == 0 && request.Token == zeroToken
	case OperationUpload:
		return len(request.Payload) > 0
	case OperationDownload:
		return len(request.Payload) == 0 || (len(request.Payload) == 2 && binary.BigEndian.Uint16(request.Payload) != 0)
	case OperationAcknowledge, OperationClose, OperationPing:
		return len(request.Payload) == 0
	default:
		return false
	}
}

func (server *Server) create(request Request, sourceIP string) Response {
	server.mu.Lock()
	if _, exists := server.sessions[request.SessionID]; exists {
		server.mu.Unlock()
		return errorResponse(request.Sequence, "SESSION_EXISTS")
	}
	if server.sessionLimitReachedLocked(sourceIP) {
		server.mu.Unlock()
		return errorResponse(request.Sequence, "SESSION_LIMIT")
	}
	server.mu.Unlock()
	target, err := net.DialTimeout("tcp", server.config.TargetAddress, 10*time.Second)
	if err != nil {
		return errorResponse(request.Sequence, "TARGET_UNAVAILABLE")
	}
	tuneConn(target)
	current := &session{id: request.SessionID, target: target, sourceIP: sourceIP, uploadPending: make(map[uint64][]byte), downloadFrames: make(map[uint64][]byte), lastSeen: time.Now(), changed: make(chan struct{})}
	if _, err := rand.Read(current.token[:]); err != nil {
		target.Close()
		return errorResponse(request.Sequence, "TOKEN_FAILED")
	}
	server.mu.Lock()
	if _, exists := server.sessions[request.SessionID]; exists {
		server.mu.Unlock()
		target.Close()
		return errorResponse(request.Sequence, "SESSION_EXISTS")
	}
	if server.sessionLimitReachedLocked(sourceIP) {
		server.mu.Unlock()
		target.Close()
		return errorResponse(request.Sequence, "SESSION_LIMIT")
	}
	server.sessions[request.SessionID] = current
	server.mu.Unlock()
	server.wait.Add(1)
	go func() {
		defer server.wait.Done()
		current.readTarget(server.config.MaxDownloadFrame, server.config.MaxReplayBytes)
	}()
	return Response{Status: StatusOK, Sequence: request.Sequence, Payload: append([]byte(nil), current.token[:]...)}
}

func (server *Server) sessionLimitReachedLocked(sourceIP string) bool {
	if len(server.sessions) >= server.config.MaxSessions {
		return true
	}
	count := 0
	for _, current := range server.sessions {
		if current.sourceIP == sourceIP {
			count++
		}
	}
	return count >= server.config.MaxSessionsPerIP
}

func (current *session) upload(sequence uint64, payload []byte) error {
	current.mu.Lock()
	defer current.mu.Unlock()
	if current.closed {
		return errors.New("TARGET_BROKEN")
	}
	if sequence < current.uploadNext {
		return nil
	}
	if _, exists := current.uploadPending[sequence]; !exists {
		current.uploadPending[sequence] = append([]byte(nil), payload...)
	}
	for {
		chunk, exists := current.uploadPending[current.uploadNext]
		if !exists {
			break
		}
		if err := writeAll(current.target, chunk); err != nil {
			current.closeLocked()
			return errors.New("TARGET_BROKEN")
		}
		delete(current.uploadPending, current.uploadNext)
		current.uploadNext++
	}
	return nil
}

func (current *session) readTarget(frameSize, maxReplay int) {
	buffer := make([]byte, frameSize)
	for {
		read, err := current.target.Read(buffer)
		current.mu.Lock()
		if read > 0 {
			frame := append([]byte(nil), buffer[:read]...)
			current.downloadFrames[current.downloadNext] = frame
			current.downloadNext++
			current.replayBytes += len(frame)
			if current.replayBytes > maxReplay {
				current.closeLocked()
			}
			current.notifyLocked()
		}
		if err != nil {
			current.closeLocked()
			current.mu.Unlock()
			return
		}
		current.mu.Unlock()
	}
}

func (current *session) download(sequence uint64, count int, timeout time.Duration) ([][]byte, Status) {
	deadline := time.Now().Add(timeout)
	for {
		current.mu.Lock()
		if sequence < current.downloadBase {
			current.mu.Unlock()
			return nil, StatusClosed
		}
		if _, exists := current.downloadFrames[sequence]; exists {
			frames := make([][]byte, 0, count)
			total := 0
			for offset := 0; offset < count; offset++ {
				frame, ok := current.downloadFrames[sequence+uint64(offset)]
				if !ok || total+4+len(frame) > MaxPayloadSize {
					break
				}
				frames = append(frames, append([]byte(nil), frame...))
				total += 4 + len(frame)
			}
			current.mu.Unlock()
			return frames, StatusData
		}
		if current.closed {
			current.mu.Unlock()
			return nil, StatusClosed
		}
		changed := current.changed
		current.mu.Unlock()
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil, StatusRetry
		}
		timer := time.NewTimer(remaining)
		select {
		case <-changed:
			if !timer.Stop() {
				<-timer.C
			}
		case <-timer.C:
			return nil, StatusRetry
		}
	}
}

func (current *session) acknowledge(sequence uint64) {
	current.mu.Lock()
	defer current.mu.Unlock()
	if sequence < current.downloadBase {
		return
	}
	for index := current.downloadBase; index <= sequence; index++ {
		if frame, exists := current.downloadFrames[index]; exists {
			current.replayBytes -= len(frame)
			delete(current.downloadFrames, index)
		}
		if index == ^uint64(0) {
			break
		}
	}
	current.downloadBase = sequence + 1
}

func (current *session) touch() {
	current.mu.Lock()
	current.lastSeen = time.Now()
	current.mu.Unlock()
}
func (current *session) isClosed() bool {
	current.mu.Lock()
	defer current.mu.Unlock()
	return current.closed
}
func (current *session) notifyLocked() { close(current.changed); current.changed = make(chan struct{}) }
func (current *session) closeLocked() {
	if !current.closed {
		current.closed = true
		current.target.Close()
		current.notifyLocked()
	}
}
func (current *session) close() { current.mu.Lock(); current.closeLocked(); current.mu.Unlock() }

func (server *Server) remove(id SessionID) {
	server.mu.Lock()
	current := server.sessions[id]
	delete(server.sessions, id)
	server.mu.Unlock()
	if current != nil {
		current.close()
	}
}

func (server *Server) cleanupLoop() {
	defer server.wait.Done()
	_interval := server.config.SessionTimeout / 2
	if _interval > 30*time.Second { _interval = 30 * time.Second }
	ticker := time.NewTicker(_interval)
	defer ticker.Stop()
	for {
		select {
		case now := <-ticker.C:
			server.mu.Lock()
			for id, current := range server.sessions {
				current.mu.Lock()
				expired := now.Sub(current.lastSeen) > server.config.SessionTimeout
				current.mu.Unlock()
				if expired {
					delete(server.sessions, id)
					current.close()
				}
			}
			server.mu.Unlock()
		case <-server.closed:
			return
		}
	}
}

func (server *Server) statsLoop() {
	defer server.wait.Done()
	ticker := time.NewTicker(server.config.SessionStatsInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			server.mu.Lock()
			count := len(server.sessions)
			var uploadNext, downloadNext, downloadBase uint64
			var replayBytes int
			for _, current := range server.sessions {
				current.mu.Lock()
				uploadNext += current.uploadNext
				downloadNext += current.downloadNext
				downloadBase += current.downloadBase
				replayBytes += current.replayBytes
				current.mu.Unlock()
			}
			server.mu.Unlock()
			if server.config.Logger != nil {
				server.config.Logger.Printf("HCR session_stats sessions=%d upload_next=%d download_next=%d download_acked=%d replay_bytes=%d", count, uploadNext, downloadNext, downloadBase, replayBytes)
			}
		case <-server.closed:
			return
		}
	}
}

func (server *Server) Close() {
	server.once.Do(func() {
		close(server.closed)
		server.mu.Lock()
		for id, current := range server.sessions {
			delete(server.sessions, id)
			current.close()
		}
		server.mu.Unlock()
	})
}

func (server *Server) Wait() { server.wait.Wait() }

func errorResponse(sequence uint64, code string) Response {
	return Response{Status: StatusError, Sequence: sequence, Payload: []byte(code)}
}

type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (connection *bufferedConn) Read(payload []byte) (int, error) {
	return connection.reader.Read(payload)
}
