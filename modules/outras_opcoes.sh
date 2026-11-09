#!/bin/bash
#============================================================
# outras_opcoes.sh - Outras Opções do menu
#============================================================
source "$INSTALL_DIR/modules/common.sh"
source "$INSTALL_DIR/modules/linguagem.sh"
source "$INSTALL_DIR/modules/swap.sh"

_lang_load

PM_DB="/root/pm_users.db"
CHECKUSER_SVC="checkuser"

outras_opcoes_checkuser_active(){
    checkuser_is_enabled
}

outras_opcoes_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}              ${L_OTHER_TITLE}              ${C_CYAN}║${C_NC}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo
        if checkuser_is_enabled; then
            echo -e "  1) ${L_CHECKUSER}  ${C_GREEN}(ON)${C_NC}"
        else
            echo "  1) ${L_CHECKUSER}  (OFF)"
        fi
        echo "  2) ${L_RESTART_ALL}"
        echo "  3) ${L_LANGUAGE}"
        echo "  4) ${L_SWAP}"
        echo "  5) ${C_WHITE}Limpar arquivos inúteis${C_NC}"
        echo
        echo "  0) ${L_BACK}"
        echo
        echo -e "${C_CYAN}──────────────────────────────────────────────────────────${C_NC}"
        read -p " ${L_CHOICE}" op
        case $op in
            1) checkuser_toggle_screen ;;
            2) restart_all_services ;;
            3) linguagem_menu ;;
            4) swap_menu ;;
            5) clean_junk ;;
            0) break ;;
            *) fail "${L_INVALID}"; sleep 1 ;;
        esac
    done
}

# ── CheckUser: verifica se serviço está ativo ────────────────
checkuser_is_enabled(){
    systemctl is-active --quiet "$CHECKUSER_SVC" 2>/dev/null
}

checkuser_enable(){
    systemctl enable "$CHECKUSER_SVC" 2>/dev/null
    systemctl start "$CHECKUSER_SVC" 2>/dev/null
}

checkuser_disable(){
    systemctl stop "$CHECKUSER_SVC" 2>/dev/null
    systemctl disable "$CHECKUSER_SVC" 2>/dev/null
}

checkuser_toggle_screen(){
    clear
    echo -e "${C_CYAN}== ${L_CK_TITLE} ==${C_NC}"
    echo
    local IP=$(get_ip)
    if checkuser_is_enabled; then
        echo -e " ${L_CK_STATUS} ${C_GREEN}${L_CK_ENABLED}${C_NC}"
        echo
        echo " ${L_CK_ENDPOINTS}"
        echo "   ${L_CK_APP}    http://${IP}:2052/check/<usuario>?deviceId=android"
        echo "   ${L_CK_BROWSER} http://${IP}:2052/checkuser/dtunnel.php?user=<usuario>"
        echo "   ${L_CK_WEBUI}  http://${IP}:2052/"
        echo
        echo " ${L_CK_CONFIG}"
        echo "   ${L_CK_URL} http://${IP}:2052/"
        echo
        echo -e " ${L_CK_EXAMPLE} http://${IP}:2052/check/user12?deviceId=android"
        echo
        read -p " ${L_CK_DISABLE} [${L_CK_YES}/${L_CK_NO}]: " resp
        if [[ "$resp" =~ ^[sSyY]$ ]]; then
            checkuser_disable
            ok "${L_CK_DISABLED}."
        fi
    else
        echo -e " ${L_CK_STATUS} ${C_RED}${L_CK_DISABLED}${C_NC}"
        echo " ${L_CK_OFF_MSG}"
        echo
        echo " ${L_CK_ON_MSG}"
        echo "   ${L_CK_URL} http://${IP}:2052/"
        echo
        echo " ${L_CK_ENDPOINTS}"
        echo "   ${L_CK_APP}    http://${IP}:2052/check/<usuario>?deviceId=android"
        echo "   ${L_CK_BROWSER} http://${IP}:2052/checkuser/dtunnel.php?user=<usuario>"
        echo "   ${L_CK_WEBUI}  http://${IP}:2052/"
        echo
        read -p " ${L_CK_ENABLE} [${L_CK_YES}/${L_CK_NO}]: " resp
        if [[ "$resp" =~ ^[sSyY]$ ]]; then
            checkuser_enable
            ok "${L_CK_ENABLED}."
        fi
    fi
    pause
}

restart_all_services(){
    clear
    echo -e "${C_CYAN}== ${L_RST_TITLE} ==${C_NC}"
    echo
    echo " ${L_RST_RESTARTING}"
    echo

    local ok_count=0 fail_count=0

    _try_restart(){
        local name="$1"
        if systemctl is-active --quiet "$name" 2>/dev/null; then
            if systemctl restart "$name" 2>/dev/null; then
                echo -e "  ${C_GREEN}✓${C_NC} $name"
                (( ok_count++ ))
            else
                echo -e "  ${C_RED}✗${C_NC} $name (falha)"
                (( fail_count++ ))
            fi
        else
            echo -e "  ${C_YELLOW}○${C_NC} $name (parado)"
        fi
    }

    _try_restart "sshd"

    for svc in /etc/systemd/system/vpnproxy-*.service; do
        [[ -f "$svc" ]] || continue
        _try_restart "$(basename "$svc" .service)"
    done

    _try_restart "$CHECKUSER_SVC"

    for name in xray v2ray slowdns badvpn; do
        _try_restart "$name"
    done

    systemctl daemon-reload 2>/dev/null

    echo
    echo -e "  ${C_GREEN}${L_RST_OK} $ok_count${C_NC}  ${C_RED}${L_RST_FAIL} $fail_count${C_NC}"
    pause
}

