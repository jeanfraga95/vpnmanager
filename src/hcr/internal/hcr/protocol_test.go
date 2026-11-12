package hcr

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func TestRequestAndResponseRoundTrip(t *testing.T) {
	var id SessionID
	var token Token
	for index := range id {
		id[index] = byte(index + 1)
	}
	for index := range token {
		token[index] = byte(0x80 + index)
	}
	request := Request{Operation: OperationUpload, SessionID: id, Token: token, Sequence: 0x0102030405060708, Payload: []byte("HCR payload")}
	var wire bytes.Buffer
	if err := WriteRequest(&wire, request); err != nil {
		t.Fatal(err)
	}
	if wire.Len() != RequestHeaderSize+len(request.Payload) {
		t.Fatalf("request length = %d", wire.Len())
	}
	if bytes.Equal(wire.Bytes()[RequestHeaderSize:], request.Payload) {
		t.Fatal("request payload was not obfuscated")
	}
	decoded, err := ReadRequest(&wire)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Operation != request.Operation || decoded.SessionID != request.SessionID || decoded.Token != request.Token || decoded.Sequence != request.Sequence || !bytes.Equal(decoded.Payload, request.Payload) {
		t.Fatalf("decoded request mismatch: %#v", decoded)
	}

	response := Response{Status: StatusData, Sequence: request.Sequence, Payload: []byte("target data")}
	if err := WriteResponse(&wire, request, response); err != nil {
		t.Fatal(err)
	}
	decodedResponse, err := ReadResponse(&wire, request)
	if err != nil {
		t.Fatal(err)
	}
	if decodedResponse.Status != response.Status || decodedResponse.Sequence != response.Sequence || !bytes.Equal(decodedResponse.Payload, response.Payload) {
		t.Fatalf("decoded response mismatch: %#v", decodedResponse)
	}
}

func TestObfuscationVector(t *testing.T) {
	idBytes, _ := hex.DecodeString("000102030405060708090a0b0c0d0e0f")
	var id SessionID
	copy(id[:], idBytes)
	payload := []byte("wire-compatible-hcr")
	obfuscate(payload, id, OperationDownload, 42, 1)
	const expected = "37b85cd272c8effd7156aa7d90737a60d7b271"
	if got := hex.EncodeToString(payload); got != expected {
		t.Fatalf("obfuscation = %s", got)
	}
	obfuscate(payload, id, OperationDownload, 42, 1)
	if string(payload) != "wire-compatible-hcr" {
		t.Fatalf("obfuscation is not reversible: %q", payload)
	}
}

func TestDownloadFrameCodec(t *testing.T) {
	want := [][]byte{[]byte("one"), {}, []byte("three")}
	payload, err := EncodeDownloadFrames(want)
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeDownloadFrames(payload)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(want) {
		t.Fatalf("frame count = %d", len(got))
	}
	for index := range want {
		if !bytes.Equal(got[index], want[index]) {
			t.Fatalf("frame %d mismatch", index)
		}
	}
}
