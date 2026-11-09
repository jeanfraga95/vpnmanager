#!/bin/bash
#============================================================
#  VPNManager Lite - Menu Principal (Responsivo)
#============================================================
INSTALL_DIR="/etc/VPNManager"

source "$INSTALL_DIR/modules/common.sh"
source "$INSTALL_DIR/modules/linguagem.sh"
source "$INSTALL_DIR/modules/ssh_users.sh"
source "$INSTALL_DIR/modules/xray.sh"
source "$INSTALL_DIR/modules/v2ray.sh"
source "$INSTALL_DIR/modules/online_users.sh"
source "$INSTALL_DIR/modules/slowdns.sh"
source "$INSTALL_DIR/modules/badvpn.sh"
source "$INSTALL_DIR/modules/telegram_bot.sh"
source "$INSTALL_DIR/modules/system_info.sh"
source "$INSTALL_DIR/modules/proxy.sh"
source "$INSTALL_DIR/modules/limiter.sh"
source "$INSTALL_DIR/modules/banner.sh"
source "$INSTALL_DIR/modules/bhttp.sh"
source "$INSTALL_DIR/modules/outras_opcoes.sh"

_lang_load

for fn in ssh_users_menu xray_menu xray_is_installed \
          v2ray_menu v2ray_is_installed \
          online_users_menu slowdns_menu badvpn_menu telegram_bot_menu \
          system_info_menu proxy_menu limiter_menu banner_menu \
          bhttp_menu outras_opcoes_menu linguagem_menu swap_menu; do
    if ! declare -F "$fn" >/dev/null 2>&1; then
        echo -e "\033[1;31m[ERRO]\033[0m Funcao '$fn' nao encontrada."
        echo "Reinstale o painel: ./install.sh"
        exit 1
    fi
done

require_root

# ── Cores ─────────────────────────────────────────────────────
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_ORANGE="\033[38;5;208m"
C_GRAY="\033[38;5;245m"
C_BLUE="\033[1;34m"
C_LIGHTGREEN="\033[38;5;120m"
C_LIGHTRED="\033[38;5;209m"
C_LIGHTCYAN="\033[1;36m"
C_WHITE="\033[1;37m"
C_NC="\033[0m"

# ── Dimensoes responsivas ────────────────────────────────────
_get_tw(){ tput cols 2>/dev/null || echo 80; }

_recalc_dims(){
    local tw; tw=$(_get_tw)
    if (( tw < 50 )); then
        BOX_W=$((tw))
    elif (( tw < 70 )); then
        BOX_W=$((tw - 2))
    else
        BOX_W=74
    fi
    (( BOX_W < 36 )) && BOX_W=36
    BOX_INNER=$((BOX_W - 2))
}

_center_pad(){
    local tw; tw=$(_get_tw)
    local pad=$(( (tw - BOX_W) / 2 ))
    (( pad < 0 )) && pad=0
    printf '%*s' "$pad" ""
}

_vlen(){
    printf '%s' "$1" | tr -d $'\033' | sed 's/\[[0-9;]*m//g' | wc -m | tr -d ' '
}

# ── Desenho ───────────────────────────────────────────────────

_sep_line(){
    local tw; tw=$(_get_tw)
    local w=$((BOX_INNER + 2))
    (( w > tw )) && w=$((tw - 2))
    (( w < 10 )) && w=10
    _center_pad
    printf "${C_ORANGE}"
    printf '%0.s─' $(seq 1 "$w")
    printf "${C_NC}\n"
}

_box_line(){
    local content="$1" align="${2:-left}"
    local vlen=$(_vlen "$content")
    _center_pad
    if [[ "$align" == "center" ]]; then
        local total=$((BOX_INNER))
        local lp=$(( (total - vlen) / 2 ))
        local rp=$(( total - vlen - lp ))
        (( lp < 0 )) && lp=0
        (( rp < 0 )) && rp=0
        printf "%*s%b%*s" "$lp" "" "$content" "$rp" ""
    else
        printf " %b" "$content"
    fi
    echo
}

_box_sep(){ _sep_line; }
_box_top(){ _sep_line; }
_box_bottom(){ _sep_line; }