# ── Limpeza de arquivos inúteis ───────────────────────────────

_clean_human(){
    local bytes=$(( $1 ))
    if (( bytes >= 1073741824 )); then
        awk -v b="$bytes" 'BEGIN{printf "%.2f GB", b/1073741824}'
    elif (( bytes >= 1048576 )); then
        awk -v b="$bytes" 'BEGIN{printf "%.2f MB", b/1048576}'
    elif (( bytes >= 1024 )); then
        awk -v b="$bytes" 'BEGIN{printf "%.2f KB", b/1024}'
    else
        printf "%d B" "$bytes"
    fi
}

clean_junk(){
    clear
    echo -e "${C_CYAN}== Limpeza de arquivos inúteis ==${C_NC}"
    echo
    echo " Limpando arquivos temporários e desnecessários..."
    echo

    local before
    before=$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}')
    [[ "$before" =~ ^[0-9]+$ ]] || before=0

    # bytes acumulados dos itens removidos para relatório
    local freed=0

    _add_freed_kb(){
        local kb="$1"
        [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
        freed=$(( freed + (kb * 1024) ))
    }

    _try_item(){
        local path="$1"
        if [[ -e "$path" ]]; then
            local sz; sz=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
            _add_freed_kb "$sz"
            rm -rf "$path" 2>/dev/null
            echo -e "  ${C_GREEN}✓${C_NC} removido: $path"
        fi
    }

    # cache de pacotes (apt)
    if command -v apt-get >/dev/null 2>&1; then
        echo -e "  ${C_YELLOW}→${C_NC} cache apt..."
        local apt_before; apt_before=$(du -sk /var/cache/apt/archives 2>/dev/null | awk '{print $1}')
        [[ "$apt_before" =~ ^[0-9]+$ ]] || apt_before=0
        apt-get clean >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
        local apt_after; apt_after=$(du -sk /var/cache/apt/archives 2>/dev/null | awk '{print $1}')
        [[ "$apt_after" =~ ^[0-9]+$ ]] || apt_after=0
        local apt_freed=$(( apt_before > apt_after ? apt_before - apt_after : 0 ))
        _add_freed_kb "$apt_freed"
        echo -e "  ${C_GREEN}✓${C_NC} removido: cache de pacotes (apt)"
    fi

    # núcleos de crash
    _try_item "/var/crash"

    # pacotes .deb soltos no /tmp e /var/tmp
    local deb_list
    deb_list=$(find /tmp /var/tmp -maxdepth 1 -type f -name '*.deb' 2>/dev/null)
    if [[ -n "$deb_list" ]]; then
        local debkb; debkb=$(echo "$deb_list" | xargs -r du -sc 2>/dev/null | awk 'END{print $1}')
        _add_freed_kb "$debkb"
        echo "$deb_list" | xargs -r rm -f 2>/dev/null
        echo -e "  ${C_GREEN}✓${C_NC} removido: pacotes .deb soltos"
    fi

    # logs girados antigos (mantém os atuais .log sem sufixo)
    local logbytes
    logbytes=$(find /var/log -type f \( -name '*.gz' -o -name '*.old' -o -name '*.1' -o -name '*.log.*' -o -name '*.xz' \) 2>/dev/null | grep -v '\.log$')
    if [[ -n "$logbytes" ]]; then
        local lb; lb=$(echo "$logbytes" | xargs -r du -sc 2>/dev/null | awk 'END{print $1}')
        _add_freed_kb "$lb"
        echo "$logbytes" | xargs -r rm -f 2>/dev/null
        echo -e "  ${C_GREEN}✓${C_NC} removido: logs girados antigos"
    fi

    # journal antigo
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-time=7d >/dev/null 2>&1
        echo -e "  ${C_GREEN}✓${C_NC} journal antigo (> 7 dias) compactado"
    fi

    # arquivos temporários com mais de 7 dias
    local tmp_freed
    tmp_freed=$(find /tmp /var/tmp -type f -mtime +7 -size +1M 2>/dev/null | wc -l)
    [[ "$tmp_freed" =~ ^[0-9]+$ ]] || tmp_freed=0
    find /tmp /var/tmp -type f -mtime +7 -size +1M -delete 2>/dev/null
    if (( tmp_freed > 0 )); then
        echo -e "  ${C_GREEN}✓${C_NC} removidos $tmp_freed arquivos temporários antigos"
    fi

    # thrashes / core dumps do sistema
    find / -xdev -maxdepth 4 \( -name 'core' -o -name 'core.*' \) -size +10M -delete 2>/dev/null 2>&1 || true

    local after
    after=$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}')
    [[ "$after" =~ ^[0-9]+$ ]] || after=0

    echo
    echo -e "${C_CYAN}════════════════════════════════════════════════════${C_NC}"
    local delta=$(( after - before ))
    if (( delta > 0 )); then
        echo -e " ${C_GREEN}Espaço liberado: $(_clean_human $(( delta * 1024 )))${C_NC}"
    else
        local f2=$(( freed > 0 ? freed : 0 ))
        echo -e " ${C_YELLOW}Espaço liberado: $(_clean_human $f2)${C_NC}"
    fi
    echo -e " ${C_WHITE}Espaço livre atual: $(_clean_human $(( after * 1024 )))${C_NC}"
    echo -e "${C_CYAN}════════════════════════════════════════════════════${C_NC}"
    echo
    pause
}
