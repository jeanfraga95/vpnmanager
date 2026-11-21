#!/usr/bin/env bash
# Compila o proxy CloudJF (WS + SOCKS4/5 + HTTP CONNECT + decoy + TLS/SNI + token).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/main_http_new.c"
ROOT="$(cd "$DIR/../.." && pwd)"

usage() {
    echo "Uso: $0 [arm64|x86_64|all]"
    exit 1
}

build_arm64() {
    echo "[*] Compilando arm64 nativo -> $ROOT/bin/aarch64/proxy"
    gcc -O2 -Wall -o "$ROOT/bin/aarch64/proxy" "$SRC" -levent -lcrypto
}

build_x86_64() {
    echo "[*] Compilando x86_64 (Docker/qemu) -> $ROOT/bin/x86_64/proxy"
    # --network host + resolv.conf do host são necessários nesta VPS (DNS interno 169.254.169.254)
    docker run --rm --platform linux/amd64 --network host \
        -v /etc/resolv.conf:/etc/resolv.conf:ro \
        -v "$ROOT":/repo -w /repo/src/proxycloudjf ubuntu:22.04 \
        bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gcc libevent-dev libssl-dev && gcc -O2 -Wall -o /repo/bin/x86_64/proxy main_http_new.c -levent -lcrypto'
}

case "${1:-all}" in
    arm64)   build_arm64 ;;
    x86_64)  build_x86_64 ;;
    all)     build_arm64; build_x86_64 ;;
    *)       usage ;;
esac

echo "[OK] Build concluído"
md5sum "$ROOT/bin/aarch64/proxy" "$ROOT/bin/x86_64/proxy" 2>/dev/null || true
