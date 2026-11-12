package hcr

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

const (
	Version            = 1
	RequestHeaderSize  = 62
	ResponseHeaderSize = 14
	MaxPayloadSize     = 256 * 1024
)

type Operation byte

const (
	OperationCreate      Operation = 1
	OperationUpload      Operation = 2
	OperationDownload    Operation = 3
	OperationAcknowledge Operation = 4
	OperationClose       Operation = 5
	OperationPing        Operation = 6
)

type Status byte

const (
	StatusOK Status = iota
	StatusData
	StatusRetry
	StatusClosed
	StatusError
)

type SessionID [16]byte
type Token [32]byte

type Request struct {
	Operation Operation
	SessionID SessionID
	Token     Token
	Sequence  uint64
	Payload   []byte
}

type Response struct {
	Status   Status
	Sequence uint64
	Payload  []byte
}

func (operation Operation) Valid() bool {
	return operation >= OperationCreate && operation <= OperationPing
}

func ReadRequest(reader io.Reader) (Request, error) {
	var request Request
	header := make([]byte, RequestHeaderSize)
	if _, err := io.ReadFull(reader, header); err != nil {
		return request, err
	}
	request.Operation = Operation(header[0])
	if !request.Operation.Valid() || header[1] != Version {
		return request, errors.New("invalid HCR request header")
	}
	copy(request.SessionID[:], header[2:18])
	copy(request.Token[:], header[18:50])
	request.Sequence = binary.BigEndian.Uint64(header[50:58])
	length := binary.BigEndian.Uint32(header[58:62])
	if length > MaxPayloadSize {
		return request, fmt.Errorf("HCR request payload is too large: %d", length)
	}
	request.Payload = make([]byte, int(length))
	if _, err := io.ReadFull(reader, request.Payload); err != nil {
		return request, err
	}
	obfuscate(request.Payload, request.SessionID, request.Operation, request.Sequence, 0)
	return request, nil
}

func WriteRequest(writer io.Writer, request Request) error {
	if !request.Operation.Valid() || len(request.Payload) > MaxPayloadSize {
		return errors.New("invalid HCR request")
	}
	header := make([]byte, RequestHeaderSize)
	header[0], header[1] = byte(request.Operation), Version
	copy(header[2:18], request.SessionID[:])
	copy(header[18:50], request.Token[:])
	binary.BigEndian.PutUint64(header[50:58], request.Sequence)
	binary.BigEndian.PutUint32(header[58:62], uint32(len(request.Payload)))
	payload := append([]byte(nil), request.Payload...)
	obfuscate(payload, request.SessionID, request.Operation, request.Sequence, 0)
	return writeAll(writer, header, payload)
}

func ReadResponse(reader io.Reader, request Request) (Response, error) {
	var response Response
	header := make([]byte, ResponseHeaderSize)
	if _, err := io.ReadFull(reader, header); err != nil {
		return response, err
	}
	response.Status = Status(header[0])
	if response.Status > StatusError || header[1] != Version {
		return response, errors.New("invalid HCR response header")
	}
	response.Sequence = binary.BigEndian.Uint64(header[2:10])
	length := binary.BigEndian.Uint32(header[10:14])
	if length > MaxPayloadSize {
		return response, fmt.Errorf("HCR response payload is too large: %d", length)
	}
	response.Payload = make([]byte, int(length))
	if _, err := io.ReadFull(reader, response.Payload); err != nil {
		return response, err
	}
	obfuscate(response.Payload, request.SessionID, request.Operation, response.Sequence, 1)
	return response, nil
}

func WriteResponse(writer io.Writer, request Request, response Response) error {
	if response.Status > StatusError || len(response.Payload) > MaxPayloadSize {
		return errors.New("invalid HCR response")
	}
	header := make([]byte, ResponseHeaderSize)
	header[0], header[1] = byte(response.Status), Version
	binary.BigEndian.PutUint64(header[2:10], response.Sequence)
	binary.BigEndian.PutUint32(header[10:14], uint32(len(response.Payload)))
	payload := append([]byte(nil), response.Payload...)
	obfuscate(payload, request.SessionID, request.Operation, response.Sequence, 1)
	return writeAll(writer, header, payload)
}

func obfuscate(payload []byte, sessionID SessionID, operation Operation, sequence uint64, direction byte) {
	var seed [30]byte
	copy(seed[:16], sessionID[:])
	seed[16] = byte(operation)
	binary.BigEndian.PutUint64(seed[17:25], sequence)
	seed[25] = direction
	for block, offset := uint32(0), 0; offset < len(payload); block, offset = block+1, offset+sha256.Size {
		binary.BigEndian.PutUint32(seed[26:30], block)
		key := sha256.Sum256(seed[:])
		limit := len(payload) - offset
		if limit > sha256.Size {
			limit = sha256.Size
		}
		for index := 0; index < limit; index++ {
			payload[offset+index] ^= key[index]
		}
	}
}

func EncodeDownloadFrames(frames [][]byte) ([]byte, error) {
	length := 0
	for _, frame := range frames {
		if len(frame) > MaxPayloadSize-4 || length > MaxPayloadSize-4-len(frame) {
			return nil, errors.New("HCR download batch is too large")
		}
		length += 4 + len(frame)
	}
	result := make([]byte, 0, length)
	var encoded [4]byte
	for _, frame := range frames {
		binary.BigEndian.PutUint32(encoded[:], uint32(len(frame)))
		result = append(result, encoded[:]...)
		result = append(result, frame...)
	}
	return result, nil
}

func DecodeDownloadFrames(payload []byte) ([][]byte, error) {
	var frames [][]byte
	for len(payload) != 0 {
		if len(payload) < 4 {
			return nil, errors.New("truncated HCR download frame")
		}
		length := int(binary.BigEndian.Uint32(payload[:4]))
		payload = payload[4:]
		if length > len(payload) {
			return nil, errors.New("invalid HCR download frame length")
		}
		frames = append(frames, append([]byte(nil), payload[:length]...))
		payload = payload[length:]
	}
	return frames, nil
}

func writeAll(writer io.Writer, chunks ...[]byte) error {
	for _, chunk := range chunks {
		for len(chunk) != 0 {
			written, err := writer.Write(chunk)
			if err != nil {
				return err
			}
			if written == 0 {
				return io.ErrShortWrite
			}
			chunk = chunk[written:]
		}
	}
	return nil
}
