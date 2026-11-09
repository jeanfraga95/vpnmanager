#!/bin/bash
#============================================================
# port80_stack.sh - Garante BHTTP + WebSocket + HCR na porta 80
#============================================================
set -e

INSTALL_DIR="/etc/VPNManager"
BHTTP_BIN="$INSTALL_DIR/bin/bhttpssh_dtp"
HCR_BIN="/usr/local/bin/hcr-server"
DISP_BIN="/usr/local/bin/hcr-dispatcher"

mkdir -p "$INSTALL_DIR/conf" "$INSTALL_DIR/bin"

# Certificado HCR (TLS auto)
if [[ ! -f "$INSTALL_DIR/conf/hcr_80_cert.pem" || ! -f "$INSTALL_DIR/conf/hcr_80_key.pem" ]]; then
    openssl req -x509 -newkey rsa:2048 -keyout "$INSTALL_DIR/conf/hcr_80_key.pem" \
        -out "$INSTALL_DIR/conf/hcr_80_cert.pem" -days 3650 -nodes \
        -subj "/CN=hcr" >/dev/null 2>&1
    chmod 600 "$INSTALL_DIR/conf/hcr_80_key.pem"
    chmod 644 "$INSTALL_DIR/conf/hcr_80_cert.pem"
fi

# sshd-bhttp (2223)
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
if [[ ! -f /etc/systemd/system/sshd-bhttp.service ]]; then
    cat > /etc/systemd/system/sshd-bhttp.service << 'SVC'
[Unit]
Description=SSH server for BHTTP tunnel (port 2223)
After=network.target
[Service]
Type=simple
ExecStart=/usr/sbin/sshd -D -f /etc/ssh/sshd_config_bhttp
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SVC
fi
systemctl daemon-reload
systemctl enable sshd-bhttp >/dev/null 2>&1 || true
systemctl start sshd-bhttp >/dev/null 2>&1 || true

# hcr-server (18082, auto TLS)
cat > /etc/systemd/system/hcr-server.service << EOF
[Unit]
Description=HCR TCP relay
After=network-online.target ssh.service sshd.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=$HCR_BIN --listen 127.0.0.1:18082 --target 127.0.0.1:22 --transport auto --tls-cert $INSTALL_DIR/conf/hcr_80_cert.pem --tls-key $INSTALL_DIR/conf/hcr_80_key.pem --max-download-frame 262140 --download-poll-timeout 15s --session-timeout 5m --session-stats-interval 0 --max-connections 4096 --max-sessions 128 --max-sessions-per-ip 128
Restart=on-failure
RestartSec=2s
LimitNOFILE=131072
[Install]
WantedBy=multi-user.target
EOF

# bhttp backend (18083)
cat > /etc/systemd/system/vpnproxy-bhttp-18083.service << SVC
[Unit]
Description=VPNManager BHTTP SSH tunnel port 18083 -> 127.0.0.1:2223
After=network.target
[Service]
User=root
ExecStart=$BHTTP_BIN --port 18083 --static-target 127.0.0.1:2223 --fallback-target 127.0.0.1:8080 --idle 1h
Restart=always
RestartSec=3
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
SVC

# dispatcher (0.0.0.0:80)
cat > /etc/systemd/system/vpnproxy-bhttp-80.service << EOF
[Unit]
Description=VPNManager BHTTP/HCR/WebSocket dispatcher port 80
After=network.target hcr-server.service vpnproxy-bhttp-18083.service
Wants=hcr-server.service vpnproxy-bhttp-18083.service
[Service]
Type=simple
ExecStart=$DISP_BIN --listen 0.0.0.0:80 --hcr-target 127.0.0.1:18082 --ws-target 127.0.0.1:8080 --bhttp-target 127.0.0.1:18083
Restart=always
RestartSec=2s
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hcr-server vpnproxy-bhttp-18083 vpnproxy-bhttp-80 >/dev/null 2>&1 || true
systemctl restart hcr-server vpnproxy-bhttp-18083 vpnproxy-bhttp-80

# desativa bhttp antigo na 80 se existir
echo "port 80 stack active"
echo "Stack port 80 (WebSocket/BHTTP/HCR) ativo."
