#!/bin/bash
# ram_clean.sh — Limpeza automática de RAM (watchdog de 75% + gatilho manual)
# Ao limpar, também reinicia os serviços em andamento (ssh, squid, xray, proxies)
# para liberar a memória que eles seguraram.
#
# Usado pelo worker do bot (botão "🧹 Limpar RAM") e pelo cron /usr/local/bin/ramwatch.sh.

RAM_LIMIT_PCT=75
RAM_FORCE_PCT=90
RAM_CLEAN_STATE="/tmp/vpnbot_ramclean_last"
RAM_CLEAN_LOG="/var/log/ramwatch.log"

# reinicia um serviço via systemd (só se instalado e em andamento). Ex.: ssh, squid, xray, x-ui
_restart_unit(){
    local unit="$1"
    if ! systemctl list-units --type=service --no-legend --all 2>/dev/null | awk '{print $1}' | grep -q "^${unit}.service$"; then
        echo "— ${unit} (não instalado)"
        return
    fi
    if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "— ${unit} (não rodando)"
        return
    fi
    if timeout 60 systemctl restart "$unit" >/dev/null 2>&1; then
        echo "✅ ${unit}"
    else
        echo "❌ ${unit}"
    fi
}

# reinicia um proxy fora do systemd (xhttpssh/bhttpssh) mantendo os mesmos args
_restart_proxy(){
    local bin="$1" base found=0 res="" orig newpid
    base=$(basename "$bin")
    for p in $(pgrep -f "^${bin}( |$)" 2>/dev/null); do
        found=1
        orig=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
        kill -9 "$p" 2>/dev/null
        sleep 2
        if [[ -n "$orig" ]]; then
            nohup $orig >/dev/null 2>&1 &
            newpid=$!
            if [[ -n "$newpid" ]]; then
                res="${res} · PID ${newpid}"
            else
                res="${res} · falha ao relançar"
            fi
            sleep 0
        fi
    done
    if [[ "$found" -eq 0 ]]; then
        echo "— ${base} (não rodando)"
    else
        echo "✅ ${base}${res}"
    fi
}

# % de uso real da RAM (used/total, igual ao `free`)
_mem_used_pct(){
    free | awk '/^Mem/{printf "%d", ($3*100)/$2}'
}

# limpa os caches da RAM e reinicia os serviços em andamento
do_ramclean(){
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    echo "🧹 *Limpeza de RAM concluída!*"
    free -h | awk '/^Mem/{gsub(/^ +/,""); print "💾 Uso atual: "$0}'
    echo
    echo "🔄 *Serviços reiniciados:*"
    for s in ssh sshd squid xray x-ui; do
        echo "• $(_restart_unit "$s")"
    done
    echo
    echo "🔥 *Proxies:*"
    for b in /etc/VPNManager/bin/xhttpssh /etc/VPNManager/bin/bhttpssh; do
        [[ -x "$b" ]] && echo "• $(_restart_proxy "$b")"
    done
}

# watchdog: se a RAM passar de 75% limpa caches e reinicia serviços (no máx. 1x a cada 10 min).
# se passar de 90%, a limpeza é imediata.
ram_watchdog(){
    local pct now last elapsed res
    pct=$(_mem_used_pct)
    now=$(date +%s)
    last=$(cat "$RAM_CLEAN_STATE" 2>/dev/null)
    if [[ -n "$last" ]]; then
        elapsed=$(( now - last ))
    else
        elapsed=999999
    fi
    if (( pct >= RAM_FORCE_PCT )); then
        echo "$now" > "$RAM_CLEAN_STATE"
        res=$(do_ramclean)
        echo "$(date '+%F %T') RAM=${pct}% >= ${RAM_FORCE_PCT}% (forçado): $(echo "$res" | tr '\n' ' ' | cut -c1-200)" >> "$RAM_CLEAN_LOG"
    elif (( pct >= RAM_LIMIT_PCT && elapsed >= 600 )); then
        echo "$now" > "$RAM_CLEAN_STATE"
        res=$(do_ramclean)
        echo "$(date '+%F %T') RAM=${pct}% >= ${RAM_LIMIT_PCT}%: $(echo "$res" | tr '\n' ' ' | cut -c1-200)" >> "$RAM_CLEAN_LOG"
    fi
}