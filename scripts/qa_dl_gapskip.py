#!/usr/bin/env python3
"""QA: ordinal perdido nao pode travar o download (bail storm).

Ancora a sessao com ordinais 0..3, 'perde' o ordinal 4 e pede 5..7.
Antes do patch, nextIdx ficava preso em 4 e todos os pedidos bailavam
(DL out congelava). Depois, o proxy comita 4 como vazio e entrega 5..7
em ~200ms, preservando a ordem dos bytes.
"""
import hashlib
import socket
import struct
import sys
import threading
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19302
ECHO = int(sys.argv[2]) if len(sys.argv) > 2 else 19301
HOST = '127.0.0.1'
KEY = bytes(range(17, 33))
CHUNK = 1024
N = 8


def crypt(data, typ, seq, resp=False):
    if not data:
        return b''
    seed = bytearray(KEY[:16])
    seed.append(typ)
    seed += struct.pack('>Q', seq)
    seed.append(1 if resp else 0)
    out = bytearray(len(data))
    i, ctr = 0, 0
    while i < len(data):
        ks = hashlib.sha256(bytes(seed) + struct.pack('>I', ctr)).digest()
        n = min(32, len(data) - i)
        for j in range(n):
            out[i + j] = data[i + j] ^ ks[j]
        i += n
        ctr += 1
    return bytes(out)


def frame(typ, seq, payload=b''):
    return bytes([typ]) + KEY + struct.pack('>Q', seq) + struct.pack('>I', len(payload)) + crypt(payload, typ, seq)


def download_frame(seq, size):
    return bytes([2]) + KEY + struct.pack('>Q', seq) + struct.pack('>I', size)


def recvn(s, n, secs=4.0):
    s.settimeout(secs)
    out = b''
    end = time.time() + secs
    while len(out) < n and time.time() < end:
        try:
            d = s.recv(n - len(out))
        except (socket.timeout, OSError):
            break
        if not d:
            break
        out += d
    return out


def read_resp(s, typ, seq, secs=4.0):
    h = recvn(s, 5, secs)
    if len(h) < 5:
        raise ValueError('resposta curta: %r' % h[:20])
    status = h[0]
    n = struct.unpack('>I', h[1:5])[0]
    if n > 200000:
        raise ValueError('tamanho absurdo %d' % n)
    body = recvn(s, n, secs)
    if len(body) < n:
        raise ValueError('body curto %d/%d' % (len(body), n))
    return status, crypt(body, typ, seq, True)


def echo_server(port):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, port))
    srv.listen(32)
    while True:
        c, _ = srv.accept()

        def handle(c=c):
            try:
                while True:
                    d = c.recv(65536)
                    if not d:
                        break
                    c.sendall(d)
            except Exception:
                pass
            finally:
                c.close()
        threading.Thread(target=handle, daemon=True).start()


def pattern(i, size):
    return bytes(((i * 37 + j * 13) & 0xff) for j in range(size))


def pull(k):
    s = socket.create_connection((HOST, PORT), 5)
    s.settimeout(5)
    s.sendall(download_frame(k, CHUNK))
    st, data = read_resp(s, 2, k, 4)
    s.close()
    if st not in (0, 2):
        raise ValueError('status %d no pull %d' % (st, k))
    return data


def main():
    original = b''.join(pattern(i + 1, CHUNK) for i in range(N))
    up = socket.create_connection((HOST, PORT), 5)
    up.settimeout(10)
    for i in range(N):
        up.sendall(frame(1, i, pattern(i + 1, CHUNK)))
        st, _ = read_resp(up, 1, i, 10)
        if st not in (0, 2):
            raise ValueError('upload ACK status %d seq=%d' % (st, i))
    time.sleep(0.4)

    # ancora e serve 0..3
    for k in range(4):
        d = pull(k)
        if d != pattern(k + 1, CHUNK):
            raise ValueError('pull %d divergiu (esperado pattern %d)' % (k, k + 1))

    # ordinal 4 e' perdido de proposito; pede 5..7 em paralelo
    got, errors = {}, []
    ts0 = time.time()

    def worker(k):
        try:
            got[k] = pull(k)
        except Exception as e:
            errors.append((k, repr(e)))

    ts = [threading.Thread(target=worker, args=(k,)) for k in (5, 6, 7)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(8)
    elapsed = time.time() - ts0
    up.close()

    sizes = [len(got.get(k, b'')) for k in (5, 6, 7)]
    stream = b''.join(got.get(k, b'') for k in (5, 6, 7))
    esperado = original[4 * CHUNK:7 * CHUNK]
    ok = not errors and all(n == CHUNK for n in sizes) and stream == esperado and elapsed < 3.0
    print('[INFO] tamanhos (5,6,7):', sizes, 'elapsed=%.3fs' % elapsed)
    print('[INFO] bytes=%d/%d erros=%d' % (len(stream), len(esperado), len(errors)))
    if errors:
        print('[ERRO]', errors[:3])
    if ok:
        print('[PASS] gap sem bail storm: download seguiu em ordem')
    else:
        print('[FAIL] gap travou download (bail storm/congelamento)')
    return ok


if __name__ == '__main__':
    threading.Thread(target=echo_server, args=(ECHO,), daemon=True).start()
    time.sleep(0.3)
    sys.exit(0 if main() else 1)
