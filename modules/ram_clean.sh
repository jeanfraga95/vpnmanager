#!/bin/bash
# ram_clean.sh — Limpeza de RAM 100% nao destrutiva.
# NUNCA reinicia ssh/sshd/proxies: isso derruba usuarios conectados nas portas 80/8080.
# Uso: watchdog do cron (/usr/local/bin/ramwatch.sh) e botao manual do bot.

RAM_LIMIT_PCT=75
RAM_FORCE_PCT=90
RAM_CLEAN_STATE="/tmp/vpnbot_ramclean_last"
RAM_CLEAN_LOG="/var/log/ramwatch.log"

# % de uso real da RAM (used/total, igual ao `free`)
_mem_used_pct(){
    free | awk '/^Mem/{printf "%d", ($3*100)/$2}'
}

# Limpa apenas page cache/dentries/inodes. Nao toca em processos nem conexoes.
do_ramclean(){
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    echo "🧹 *Limpeza de RAM concluída!*"
    free -h | awk '/^Mem/{gsub(/^ +/,""); print "💾 Uso atual: "$0}'
    echo
    echo "🔒 *Serviços e sessões preservados* (nenhum restart; usuarios conectados continuam)."
}

# Watchdog: apenas libera cache e registra alerta. Nao ha mais acao destrutiva.
ram_watchdog(){
    local pct now last elapsed
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
        echo "$(date '+%F %T') RAM=${pct}% >= ${RAM_FORCE_PCT}% (alerta): cache liberado, nenhum servico reiniciado" >> "$RAM_CLEAN_LOG"
        do_ramclean >/dev/null 2>&1 || true
    elif (( pct >= RAM_LIMIT_PCT && elapsed >= 600 )); then
        echo "$now" > "$RAM_CLEAN_STATE"
        echo "$(date '+%F %T') RAM=${pct}% >= ${RAM_LIMIT_PCT}%: cache liberado, nenhum servico reiniciado" >> "$RAM_CLEAN_LOG"
        do_ramclean >/dev/null 2>&1 || true
    fi
}
