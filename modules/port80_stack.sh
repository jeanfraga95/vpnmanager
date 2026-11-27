#!/bin/bash
#============================================================
# port80_stack.sh - Stack unica da porta 80
#
# BHTTP (TCP/UDP 80) -> fallback interno 19080 -> WebSocket, XHTTP e HCR.
# Sem nginx e sem portas publicas avulsas (8787/8788/9090/9443).
# HCR fica em loopback; XHTTP usa 8443 (publico e backend dos proxies).
#
# Uso: bash /etc/VPNManager/modules/port80_stack.sh
# VPNMANAGER_SKIP_PUBLIC=1 cria somente os backends internos (sshd-bhttp,
# HCR e XHTTP), sem abrir 80/8080. Usado quando a 80 pertence a outro
# sistema (ex.: dtproto/proto-server).
#============================================================
set -euo pipefail

SKIP_PUBLIC="${VPNMANAGER_SKIP_PUBLIC:-0}"
INSTALL_DIR="/etc/VPNManager"
BHTTP_BIN="$INSTALL_DIR/bin/bhttpssh_dtp"
WS_BIN="$INSTALL_DIR/bin/proxy"
XHTTP_BIN="$INSTALL_DIR/bin/xhttpssh"
FALLBACK_BIN="$INSTALL_DIR/bin/fallback-proxy/fallback-proxy"
# O binario e instalado em $INSTALL_DIR/bin. O uninstall remove a copia
# antiga em /usr/local/bin; apontar para ela deixava hcr-server em 203/EXEC.
HCR_BIN="$INSTALL_DIR/bin/hcr-server"

mkdir -p "$INSTALL_DIR/conf" "$INSTALL_DIR/bin" \
         /etc/systemd/system/vpnproxy-xhttp-8443.service.d

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
ClientAliveInterval 10
ClientAliveCountMax 3600
LoginGraceTime 60
MaxStartups 300:30:600
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
if [[ "$SKIP_PUBLIC" != "1" ]]; then
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
fi

# ── XHTTP: 8443 (publico e tambem backend dos proxies 80/8080) ─
# Remove a unit antiga em 11443 e qualquer drop-in que restringisse
# o XHTTP a loopback (versoes anteriores usavam 11443 somente interno).
systemctl stop vpnproxy-xhttp-11443 >/dev/null 2>&1 || true
systemctl disable vpnproxy-xhttp-11443 >/dev/null 2>&1 || true
rm -f /etc/systemd/system/vpnproxy-xhttp-11443.service
rm -rf /etc/systemd/system/vpnproxy-xhttp-11443.service.d
rm -f /etc/systemd/system/vpnproxy-xhttp-8443.service.d/override.conf

cat > /etc/systemd/system/vpnproxy-xhttp-8443.service << EOF
[Unit]
Description=VPNManager XHTTP 8443 -> 22
After=network.target ssh.service

[Service]
Type=simple
ExecStart=$XHTTP_BIN --port 8443 --to 22
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# ── Fallback: 19080 interno -> HCR/WS/XHTTP ─────────────────
if [[ "$SKIP_PUBLIC" != "1" ]]; then
cat > /etc/systemd/system/vpnproxy-fallback.service <<'SVC'
[Unit]
Description=VPNManager fallback interno 19080 (HCR + WebSocket + XHTTP)
After=network.target hcr-server.service vpnproxy-ws-8080.service vpnproxy-xhttp-8443.service
Wants=hcr-server.service vpnproxy-ws-8080.service vpnproxy-xhttp-8443.service

[Service]
Type=simple
ExecStart=/etc/VPNManager/bin/fallback-proxy/fallback-proxy
Restart=always
RestartSec=2s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SVC
fi

# ── BHTTP: unico listener publico na 80 ─────────────────────
if [[ "$SKIP_PUBLIC" != "1" ]]; then
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
fi

# ── Desliga tudo que abria portas avulsas ───────────────────
OLD_SVCS="vpnproxy-hcr-tcp vpnproxy-hcr-quic vpnproxy-bhttp-18083 vpnproxy-port80 hcr-dispatcher nginx"
for svc in $OLD_SVCS; do
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
done

# ── Aplica stack ────────────────────────────────────────────
systemctl daemon-reload
CORE_SVCS="sshd-bhttp hcr-server vpnproxy-xhttp-8443"
[[ "$SKIP_PUBLIC" != "1" ]] && \
    CORE_SVCS="$CORE_SVCS vpnproxy-ws-8080 vpnproxy-fallback vpnproxy-bhttp-80"
systemctl enable $CORE_SVCS >/dev/null 2>&1 || true
for svc in $CORE_SVCS; do
    systemctl restart "$svc" >/dev/null 2>&1 || true
done

# ── Comando curto para administracao ────────────────────────
cat > /usr/local/bin/vpnmanager-stack <<'CMD'
#!/bin/bash
echo "Stack VPNManager (sem nginx):"
for s in vpnproxy-unified vpnproxy-unified-8080 vpnproxy-bhttp-80 vpnproxy-fallback vpnproxy-ws-8080 vpnproxy-xhttp-8443 hcr-server sshd-bhttp; do
    [[ -f "/etc/systemd/system/$s.service" ]] || continue
    printf '  %-28s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo missing)"
done
main=$(ps -eo pid,args | awk '/\/usr\/sbin\/sshd -D/ && !/sshd_config_bhttp/ && !/awk/ {print $1; exit}')
startups=$(ps -o args= -p "$main" 2>/dev/null | grep -oE '[0-9]+ of [0-9]+-[0-9]+ startups' | awk '{print $1}')
[ -z "$startups" ] && startups=0
preauth=$(ps -eo pid,ppid,etimes,args | awk -v m="$main" '$2==m && /\[accepted\]/ {n++} END {print n+0}')
printf '  %-28s %s (%s pre-auth)\n' "sshd 22" "$startups/300" "$preauth"
mainb=$(ps -eo pid,args | awk '/\/usr\/sbin\/sshd -D -f \/etc\/ssh\/sshd_config_bhttp/ && !/awk/ {print $1; exit}')
startupsb=$(ps -o args= -p "$mainb" 2>/dev/null | grep -oE '[0-9]+ of [0-9]+-[0-9]+ startups' | awk '{print $1}')
[ -z "$startupsb" ] && startupsb=0
preauthb=$(ps -eo pid,ppid,etimes,args | awk -v m="$mainb" '$2==m && /\[accepted\]/ {n++} END {print n+0}')
printf '  %-28s %s (%s pre-auth)\n' "sshd 2223" "$startupsb/300" "$preauthb"
echo
echo "Portas publicas (ver ss -lntp): 80 e/ou 8080/tcp BHTTP+WS+XHTTP+HCR"
echo "Portas internas: 2223 (sshd-bhttp), 18082 (HCR) | XHTTP: 8443"
CMD
chmod +x /usr/local/bin/vpnmanager-stack

echo
echo "Stack limpa ativa."
/usr/local/bin/vpnmanager-stack
echo
echo "Reaplicar com: bash $INSTALL_DIR/modules/port80_stack.sh"
