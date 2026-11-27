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
source "$INSTALL_DIR/modules/swap.sh"

# ── Cores do menu (fallback) ──────────────────────────────────
# O tema fica em modules/theme.sh e e carregado por common.sh. Se o
# instalador antigo nao copiou esse arquivo, o menu abria sem nenhuma
# cor. Define aqui os mesmos codigos para o menu continuar colorido.
if [[ -z "${C_NC:-}" ]]; then
    C_RESET='\033[0m'
    C_NC="$C_RESET"
    C_BG=''
    C_BG_SOFT='\033[48;5;24m'
    C_TEXT=''
    C_ORANGE='\033[38;5;208m'
    C_AMBER='\033[38;5;214m'
    C_BORDER='\033[1;34m'
    C_BLUE="$C_BORDER"
    C_CYAN='\033[1;36m'
    C_WHITE='\033[1;38;5;255m'
    C_GRAY='\033[38;5;245m'
    C_DIM='\033[38;5;244m'
    C_BAR='\033[44m'
    C_GREEN='\033[38;5;120m'
    C_YELLOW='\033[38;5;214m'
    C_RED='\033[38;5;209m'
    C_BOLD='\033[1m'
    C_LIGHTGREEN="$C_GREEN"
    C_LIGHTRED="$C_RED"
    C_LIGHTCYAN="$C_CYAN"
fi

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
# Paleta unificada em modules/theme.sh: azul escuro + laranja.

# ── Dimensoes responsivas ────────────────────────────────────
_get_tw(){ tput cols 2>/dev/null || echo 80; }

# Controle de linhas para atualizar somente a faixa de CPU/RAM.
UI_ROW=1
CPU_ROW=5
CPU_LINES=1
MENU_TW=""
PROMPT_ROW=1
PROMPT_COL=8
STATUS_TOP_ROW=8
S_IP=""
S_USERS=0
S_ONLINE=0            # usuários SSH online
S_XRAY_ONLINE=0       # usuários Xray/VLESS online
S_S1="off"; S_S2="off"; S_S3="off"; S_S4="off"; S_S5="off"
BOX_INNER=56
BOX_W=58

_recalc_dims(){
    local tw; tw=$(_get_tw)
    BOX_INNER=$((tw - 3))
    (( BOX_INNER > 56 )) && BOX_INNER=56
    if (( BOX_INNER < 34 )); then
        if (( tw - 2 >= 28 )); then BOX_INNER=$((tw - 2)); else BOX_INNER=28; fi
    fi
    BOX_W=$((BOX_INNER + 2))
}

_center_pad(){
    local tw; tw=$(_get_tw)
    local pad=$(( (tw - BOX_W) / 2 ))
    (( pad < 0 )) && pad=0
    printf '%*s' "$pad" ""
}

