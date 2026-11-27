#!/bin/bash
#============================================================
# healthcheck.sh - Verifica e reinicia servicos VPNManager mortos
#============================================================
INSTALL_DIR="/etc/VPNManager"
LOG="/var/log/vpnmanager_healthcheck.log"

# Lista de servicos criticos (podem nao existir em todas instalacoes)
CRITICAL_SVCS="vpnproxy-unified vpnproxy-unified-8080 vpnproxy-xhttp-8443 hcr-server sshd-bhttp checkuser"

# Garante que conexoes SSH pre-auth nao esgotem os slots (4 proxies usam a 22).
if [[ -x "$INSTALL_DIR/modules/sshd_auth_guard.sh" ]]; then
    bash "$INSTALL_DIR/modules/sshd_auth_guard.sh" >/dev/null 2>&1 || true
fi

for sn in $CRITICAL_SVCS; do
    # Ignora servicos nao instalados
    systemctl cat "$sn" >/dev/null 2>&1 || continue
    # Unidade mascarada foi desativada de proposito (ex.: porta 80
    # pertence ao proto-server). Nao ressuscitar.
    systemctl show -p LoadState "$sn" 2>/dev/null | grep -q '^LoadState=masked$' && continue
    if ! systemctl is-active --quiet "$sn" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') REINICIANDO $sn" >> "$LOG"
        systemctl restart "$sn" >/dev/null 2>&1 || true
    fi
done


# Garante que as portas avulsas nao voltem: a unica entrada publica e a 80.
for sn in vpnproxy-hcr-tcp vpnproxy-hcr-quic vpnproxy-bhttp-18083 vpnproxy-port80 hcr-dispatcher nginx; do
    systemctl stop "$sn" >/dev/null 2>&1 || true
    systemctl disable "$sn" >/dev/null 2>&1 || true
done

# Limpa log antigo (>7 dias)
if [[ -f "$LOG" ]]; then
    find /var/log -name 'vpnmanager_healthcheck.log*' -mtime +7 -delete 2>/dev/null || true
fi
