#!/bin/bash
#============================================================
# healthcheck.sh - Verifica e reinicia servicos VPNManager mortos
#============================================================
INSTALL_DIR="/etc/VPNManager"
LOG="/var/log/vpnmanager_healthcheck.log"

# Lista de servicos criticos (podem nao existir em todas instalacoes)
CRITICAL_SVCS="vpnproxy-bhttp-80 hcr-server vpnproxy-hcr-tcp vpnproxy-hcr-quic vpnproxy-xhttp-10443 vpnproxy-fallback sshd-bhttp checkuser"

for sn in $CRITICAL_SVCS; do
    # Ignora servicos nao instalados
    systemctl cat "$sn" >/dev/null 2>&1 || continue
    if ! systemctl is-active --quiet "$sn" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') REINICIANDO $sn" >> "$LOG"
        systemctl restart "$sn" >/dev/null 2>&1 || true
    fi
done

# Limpa log antigo (>7 dias)
if [[ -f "$LOG" ]]; then
    find /var/log -name 'vpnmanager_healthcheck.log*' -mtime +7 -delete 2>/dev/null || true
fi
