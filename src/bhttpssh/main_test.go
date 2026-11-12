package main

import (
	"bytes"
	"testing"
)

func TestCryptOffMatchesSlice(t *testing.T) {
	key := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	data := make([]byte, 300)
	for i := range data {
		data[i] = byte(i * 7)
	}
	full := crypt(data, key, byte(2), 12345, true)
	for _, off := range []int{0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 137, 295, 299} {
		tail := cryptOff(data, key, byte(2), 12345, true, off)
		want := full[off:]
		if !bytes.Equal(tail, want) {
			t.Fatalf("off=%d: mismatch len=%d vs %d", off, len(tail), len(want))
		}
	}
}

func TestCryptOffBeyond(t *testing.T) {
	key := make([]byte, 16)
	data := []byte{1, 2, 3, 4, 5}
	out := cryptOff(data, key, byte(2), 0, true, 5)
	if len(out) != 0 {
		t.Fatalf("expected empty, got %d", len(out))
	}
	out = cryptOff(data, key, byte(2), 0, true, 6)
	if len(out) != 0 {
		t.Fatalf("expected empty beyond end, got %d", len(out))
	}
}