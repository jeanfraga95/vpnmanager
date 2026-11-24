#!/bin/bash
#============================================================
# sshd_auth_guard.sh - Evita que conexoes SSH nao autenticadas
# (backends do BHTTP/XHTTP/WebSocket/HCR) esgotem o MaxStartups.
#
# Nunca mata sessao autenticada: apenas processos [accepted] e
# [priv] orfaos (sem processo filho de sessao).
#============================================================
set -u

SSHD_CONFIG="/etc/ssh/sshd_config"
LOG="/var/log/vpnmanager_healthcheck.log"
RELOAD=0

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') SSHD_GUARD $*" >> "$LOG" 2>/dev/null || true; }

# ── 1) Garante config com timeout e folga de slots ──────────
set_conf() {
    local key="$1" value="$2"
    if grep -qE "^#?${key}[[:space:]]" "$SSHD_CONFIG"; then
        if ! grep -qE "^${key}[[:space:]]+${value}$" "$SSHD_CONFIG"; then
            sed -i -E "s|^#?${key}[[:space:]].*|${key} ${value}|" "$SSHD_CONFIG"
            RELOAD=1
        fi
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
        RELOAD=1
    fi
}

if [ -f "$SSHD_CONFIG" ]; then
    cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.authguard" 2>/dev/null || true
    set_conf LoginGraceTime '60'
    set_conf MaxStartups '300:30:600'
    set_conf MaxSessions '100'
    if [ "$RELOAD" -eq 1 ] && sshd -t >/dev/null 2>&1; then
        systemctl reload ssh >/dev/null 2>&1 || true
        log "config ajustada (LoginGraceTime=60, MaxStartups=300:30:600, MaxSessions=100)"
    fi
fi

# ── 2) Limpa conexoes presas ha mais de 70s ─────────────────
main=$(ps -eo pid,args | awk '/\/usr\/sbin\/sshd -D/ && !/sshd_config_bhttp/ && !/awk/ {print $1; exit}')
if [ -z "$main" ]; then
    exit 0
fi

killed=0
for pid in $(ps -eo pid,ppid,etimes,args | awk -v m="$main" '$2==m && /\[accepted\]/ && $3>70 {print $1}'); do
    kill -9 "$pid" 2>/dev/null && killed=$((killed+1)) || true
done
for pid in $(ps -eo pid,ppid,etimes,args | awk -v m="$main" '$2==m && /\[priv\]/ && $3>120 {print $1}'); do
    if [ "$(pgrep -P "$pid" 2>/dev/null | wc -l)" -eq 0 ]; then
        kill -9 "$pid" 2>/dev/null && killed=$((killed+1)) || true
    fi
done

startups=$(ps -o args= -p "$main" 2>/dev/null | grep -oE '[0-9]+ of [0-9]+-[0-9]+ startups' | awk '{print $1}')
[ -z "$startups" ] && startups=0
if [ "$killed" -gt 0 ]; then
    log "removidas $killed conexoes pre-auth; startups=$startups"
fi

# ── 3) Alerta se ainda proximo do limite ────────────────────
if [ "$startups" -ge 250 ]; then
    log "ALERTA: sshd startups=$startups (limite 300) — verificar backends dos proxies"
fi

exit 0
