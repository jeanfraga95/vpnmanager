#!/bin/bash
#============================================================
# common.sh - funções compartilhadas (cores, validação)
#============================================================

INSTALL_DIR="${INSTALL_DIR:-/etc/VPNManager}"
CONF="$INSTALL_DIR/conf/vpnmanager.conf"
CRED_FILE="$INSTALL_DIR/conf/xray_credentials.txt"

C_GREEN="\033[1;32m"; C_RED="\033[1;31m"; C_YELLOW="\033[1;33m"
C_CYAN="\033[1;36m"; C_WHITE="\033[1;37m"; C_NC="\033[0m"

msg(){ echo -e "${C_CYAN}[*]${C_NC} $1"; }
ok(){ echo -e "${C_GREEN}[OK]${C_NC} $1"; }
fail(){ echo -e "${C_RED}[ERRO]${C_NC} $1"; }
pause(){ echo; read -n 1 -s -r -p "Pressione qualquer tecla para voltar..."; echo; }

require_root(){
    [[ "$EUID" -ne 0 ]] && { fail "Execute como root."; exit 1; }
}

get_ip(){
    local cache="/tmp/.vpnmanager_ip_cache"
    local ttl=1800   # 30 minutos
    if [[ -f "$cache" ]]; then
        local age now mtime
        now=$(date +%s)
        mtime=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
        age=$(( now - mtime ))
        if [[ "$age" -lt "$ttl" ]] && [[ -s "$cache" ]]; then
            cat "$cache"
            return
        fi
    fi
    local ip
    ip=$(curl -s -4 --max-time 2 ifconfig.me 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip="N/D"
    echo "$ip" > "$cache" 2>/dev/null
    echo "$ip"
}

valid_username(){
    [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]{2,31}$ ]]
}

date_add_days(){
    date -d "+$1 days" "+%Y-%m-%d"
}

conf_get(){
    [[ -f "$CONF" ]] && grep "^$1=" "$CONF" | cut -d'=' -f2-
}

conf_set(){
    local key="$1" val="$2"
    touch "$CONF"
    if grep -q "^$key=" "$CONF" 2>/dev/null; then
        sed -i "s|^$key=.*|$key=$val|" "$CONF"
    else
        echo "$key=$val" >> "$CONF"
    fi
}