_strip_ansi(){
    printf '%s' "$1" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g; s/\\033\[[0-9;]*[a-zA-Z]//g'
}

_vlen(){
    _strip_ansi "$1" | wc -m | tr -d ' '
}

_trunc_content(){
    local s="$1" max="$2" plain
    plain=$(_strip_ansi "$s")
    if (( ${#plain} > max )); then
        printf '%s...' "${plain:0:max-3}"
    else
        printf '%s' "$s"
    fi
}

# ── Desenho: caixas ASCII estilo SSHPlus ─────────────────────

_box_rule(){
    local fill
    fill=$(printf '%*s' "$BOX_INNER" "" | tr ' ' '-')
    _center_pad
    printf '%b+%s+%b\033[K\n' "${C_BORDER}" "$fill" "${C_NC}"
    ((UI_ROW++))
}

_sep_line(){ _box_rule; }
_box_top(){ _box_rule; }
_box_bottom(){ _box_rule; }
_box_sep(){ _box_rule; }

_box_line(){
    local content="$1" align="${2:-left}"
    local len lp rp pad
    content=$(_trunc_content "$content" "$BOX_INNER")
    len=$(_vlen "$content")
    pad=$((BOX_INNER - len))
    (( pad < 0 )) && pad=0
    _center_pad
    printf '%b' "${C_BORDER}|${C_NC}"
    if [[ "$align" == "center" ]]; then
        lp=$(( pad / 2 ))
        rp=$(( pad - lp ))
        printf '%*s' "$lp" ""
        printf '%b' "$content"
        printf '%*s' "$rp" ""
    else
        printf '%b' "$content"
        printf '%*s' "$pad" ""
    fi
    printf '%b\033[K\n' "${C_BORDER}|${C_NC}"
    ((UI_ROW++))
}

# Barra de titulo com fundo azul cheio, como no SSHPlus.
_box_bar(){
    local text="$1" plain len lp rp
    plain=$(_strip_ansi "$text")
    text="$plain"
    len=${#plain}
    lp=$(( (BOX_INNER - len) / 2 ))
    rp=$(( BOX_INNER - len - lp ))
    (( lp < 0 )) && lp=0
    (( rp < 0 )) && rp=0
    _center_pad
    # A cor do texto é aplicada aqui e só é resetada no fim da linha:
    # assim o fundo azul da barra fica contínuo e o texto centralizado.
    printf '%b' "${C_BORDER}|${C_NC}${C_BAR}"
    printf '%*s' "$lp" ""
    printf '%b' "${C_WHITE}${text}"
    printf '%*s' "$rp" ""
    printf '%b\033[K\n' "${C_NC}${C_BORDER}|${C_NC}"
    ((UI_ROW++))
}

_status_icon(){
    case "$1" in
        active)  printf '%b' "${C_LIGHTGREEN}ON${C_NC}" ;;
        stopped) printf '%b' "${C_YELLOW}PARADO${C_NC}" ;;
        off)     printf '%b' "${C_DIM}OFF${C_NC}" ;;
    esac
}

_progress_bar(){
    local pct=$1 w=$2 i
    w=${w:-10}
    (( w < 6 )) && w=6
    local filled=$(( pct * w / 100 ))
    local empty=$(( w - filled ))
    printf '%b' "${C_ORANGE}[${C_LIGHTGREEN}"
    for ((i=0; i<filled; i++)); do printf '#'; done
    printf '%b' "${C_GRAY}"
    for ((i=0; i<empty; i++)); do printf '-'; done
    printf '%b %3d%%' "${C_ORANGE}]${C_NC}" "$pct"
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
    local pw=10
    (( tw < 80 )) && pw=6

    CPU_ROW=$UI_ROW
    if (( tw >= 60 )); then
        CPU_LINES=1
        _box_line " ${C_WHITE}CPU:${C_NC} $(_progress_bar $cpu $pw)  ${C_WHITE}RAM:${C_NC} $(_progress_bar $mem $pw)"
    else
        CPU_LINES=2
        _box_line " ${C_WHITE}CPU:${C_NC} $(_progress_bar $cpu $pw)"
        _box_line " ${C_WHITE}RAM:${C_NC} $(_progress_bar $mem $pw)"
    fi
}

# Posição onde o prompt "Opcao:" é desenhado.
_menu_prompt_pos(){
    local tw; tw=$(_get_tw)
    local pad=$(( (tw - BOX_W) / 2 ))
    (( pad < 0 )) && pad=0
    PROMPT_ROW=$UI_ROW
    PROMPT_COL=$(( pad + 8 ))
}

# Caixa de status: desenhada no início e reescrita no mesmo lugar nas atualizações.
# Assim a linha de CPU/RAM nunca fica duplicada.
_draw_status_box(){
    local cpu=$1 mem=$2
    local tw; tw=$(_get_tw)
    local total_online=$((S_ONLINE + S_XRAY_ONLINE))

    _box_top
    if (( tw >= 65 )); then
        _box_line " ${C_WHITE}IP:${C_NC} ${C_LIGHTCYAN}${S_IP}${C_NC}  ${C_WHITE}Users:${C_NC} ${C_LIGHTCYAN}${S_USERS}${C_NC}  ${C_WHITE}Online:${C_NC} ${C_LIGHTCYAN}${total_online}${C_NC}"
    elif (( tw >= 48 )); then
        _box_line " ${C_WHITE}IP:${C_NC} ${C_LIGHTCYAN}${S_IP}${C_NC}"
        _box_line " ${C_WHITE}Users:${C_NC} ${C_LIGHTCYAN}${S_USERS}${C_NC}  ${C_WHITE}Online:${C_NC} ${C_LIGHTCYAN}${total_online}${C_NC}"
    else
        _box_line " ${C_LIGHTCYAN}${S_IP}${C_NC}  U:${C_LIGHTCYAN}${S_USERS}${C_NC}  O:${C_LIGHTCYAN}${total_online}${C_NC}"
    fi

    _draw_cpu_ram_line "$cpu" "$mem"

    if (( tw >= 65 )); then
        _box_line " ${C_WHITE}Xray:${C_NC} $(_status_icon "$S_S1")  ${C_WHITE}V2Ray:${C_NC} $(_status_icon "$S_S2")  ${C_WHITE}Bot:${C_NC} $(_status_icon "$S_S3")  ${C_WHITE}CU:${C_NC} $(_status_icon "$S_S4")  ${C_WHITE}Squid:${C_NC} $(_status_icon "$S_S5")"
    elif (( tw >= 48 )); then
        _box_line " ${C_WHITE}Xray:${C_NC} $(_status_icon "$S_S1")  ${C_WHITE}V2Ray:${C_NC} $(_status_icon "$S_S2")  ${C_WHITE}Bot:${C_NC} $(_status_icon "$S_S3")"
        _box_line " ${C_WHITE}CU:${C_NC} $(_status_icon "$S_S4")  ${C_WHITE}Squid:${C_NC} $(_status_icon "$S_S5")"
    else
        _box_line " ${C_WHITE}X:${C_NC} $(_status_icon "$S_S1")  ${C_WHITE}V:${C_NC} $(_status_icon "$S_S2")  ${C_WHITE}B:${C_NC} $(_status_icon "$S_S3")"
        _box_line " ${C_WHITE}C:${C_NC} $(_status_icon "$S_S4")  ${C_WHITE}S:${C_NC} $(_status_icon "$S_S5")"
    fi
    _box_top
}

# Atualiza somente a caixa de status, sem tocar no menu.
# Usa posicionamento absoluto e nunca roda enquanto há caracteres digitados.
_update_cpu_ram_only(){
    local tw; tw=$(_get_tw)
    if [[ -n "$MENU_TW" && "$tw" != "$MENU_TW" ]]; then
        draw_header_full
        _draw_menu_items
        _menu_prompt_pos
        return 0
    fi

    local saved_row=$UI_ROW
    printf "\033[%d;1H" "$STATUS_TOP_ROW"
    # Atualiza também a contagem Xray (uma chamada leve à API local).
    S_XRAY_ONLINE=$(_xray_online_count)
    _draw_status_box "$(_get_cpu_usage)" "$(_get_mem_usage)"
    UI_ROW=$saved_row
    printf "\033[%d;%dH" "$PROMPT_ROW" "$PROMPT_COL"
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
    UI_ROW=1
    MENU_TW=$tw

    echo
    ((UI_ROW++))
    _box_top
    _box_bar "VPNManager"
    _box_line "${C_WHITE}Proxy + Protocolo integrados${C_NC}" "center"
    _box_top
    echo
    ((UI_ROW++))

    STATUS_TOP_ROW=$UI_ROW
    S_IP="$ip"
    S_USERS=$users
    S_ONLINE=$online
    S_XRAY_ONLINE=$(_xray_online_count)
    S_S1="$s1"
    S_S2="$s2"
    S_S3="$s3"
    S_S4="$s4"
    S_S5="$s5"
    _draw_status_box "$cpu" "$mem"
    echo
    ((UI_ROW++))
}

# ── Menu item ─────────────────────────────────────────────────

_menu_item(){
    local num=$1 label="$2" status="${3:-}"
    local st="" line

    case "$status" in
        active)  st="  ${C_LIGHTGREEN}ON${C_NC}" ;;
        stopped) st="  ${C_YELLOW}PARADO${C_NC}" ;;
        off)     st="  ${C_DIM}OFF${C_NC}" ;;
    esac
    printf -v st '%b' "$st"

    if [[ "$status" == "danger" ]]; then
        line="${C_LIGHTRED}  [${num}] ${label}${C_NC}"
    else
        line="${C_WHITE}  [${C_ORANGE}${num}${C_WHITE}] ${C_LIGHTCYAN}${label}${C_NC}${st}"
    fi
    _box_line "$line"
}