_status_icon(){
    case "$1" in
        active)  echo -e "${C_LIGHTGREEN}●${C_NC}" ;;
        stopped) echo -e "${C_LIGHTRED}●${C_NC}" ;;
        off)     echo -e "${C_DIM}○${C_NC}" ;;
    esac
}

_progress_bar(){
    local pct=$1 w=$2
    w=${w:-10}
    (( w < 6 )) && w=6
    local filled=$(( pct * w / 100 ))
    local empty=$(( w - filled ))
    printf "${C_ORANGE}["
    printf '%0.s█' $(seq 1 "$filled" 2>/dev/null) || true
    printf "${C_GRAY}"
    printf '%0.s░' $(seq 1 "$empty" 2>/dev/null) || true
    printf "${C_ORANGE}]${C_NC} %3d%%" "$pct"
}

_get_cpu_usage(){
    local cpu1=($(grep '^cpu ' /proc/stat))
    sleep 0.3
    local cpu2=($(grep '^cpu ' /proc/stat))
    local i total1=0 total2=0
    for ((i=1; i<${#cpu1[@]}; i++)); do
        total1=$((total1 + cpu1[i])); total2=$((total2 + cpu2[i]))
    done
    local idle1=${cpu1[4]} idle2=${cpu2[4]}
    local total=$((total2 - total1)) idle=$((idle2 - idle1))
    (( total > 0 )) && echo $(( (total - idle) * 100 / total )) || echo "0"
}

_get_mem_usage(){
    awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%d", (t-a)*100/t}' /proc/meminfo
}

# ── Status cache ──────────────────────────────────────────────
_SVC_CACHE=""
_SVC_CACHE_TIME=0

_cache_services(){
    local now=$(date +%s)
    (( now - _SVC_CACHE_TIME < 10 )) && return 0
    _SVC_CACHE_TIME=$now
    local xray_s="off" v2ray_s="off" bot_s="off" cu_s="off" sq_s="off"
    xray_is_installed 2>/dev/null && { systemctl is-active --quiet xray 2>/dev/null && xray_s="active" || xray_s="stopped"; }
    v2ray_is_installed 2>/dev/null && { systemctl is-active --quiet v2ray 2>/dev/null && v2ray_s="active" || v2ray_s="stopped"; }
    bot_is_configured 2>/dev/null && { bot_is_active 2>/dev/null && bot_s="active" || bot_s="stopped"; }
    outras_opcoes_checkuser_active 2>/dev/null && cu_s="active"
    squid_is_installed 2>/dev/null && sq_s="active"
    _SVC_CACHE="${xray_s}|${v2ray_s}|${bot_s}|${cu_s}|${sq_s}"
}

_get_svc(){ _cache_services; echo "$_SVC_CACHE" | cut -d'|' -f"$1"; }

_draw_cpu_ram_line(){
    local cpu=$1 mem=$2
    local tw; tw=$(_get_tw)
    if (( tw >= 60 )); then
        local pw=10
        (( tw < 80 )) && pw=6
        _box_line "  ${C_BLUE}CPU:${C_NC} $(_progress_bar $cpu $pw)   ${C_BLUE}RAM:${C_NC} $(_progress_bar $mem $pw)"
    else
        _box_line "  ${C_BLUE}CPU:${C_NC} $(_progress_bar $cpu 6)"
        _box_line "  ${C_BLUE}RAM:${C_NC} $(_progress_bar $mem 6)"
    fi
}

_update_cpu_ram_only(){
    local cpu=$(_get_cpu_usage)
    local mem=$(_get_mem_usage)
    local ip=$(get_ip)
    local users=$(awk -F: '$3>=1000 && $7=="/bin/false"' /etc/passwd | wc -l)
    local online=0
    local vpn_users; mapfile -t vpn_users < <(awk -F: '$3>=1000 && $7=="/bin/false"{print $1}' /etc/passwd)
    if [[ ${#vpn_users[@]} -gt 0 ]]; then
        local au; au=$'\n'"$(ps -eo user= | sort -u)"$'\n'
        for u in "${vpn_users[@]}"; do [[ "$au" == *$'\n'"$u"$'\n'* ]] && (( online++ )); done
    fi
    local s1=$(_get_svc 1) s2=$(_get_svc 2) s3=$(_get_svc 3) s4=$(_get_svc 4) s5=$(_get_svc 5)
    local tw; tw=$(_get_tw)
    local box_w=74; (( tw < 50 )) && box_w=$((tw)); (( tw >= 50 && tw < 70 )) && box_w=$((tw - 2))
    local box_inner=$((box_w - 2)); local sep_w=$((box_inner + 2)); (( sep_w < 10 )) && sep_w=10
    local pad=$(( (tw - box_w) / 2 )); (( pad < 0 )) && pad=0
    local pw=10; (( tw < 80 )) && pw=6; (( tw < 60 )) && pw=6

    printf "\033[2J\033[H"

    echo
    printf '%*s' "$pad" ""
    printf "${C_ORANGE}"; printf '%0.s─' $(seq 1 "$sep_w"); printf "${C_NC}\n"
    printf '%*s' "$pad" ""
    printf "  ${C_LIGHTCYAN}${C_BOLD}VPNManager${C_NC} ${C_DIM}v2.0${C_NC}\n"
    printf '%*s' "$pad" ""
    printf "${C_ORANGE}"; printf '%0.s─' $(seq 1 "$sep_w"); printf "${C_NC}\n"

    printf '%*s' "$pad" ""
    printf "  ${C_BLUE}CPU:${C_NC} %b   ${C_BLUE}RAM:${C_NC} %b\n" "$(_progress_bar $cpu $pw)" "$(_progress_bar $mem $pw)"

    printf '%*s' "$pad" ""
    if (( tw >= 65 )); then
        printf "  ${C_BLUE}IP:${C_NC} ${C_WHITE}${ip}${C_NC}  ${C_BLUE}Users:${C_NC} ${C_WHITE}${users}${C_NC}  ${C_BLUE}Online:${C_NC} ${C_WHITE}${online}${C_NC}\n"
    elif (( tw >= 48 )); then
        printf "  ${C_BLUE}IP:${C_NC} ${C_WHITE}${ip}${C_NC}\n"
        printf '%*s' "$pad" ""
        printf "  ${C_BLUE}Users:${C_NC} ${C_WHITE}${users}${C_NC}  ${C_BLUE}Online:${C_NC} ${C_WHITE}${online}${C_NC}\n"
    else
        printf "  ${C_BLUE}${ip}${C_NC}  U:${C_WHITE}${users}${C_NC}  O:${C_WHITE}${online}${C_NC}\n"
    fi

    printf '%*s' "$pad" ""
    printf "  $(_status_icon $s1) ${C_BLUE}Xray${C_NC}  $(_status_icon $s2) ${C_BLUE}V2Ray${C_NC}  $(_status_icon $s3) ${C_BLUE}Bot${C_NC}  $(_status_icon $s4) ${C_BLUE}CU${C_NC}  $(_status_icon $s5) ${C_BLUE}Squid${C_NC}\n"

    printf '%*s' "$pad" ""
    printf "${C_ORANGE}"; printf '%0.s─' $(seq 1 "$sep_w"); printf "${C_NC}\n"

    _draw_menu_items
}

# ── Draw header completo ──────────────────────────────────────

draw_header_full(){
    _recalc_dims

    local ip=$(get_ip)
    local users=$(awk -F: '$3>=1000 && $7=="/bin/false"' /etc/passwd | wc -l)
    local cpu=$(_get_cpu_usage)
    local mem=$(_get_mem_usage)

    local online=0
    local vpn_users; mapfile -t vpn_users < <(awk -F: '$3>=1000 && $7=="/bin/false"{print $1}' /etc/passwd)
    if [[ ${#vpn_users[@]} -gt 0 ]]; then
        local au; au=$'\n'"$(ps -eo user= | sort -u)"$'\n'
        for u in "${vpn_users[@]}"; do [[ "$au" == *$'\n'"$u"$'\n'* ]] && (( online++ )); done
    fi

    local s1=$(_get_svc 1) s2=$(_get_svc 2) s3=$(_get_svc 3) s4=$(_get_svc 4) s5=$(_get_svc 5)

    local tw; tw=$(_get_tw)

    clear
    echo
    _box_top
    _box_line "${C_LIGHTCYAN}${C_BOLD}VPNManager${C_NC} ${C_DIM}v2.0${C_NC}" "center"
    _box_sep

    _draw_cpu_ram_line "$cpu" "$mem"

    # IP / Users / Online — responsivo
    if (( tw >= 65 )); then
        _box_line "  ${C_BLUE}IP:${C_NC} ${C_WHITE}${ip}${C_NC}  ${C_BLUE}Users:${C_NC} ${C_WHITE}${users}${C_NC}  ${C_BLUE}Online:${C_NC} ${C_WHITE}${online}${C_NC}"
    elif (( tw >= 48 )); then
        _box_line "  ${C_BLUE}IP:${C_NC} ${C_WHITE}${ip}${C_NC}"
        _box_line "  ${C_BLUE}Users:${C_NC} ${C_WHITE}${users}${C_NC}  ${C_BLUE}Online:${C_NC} ${C_WHITE}${online}${C_NC}"
    else
        _box_line "  ${C_BLUE}${ip}${C_NC}  U:${C_WHITE}${users}${C_NC}  O:${C_WHITE}${online}${C_NC}"
    fi

    # Status services — responsivo
    if (( tw >= 65 )); then
        _box_line "  $(_status_icon $s1) ${C_BLUE}Xray${C_NC}  $(_status_icon $s2) ${C_BLUE}V2Ray${C_NC}  $(_status_icon $s3) ${C_BLUE}Bot${C_NC}  $(_status_icon $s4) ${C_BLUE}CU${C_NC}  $(_status_icon $s5) ${C_BLUE}Squid${C_NC}"
    elif (( tw >= 48 )); then
        _box_line "  $(_status_icon $s1)Xray $(_status_icon $s2)V2Ray $(_status_icon $s3)Bot"
        _box_line "  $(_status_icon $s4)CU $(_status_icon $s5)Squid"
    else
        _box_line "  ${C_BLUE}X:${C_NC}$(_status_icon $s1) ${C_BLUE}V:${C_NC}$(_status_icon $s2) ${C_BLUE}B:${C_NC}$(_status_icon $s3)"
        _box_line "  ${C_BLUE}C:${C_NC}$(_status_icon $s4) ${C_BLUE}S:${C_NC}$(_status_icon $s5)"
    fi

    _box_sep
}

# ── Menu item ─────────────────────────────────────────────────

_menu_item(){
    local num=$(printf "%2s" "$1") label="$2" status="${3:-}"
    local st=""
    case "$status" in
        active)  st=" ${C_LIGHTGREEN}●${C_NC}" ;;
        stopped) st=" ${C_LIGHTRED}●${C_NC}" ;;
        off)     st=" ${C_DIM}○${C_NC}" ;;
    esac
    _center_pad
    echo -e "  ${C_ORANGE}${C_BOLD}${num})${C_NC} ${C_WHITE}${label}${C_NC}${st}"
}

# ── Xray install prompt ───────────────────────────────────────

_xray_install_prompt(){
    clear
    _sep_line
    echo -e "  ${C_BLUE}Xray — ${L_NOT_INST}${C_NC}"
    _sep_line
    echo
    echo " ${L_XRAY}"
    echo
    read -p " Instalar Xray agora? [s/N]: " resp
    [[ "$resp" =~ ^[sS]$ ]] && xray_menu
}

# ── Auto Menu ─────────────────────────────────────────────────

BIN_LINK="/usr/local/bin/menuvpn"
AUTO_MENU_MARK_START="# >>> VPNManager auto-menu >>>"
AUTO_MENU_MARK_END="# <<< VPNManager auto-menu <<<"
AUTO_MENU_BASHRC="/root/.bashrc"

auto_menu_is_enabled(){
    [[ -f "$AUTO_MENU_BASHRC" ]] && grep -qF "$AUTO_MENU_MARK_START" "$AUTO_MENU_BASHRC" 2>/dev/null
}

auto_menu_enable(){
    auto_menu_is_enabled && return 0
    { echo ""; echo "$AUTO_MENU_MARK_START"
      echo "if [[ \$- == *i* ]] && [[ -z \"\$VPNMANAGER_NO_AUTOMENU\" ]]; then"
      echo "    $BIN_LINK"; echo "fi"
      echo "$AUTO_MENU_MARK_END"; } >> "$AUTO_MENU_BASHRC"
}

auto_menu_disable(){
    auto_menu_is_enabled || return 0
    sed -i "/$(printf '%s' "$AUTO_MENU_MARK_START" | sed 's/[.[\*^$/]/\\&/g')/,/$(printf '%s' "$AUTO_MENU_MARK_END" | sed 's/[.[\*^$/]/\\&/g')/d" "$AUTO_MENU_BASHRC"
}

auto_menu_toggle_screen(){
    clear
    _box_top
    _box_line "${C_BLUE}${C_BOLD}${L_AUTO_MENU}" "center"
    _box_sep
    echo
    if auto_menu_is_enabled; then
        _center_pad; echo -e "  ${C_LIGHTGREEN}● ATIVO${C_NC}  ${C_DIM}O menu abre automaticamente${C_NC}"
    else
        _center_pad; echo -e "  ${C_LIGHTRED}● PARADO${C_NC}  ${C_DIM}Execute 'menuvpn' manualmente${C_NC}"
    fi
    echo
    _center_pad; read -p "  Ativar/Desativar? [s/N]: " resp
    if [[ "$resp" =~ ^[sS]$ ]]; then
        auto_menu_is_enabled && { auto_menu_disable; ok "Desativado."; } || { auto_menu_enable; ok "Ativado."; }
    fi
    _box_bottom
    pause
}

# ── Uninstall ─────────────────────────────────────────────────

full_uninstall(){
    clear
    _sep_line
    echo -e "  ⚠  ${L_UNINST_TITLE}"
    _sep_line
    echo
    echo " ${L_UNINST_MSG}"
    echo -e "  ${C_DIM}• ${L_UNINST_USERS}${C_NC}"
    echo -e "  ${C_DIM}• ${L_UNINST_TOOLS}${C_NC}"
    echo -e "  ${C_DIM}• ${L_UNINST_BOT}${C_NC}"
    echo -e "  ${C_DIM}• ${L_UNINST_PORTS}${C_NC}"
    echo -e "  ${C_DIM}• ${L_UNINST_MENU}${C_NC}"
    echo -e "  ${C_DIM}• ${L_UNINST_AUTO}${C_NC}"
    echo
    echo -e " ${C_LIGHTRED}${L_UNINST_WARN}${C_NC}"
    echo
    read -p "${L_UNINST_CONFIRM}" conf
    if [[ "$conf" != "DESINSTALAR" && "$conf" != "UNINSTALL" ]]; then
        fail "Confirmacao incorreta."; pause; return
    fi
    echo
    msg "Removendo usuarios SSH..."
    while IFS=: read -r uname _ uid _ _ _ shell; do
        [[ "$uid" -ge 1000 && "$shell" == "/bin/false" ]] || continue
        ssh_remove_api "$uname" > /dev/null 2>&1
    done < <(sort -t: -k1,1 /etc/passwd)
    msg "Removendo Bot Telegram..."
    systemctl disable --now vpnbot 2>/dev/null
    rm -f "$BOT_SERVICE" "$BOT_SCRIPT" "$BOT_CONF" "$BOT_OFFSET_FILE" "$AUTO_BACKUP_CONF" 2>/dev/null
    msg "Removendo Limitador..."
    systemctl disable --now vpnlimiter 2>/dev/null
    rm -f "$LIMITER_SERVICE" "$LIMITER_SCRIPT" "$LIMITER_CONF" 2>/dev/null
    msg "Removendo SlowDNS..."
    systemctl disable --now slowdns 2>/dev/null; rm -f "$SDNS_SERVICE" /usr/local/bin/dnstt-server 2>/dev/null; rm -rf "$SDNS_DIR" 2>/dev/null
    msg "Removendo BadVPN..."
    _stop_all_badvpn 2>/dev/null; apt-get remove -y badvpn > /dev/null 2>&1 || true
    msg "Fechando portas WS/TLS-SSL/XHTTP..."
    for svc in /etc/systemd/system/vpnproxy-*.service; do
        [[ -f "$svc" ]] || continue; systemctl disable --now "$(basename "$svc" .service)" 2>/dev/null; rm -f "$svc"
    done
    msg "Removendo Xray e V2Ray..."
    xray_full_uninstall 2>/dev/null; v2ray_full_uninstall 2>/dev/null
    msg "Removendo Banner SSH..."
    rm -f /etc/bannerssh 2>/dev/null; _banner_set_sshd_directive "none" 2>/dev/null; systemctl restart ssh 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    msg "Removendo menu..."
    auto_menu_disable; rm -f "$BIN_LINK"; rm -rf /etc/SSHPlus /etc/PanelMaster /etc/usuarios 2>/dev/null; rm -f /root/pm_users.db 2>/dev/null
    clear; echo -e "${C_LIGHTGREEN}${L_UNINST_OK}${C_NC}"; rm -rf "$INSTALL_DIR"; exit 0
}

# ── Menu items ────────────────────────────────────────────────

_draw_menu_items(){
    _cache_services
    _menu_item 1 "${L_SSH_USERS}"
    _menu_item 2 "${L_ONLINE_USERS}"
    _menu_item 3 "Xray" "$(_get_svc 1)"
    _menu_item 4 "V2Ray" "$(_get_svc 2)"
    _menu_item 5 "SlowDNS" "$([[ "$(slowdns_is_installed 2>/dev/null)" == "1" ]] && echo "active" || echo "off")"
    _menu_item 6 "BadVPN" "$([[ "$(badvpn_is_installed 2>/dev/null)" == "1" ]] && echo "active" || echo "off")"
    _menu_item 7 "Bot Telegram" "$(_get_svc 3)"
    _menu_item 8 "${L_SYSINFO}"
    _menu_item 9 "${L_OPEN_PORT}"
    _menu_item 10 "${L_BHTTP}" "$([[ "$(bhttp_is_installed 2>/dev/null)" ]] && echo "active" || echo "off")"
    _menu_item 11 "${L_LIMITER}" "$([[ "$(limiter_is_installed 2>/dev/null)" && "$(limiter_is_active 2>/dev/null)" ]] && echo "active" || { [[ "$(limiter_is_installed 2>/dev/null)" ]] && echo "stopped" || echo "off"; })"
    _menu_item 12 "${L_BANNER}" "$([[ "$(banner_is_configured 2>/dev/null)" && "$(_banner_is_active_in_sshd 2>/dev/null)" ]] && echo "active" || echo "off")"
    _menu_item 13 "${L_OTHER_OPT}"
    _menu_item 14 "${L_AUTO_MENU}" "$([[ "$(auto_menu_is_enabled)" ]] && echo "active" || echo "off")"
    _menu_item 15 "${L_LANGUAGE}"
    echo
    _menu_item 16 "${L_UNINSTALL}" "danger"
    echo
    _box_sep
    _box_line "  ${C_DIM}0) ${L_EXIT}${C_NC}" "center"
    _box_bottom
}

# ── Menu Principal ────────────────────────────────────────────

main_menu(){
    while true; do
        _lang_load
        _cache_services

        draw_header_full
        _draw_menu_items

        while true; do
            printf "\r\033[K"
            _center_pad
            echo -ne "  ${C_ORANGE}❯${C_NC} ${C_WHITE}"

            read -t 2 opt 2>/dev/null
            local rc=$?

            if (( rc != 0 )); then
                _update_cpu_ram_only
                continue
            fi

            echo -e "${C_NC}"
            _SVC_CACHE_TIME=0

            case "$opt" in
                1) ssh_users_menu; break ;;
                2) online_users_menu; break ;;
                3) xray_is_installed && xray_menu || _xray_install_prompt; break ;;
                4) v2ray_menu; break ;;
                5) slowdns_menu; break ;;
                6) badvpn_menu; break ;;
                7) telegram_bot_menu; break ;;
                8) system_info_menu; break ;;
                9) proxy_menu; break ;;
                10) bhttp_menu; break ;;
                11) limiter_menu; break ;;
                12) banner_menu; break ;;
                13) outras_opcoes_menu; break ;;
                14) auto_menu_toggle_screen; break ;;
                15) linguagem_menu; break ;;
                16) full_uninstall; break ;;
                0) clear; exit 0 ;;
                "") ;;
                *) fail "${L_INVALID}"; sleep 1; break ;;
            esac
        done
    done
}

main_menu
