#!/bin/bash
#============================================================
# port80_stack.sh - Stack unica da porta 80
#
# BHTTP (TCP/UDP 80) -> fallback interno 19080 -> WebSocket, XHTTP e HCR.
# Sem nginx e sem portas publicas avulsas (8443/8787/8788/9090/9443).
# HCR e XHTTP ficam em loopback; so a 80 (e a 8080 legada) sao publicas.
#
# Uso: bash /etc/VPNManager/modules/port80_stack.sh
#============================================================
set -euo pipefail

INSTALL_DIR="/etc/VPNManager"
BHTTP_BIN="$INSTALL_DIR/bin/bhttpssh_dtp"
WS_BIN="$INSTALL_DIR/bin/proxy"
XHTTP_BIN="$INSTALL_DIR/bin/xhttpssh"
FALLBACK_BIN="$INSTALL_DIR/bin/fallback-proxy/fallback-proxy"
HCR_BIN="/usr/local/bin/hcr-server"

mkdir -p "$INSTALL_DIR/conf" "$INSTALL_DIR/bin" \
         /etc/systemd/system/vpnproxy-xhttp-11443.service.d

# ── Certificados ────────────────────────────────────────────
if [[ ! -f "$INSTALL_DIR/conf/hcr_80_cert.pem" || ! -f "$INSTALL_DIR/conf/hcr_80_key.pem" ]]; then
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$INSTALL_DIR/conf/hcr_80_key.pem" \
        -out "$INSTALL_DIR/conf/hcr_80_cert.pem" -days 3650 -nodes \
        -subj "/CN=hcr" >/dev/null 2>&1
    chmod 600 "$INSTALL_DIR/conf/hcr_80_key.pem"
fi
if [[ ! -f "$INSTALL_DIR/conf/bhttp_80_cert.pem" || ! -f "$INSTALL_DIR/conf/bhttp_80_key.pem" ]]; then
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$INSTALL_DIR/conf/bhttp_80_key.pem" \
        -out "$INSTALL_DIR/conf/bhttp_80_cert.pem" -days 3650 -nodes \
        -subj "/CN=bhttp" >/dev/null 2>&1
    chmod 600 "$INSTALL_DIR/conf/bhttp_80_key.pem"
fi

# ── sshd interno do BHTTP (2223) ─────────────────────────────
if [[ ! -f /etc/ssh/sshd_config_bhttp ]]; then
    cat > /etc/ssh/sshd_config_bhttp << CONF
Port 2223
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_rsa_key
PermitRootLogin yes
PasswordAuthentication yes
AllowTcpForwarding yes
GatewayPorts yes
ClientAliveInterval 30
ClientAliveCountMax 5
MaxSessions 100
LogLevel INFO
UsePAM yes
CONF
fi

cat > /etc/systemd/system/sshd-bhttp.service <<'SVC'
[Unit]
Description=SSH interno do BHTTP (127.0.0.1:2223)
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/sshd -D -f /etc/ssh/sshd_config_bhttp
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

# ── HCR: interno, 127.0.0.1:18082 ───────────────────────────
cat > /etc/systemd/system/hcr-server.service << EOF
[Unit]
Description=HCR interno (127.0.0.1:18082) -> sshd-bhttp
After=network-online.target sshd-bhttp.service
Wants=network-online.target sshd-bhttp.service

[Service]
Type=simple
ExecStart=$HCR_BIN --listen 127.0.0.1:18082 --target 127.0.0.1:2223 --transport auto --tls-cert $INSTALL_DIR/conf/hcr_80_cert.pem --tls-key $INSTALL_DIR/conf/hcr_80_key.pem --max-download-frame 262140 --download-poll-timeout 15s --session-timeout 5m --session-stats-interval 0 --max-connections 4096 --max-sessions 128 --max-sessions-per-ip 128
Restart=on-failure
RestartSec=2s
LimitNOFILE=131072

[Install]
WantedBy=multi-user.target
EOF