_menu_section(){
    _box_line " ${C_ORANGE}${C_BOLD}$1${C_NC}" "center"
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
        _box_line " ${C_LIGHTGREEN}ATIVO${C_NC}  ${C_DIM}O menu abre automaticamente${C_NC}"
    else
        _box_line " ${C_LIGHTRED}PARADO${C_NC}  ${C_DIM}Execute 'menuvpn' manualmente${C_NC}"
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

# Remove uma unidade apenas se ela for claramente do VPNManager.
# Servicos de outros sistemas (ex.: proto-server/dtproto, badvpn de outro
# painel) nunca sao tocados.
_vpnmanager_unit_remove(){
    local u="$1" f="/etc/systemd/system/${u}.service"
    [[ -f "$f" ]] || return 0
    if grep -Eq '/etc/VPNManager|VPNManager' "$f" 2>/dev/null; then
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "$f"
    fi
}

full_uninstall(){
    clear
    _sep_line
    echo -e "  !  ${L_UNINST_TITLE}"
    _sep_line
    echo
    echo " ${L_UNINST_MSG}"
    echo -e "  ${C_DIM}• Menu, modulos, binarios e configuracoes${C_NC}"
    echo -e "  ${C_DIM}• Servicos vpnproxy / HCR / sshd-bhttp / healthcheck${C_NC}"
    echo -e "  ${C_DIM}• Usuarios: preservados por padrao (pergunta abaixo)${C_NC}"
    echo -e "  ${C_DIM}• Sistemas de terceiros (ex.: dtproto/proto-server): intactos${C_NC}"
    echo
    echo -e " ${C_LIGHTRED}${L_UNINST_WARN}${C_NC}"
    echo
    read -p "${L_UNINST_CONFIRM}" conf
    if [[ "$conf" != "DESINSTALAR" && "$conf" != "UNINSTALL" ]]; then
        fail "Confirmacao incorreta."; pause; return
    fi

    local remove_users=0
    echo
    read -p " Remover tambem os usuarios criados pelo painel? [s/N]: " conf2
    [[ "$conf2" =~ ^[sS]$ ]] && remove_users=1

    echo
    msg "Parando e removendo servicos do VPNManager..."
    local u f sn left=()
    for u in sshd-bhttp hcr-server vpnproxy-xhttp-11443 vpnproxy-fallback \
             vpnproxy-ws-8080 vpnproxy-bhttp-80 checkuser; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${u}.service"
    done
    for u in vpnmanager-healthcheck.timer vpnmanager-healthcheck.service; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${u}"
    done
    for f in /etc/systemd/system/vpnproxy-*.service; do
        [[ -f "$f" ]] || continue
        sn=$(basename "$f" .service)
        systemctl disable --now "$sn" >/dev/null 2>&1 || true
        rm -f "$f"
    done
    rm -rf /etc/systemd/system/vpnproxy-*.service.d

    # Modulos opcionais: só removemos se a unit apontar para o VPNManager.
    for u in vpnbot vpnlimiter slowdns xray v2ray; do
        _vpnmanager_unit_remove "$u"
    done
    rm -f "$BOT_SERVICE" "$BOT_SCRIPT" "$BOT_CONF" "$BOT_OFFSET_FILE" "$AUTO_BACKUP_CONF" 2>/dev/null
    rm -f "$LIMITER_SERVICE" "$LIMITER_SCRIPT" "$LIMITER_CONF" 2>/dev/null
    rm -f "$SDNS_SERVICE" /usr/local/bin/dnstt-server 2>/dev/null
    rm -rf "$SDNS_DIR" 2>/dev/null

    msg "Removendo arquivos do VPNManager..."
    auto_menu_disable 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    rm -f "$BIN_LINK"
    rm -f /etc/ssh/sshd_config_bhttp
    rm -f /usr/local/bin/hcr-server /usr/local/bin/hcr-dispatcher /usr/local/bin/checkuser
    rm -f /usr/local/bin/vpnmanager-stack
    rm -rf /opt/magnumproxy
    rm -f /etc/bannerssh 2>/dev/null
    _banner_set_sshd_directive "none" 2>/dev/null || true

    if (( remove_users )); then
        msg "Removendo usuarios criados pelo painel..."
        while IFS=: read -r uname _ uid _ _ _ shell; do
            [[ "$uid" -ge 1000 && "$shell" == "/bin/false" ]] || continue
            ssh_remove_api "$uname" > /dev/null 2>&1
        done < <(sort -t: -k1,1 /etc/passwd)
        rm -rf /etc/SSHPlus /etc/PanelMaster /etc/usuarios 2>/dev/null
        rm -f /root/pm_users.db 2>/dev/null
    else
        echo "  Usuarios preservados."
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true

    # Verificação: nada do VPNManager pode sobrar (exceto usuarios, se escolhido).
    [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]] && left+=("$INSTALL_DIR")
    [[ -e "$BIN_LINK" || -L "$BIN_LINK" ]] && left+=("$BIN_LINK")
    for f in /etc/systemd/system/vpnproxy-*.service \
             /etc/systemd/system/vpnproxy-*.service.d \
             /etc/systemd/system/sshd-bhttp.service \
             /etc/systemd/system/hcr-server.service \
             /etc/systemd/system/checkuser.service \
             /etc/systemd/system/vpnmanager-healthcheck.*; do
        [[ -e "$f" ]] && left+=("$f")
    done
    if (( ${#left[@]} )); then
        echo -e " ${C_LIGHTRED}[AVISO]${C_NC} Restaram artefatos do VPNManager:"
        printf '   %s\n' "${left[@]}" | head -20
    else
        echo -e " ${C_GREEN}[OK]${C_NC} Nenhum artefato do VPNManager restou."
    fi

    clear; echo -e "${C_LIGHTGREEN}${L_UNINST_OK}${C_NC}"; exit 0
}

# ── Menu items ────────────────────────────────────────────────

_draw_menu_items(){
    _cache_services

    _box_top
    _box_line "${C_CYAN}${C_BOLD}MENU INICIAL${C_NC}" "center"
    _box_top

    _menu_item 1 "${L_SSH_USERS}"
    _menu_item 2 "${L_ONLINE_USERS}"
    _menu_item 3 "Xray" "$(_get_svc 1)"
    _menu_item 4 "V2Ray" "$(_get_svc 2)"
    _menu_item 5 "SlowDNS" "$(slowdns_is_installed 2>/dev/null && echo active || echo off)"
    _menu_item 6 "BadVPN" "$(badvpn_is_installed 2>/dev/null && echo active || echo off)"
    _menu_item 7 "Bot Telegram" "$(_get_svc 3)"
    _menu_item 8 "${L_SYSINFO}"
    _menu_item 9 "${L_OPEN_PORT}"
    _menu_item 10 "${L_BHTTP}" "$(bhttp_is_installed 2>/dev/null && echo active || echo off)"
    _menu_item 11 "${L_LIMITER}" "$(if limiter_is_installed 2>/dev/null; then limiter_is_active 2>/dev/null && echo active || echo stopped; else echo off; fi)"
    _menu_item 12 "${L_BANNER}" "$(if banner_is_configured 2>/dev/null && _banner_is_active_in_sshd 2>/dev/null; then echo active; else echo off; fi)"
    _menu_item 13 "${L_OTHER_OPT}"
    _menu_item 14 "${L_AUTO_MENU}" "$(auto_menu_is_enabled 2>/dev/null && echo active || echo off)"
    _menu_item 15 "${L_LANGUAGE}"
    _menu_item 16 "${L_UNINSTALL}" "danger"

    _box_top
    _menu_item 0 "${L_EXIT}" "danger"
    _box_top
    echo
    ((UI_ROW++))
}

# ── Menu Principal ────────────────────────────────────────────

main_menu(){
    while true; do
        _lang_load
        _cache_services

        draw_header_full
        _draw_menu_items

        _menu_prompt_pos
        while true; do
            local input="" ch rc
            printf "\r\033[K"
            _center_pad
            printf '%b' "${C_WHITE}Opcao: ${C_NC}"

            while true; do
                # Com caracteres digitados, não há timeout: CPU/RAM não mexe no cursor.
                if [[ -n "$input" ]]; then
                    IFS= read -r -n 1 ch
                else
                    IFS= read -r -n 1 -t 2 ch
                fi
                rc=$?

                if (( rc != 0 )); then
                    # Timeout com prompt vazio: atualiza apenas CPU/RAM.
                    _update_cpu_ram_only
                    continue
                fi

                if [[ -z "$ch" ]]; then
                    # Enter.
                    opt=$input
                    break
                fi

                case "$ch" in
                    $'\177'|$'\b')
                        [[ -n "$input" ]] && { input=${input%?}; printf '\b \b'; }
                        ;;
                    *)
                        input+="$ch"
                        ;;
                esac
            done

            printf '%b\n' "$C_NC"
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
