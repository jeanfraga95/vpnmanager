#!/bin/bash
#============================================================
# sshd_auth_guard.sh - Evita que conexoes SSH nao autenticadas
# esgotem o MaxStartups dos DOIS listeners:
#   - sshd publico  (22)   -> /etc/ssh/sshd_config
#   - sshd BHTTP    (2223) -> /etc/ssh/sshd_config_bhttp
#
# Todos os backends (BHTTP, XHTTP, WebSocket e HCR) autenticam
# nesses sshd. Nunca mata sessao autenticada: apenas processos
# [accepted] e [priv] orfaos (sem filho de sessao).
#============================================================
set -u

LOG="/var/log/vpnmanager_healthcheck.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') SSHD_GUARD $*" >> "$LOG" 2>/dev/null || true; }

# ── 1) Garante config segura nos dois sshd ──────────────────
set_conf() {
    local file="$1" key="$2" value="$3"
    grep -qE "^#?${key}[[:space:]]" "$file" || { echo "${key} ${value}" >> "$file"; return 1; }
    grep -qE "^${key}[[:space:]]+${value}$" "$file" && return 0
    sed -i -E "s|^#?${key}[[:space:]].*|${key} ${value}|" "$file"
    return 1
}

harden() {
    local file="$1" label="$2" changed=0
    [ -f "$file" ] || return 0
    cp -a "$file" "${file}.bak.authguard" 2>/dev/null || true
    set_conf "$file" LoginGraceTime '60'     || changed=1
    set_conf "$file" MaxStartups '300:30:600' || changed=1
    set_conf "$file" MaxSessions '100'       || changed=1
    if [ "$changed" -eq 1 ]; then
        if ! sshd -t -f "$file" >/dev/null 2>&1; then
            log "$label: ERRO sshd -t -f $file — configuracao nao recarregada"
            return 0
        fi
        # SIGHUP reexecuta o sshd sem derrubar sessoes ja autenticadas.
        local pid
        if [ "$file" = "/etc/ssh/sshd_config_bhttp" ]; then
            pid=$(ps -eo pid,args | awk '/\/usr\/sbin\/sshd -D -f \/etc\/ssh\/sshd_config_bhttp/ && !/awk/ {print $1; exit}')
        else
            pid=$(ps -eo pid,args | awk '/\/usr\/sbin\/sshd -D/ && !/sshd_config_bhttp/ && !/awk/ {print $1; exit}')
        fi
        [ -n "$pid" ] && kill -HUP "$pid" 2>/dev/null || true
        log "$label: config ajustada (LoginGraceTime=60, MaxStartups=300:30:600, MaxSessions=100)"
    fi
}

harden /etc/ssh/sshd_config         'sshd 22'
harden /etc/ssh/sshd_config_bhttp   'sshd 2223'

# ── 3) Limpa conexoes presas nos dois listeners ─────────────
cleanup() {
    local main="$1" label="$2" threshold="$3"
    [ -n "$main" ] || return 0
    local killed=0
    for pid in $(ps -eo pid,ppid,etimes,args | awk -v m="$main" -v t="$threshold" '$2==m && /\[accepted\]/ && $3>t {print $1}'); do
        kill -9 "$pid" 2>/dev/null && killed=$((killed+1)) || true
    done
    for pid in $(ps -eo pid,ppid,etimes,args | awk -v m="$main" '$2==m && /\[priv\]/ && $3>120 {print $1}'); do
        if [ "$(pgrep -P "$pid" 2>/dev/null | wc -l)" -eq 0 ]; then
            kill -9 "$pid" 2>/dev/null && killed=$((killed+1)) || true
        fi
    done
    local startups
    startups=$(ps -o args= -p "$main" 2>/dev/null | grep -oE '[0-9]+ of [0-9]+-[0-9]+ startups' | awk '{print $1}')
    [ -z "$startups" ] && startups=0
    if [ "$killed" -gt 0 ]; then
        log "$label: removidas $killed conexoes pre-auth; startups=$startups"
    fi
    if [ "$startups" -ge 250 ]; then
        log "ALERTA: $label startups=$startups (limite 300) — verificar backends dos proxies"
    fi
}

main22=$(ps -eo pid,args | awk '/\/usr\/sbin\/sshd -D/ && !/sshd_config_bhttp/ && !/awk/ {print $1; exit}')
main2223=$(ps -eo pid,args | awk '/\/usr\/sbin\/sshd -D -f \/etc\/ssh\/sshd_config_bhttp/ && !/awk/ {print $1; exit}')

cleanup "$main22"   'sshd 22'   70
cleanup "$main2223" 'sshd 2223' 70

exit 0