# ── WebSocket: 8080 (legado, usado pelo app) ────────────────
cat > /etc/systemd/system/vpnproxy-ws-8080.service << EOF
[Unit]
Description=VPNManager WebSocket 8080 -> 22 (auto-200)
After=network.target ssh.service

[Service]
Type=simple
ExecStart=$WS_BIN --port 8080 --to-port 22 --auto-200
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# ── XHTTP: 11443 restrito a loopback ────────────────────────
cat > /etc/systemd/system/vpnproxy-xhttp-11443.service << EOF
[Unit]
Description=VPNManager XHTTP interno 11443 -> 22 (loopback)
After=network.target ssh.service

[Service]
Type=simple
ExecStart=$XHTTP_BIN --port 11443 --to 22
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/vpnproxy-xhttp-11443.service.d/override.conf <<'CONF'
[Service]
IPAddressAllow=127.0.0.1/32
IPAddressAllow=::1/128
IPAddressDeny=any
CONF

# ── Fallback: 19080 interno -> HCR/WS/XHTTP ─────────────────
cat > /etc/systemd/system/vpnproxy-fallback.service <<'SVC'
[Unit]
Description=VPNManager fallback interno 19080 (HCR + WebSocket + XHTTP)
After=network.target hcr-server.service vpnproxy-ws-8080.service vpnproxy-xhttp-11443.service
Wants=hcr-server.service vpnproxy-ws-8080.service vpnproxy-xhttp-11443.service

[Service]
Type=simple
ExecStart=/etc/VPNManager/bin/fallback-proxy/fallback-proxy
Restart=always
RestartSec=2s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SVC

# ── BHTTP: unico listener publico na 80 ─────────────────────
cat > /etc/systemd/system/vpnproxy-bhttp-80.service << EOF
[Unit]
Description=VPNManager BHTTP publico 80 -> 2223, fallback 19080 (WS/XHTTP/HCR), sem nginx
After=network.target sshd-bhttp.service vpnproxy-fallback.service
Wants=sshd-bhttp.service vpnproxy-fallback.service

[Service]
User=root
ExecStart=$BHTTP_BIN --port 80 --static-target 127.0.0.1:2223 --fallback-target 127.0.0.1:19080 --idle 24h --quic-port 80 --tls-cert $INSTALL_DIR/conf/bhttp_80_cert.pem --tls-key $INSTALL_DIR/conf/bhttp_80_key.pem
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# ── Desliga tudo que abria portas avulsas ───────────────────
OLD_SVCS="vpnproxy-hcr-tcp vpnproxy-hcr-quic vpnproxy-bhttp-18083 vpnproxy-port80 hcr-dispatcher nginx"
for svc in $OLD_SVCS; do
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
done

# ── Aplica stack ────────────────────────────────────────────
systemctl daemon-reload
CORE_SVCS="sshd-bhttp hcr-server vpnproxy-ws-8080 vpnproxy-xhttp-11443 vpnproxy-fallback vpnproxy-bhttp-80"
systemctl enable $CORE_SVCS >/dev/null 2>&1 || true
for svc in $CORE_SVCS; do
    systemctl restart "$svc" >/dev/null 2>&1 || true
done

# ── Comando curto para administracao ────────────────────────
cat > /usr/local/bin/vpnmanager-stack <<'CMD'
#!/bin/bash
echo "Stack VPNManager (porta 80, sem nginx):"
for s in vpnproxy-bhttp-80 vpnproxy-fallback vpnproxy-ws-8080 vpnproxy-xhttp-11443 hcr-server sshd-bhttp; do
    printf '  %-28s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo missing)"
done
echo
echo "Portas publicas: 80/tcp BHTTP+WS+XHTTP+HCR, 8080/tcp WebSocket legado"
echo "Portas fechadas: 8443, 8787, 8788, 9090, 9443, 18082, 11443"
CMD
chmod +x /usr/local/bin/vpnmanager-stack

echo
echo "Stack limpa ativa."
/usr/local/bin/vpnmanager-stack
echo
echo "Reaplicar com: bash $INSTALL_DIR/modules/port80_stack.sh"
