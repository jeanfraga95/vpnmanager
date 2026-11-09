#!/bin/bash
#============================================================
# limiter.sh - Limitador de conexões simultâneas
#
# Roda em segundo plano (systemd) e periodicamente verifica
# quantas sessões cada usuário SSH tem abertas. Se o total
# ultrapassar o limite definido em /root/pm_users.db (mesma
# convenção do ssh_users.sh), derruba as sessões mais novas
# até voltar dentro do limite. limite "0" = ilimitado.
#============================================================
source "$INSTALL_DIR/modules/common.sh"

LIMITER_SERVICE="/etc/systemd/system/vpnlimiter.service"
LIMITER_SCRIPT="/usr/local/bin/vpnlimiter_worker.sh"
LIMITER_CONF="$INSTALL_DIR/conf/limiter.conf"
LIMITER_LOG="/var/log/vpnlimiter.log"
LIMITER_DEFAULT_INTERVAL=15
LIMITER_PM_DB="/root/pm_users.db"

# ── Helpers ──────────────────────────────────────────────────

limiter_is_installed(){ [[ -f "$LIMITER_SERVICE" ]]; }

limiter_is_active(){ systemctl is-active --quiet vpnlimiter 2>/dev/null; }

_limiter_load_conf(){ [[ -f "$LIMITER_CONF" ]] && source "$LIMITER_CONF" 2>/dev/null; }

# ── Geração do worker (script que roda em loop) ───────────────

_write_limiter_worker(){
    local interval="$1"

    cat > "$LIMITER_SCRIPT" << WORKEREOF
#!/bin/bash
#============================================================
# vpnlimiter_worker.sh — gerado automaticamente pelo VPNManager
#============================================================
PM_DB="${LIMITER_PM_DB}"
LOG_FILE="${LIMITER_LOG}"
INTERVAL="${interval}"

log_kick(){
    echo "\$(date '+%Y-%m-%d %H:%M:%S') \$1" >> "\$LOG_FILE"
}

while true; do
    if [[ -f "\$PM_DB" ]]; then
        while read -r user limit _rest; do
            [[ -z "\$user" || -z "\$limit" ]] && continue
            [[ "\$limit" =~ ^[0-9]+\$ ]] || continue
            [[ "\$limit" == "0" ]] && continue

            mapfile -t pids < <(ps -u "\$user" -o pid=,etimes= 2>/dev/null \\
                | awk '{print \$2, \$1}' | sort -rn | awk '{print \$2}')
            total=\${#pids[@]}

            if (( total > limit )); then
                excess=\$(( total - limit ))
                killed=0
                for (( i = total - excess; i < total; i++ )); do
                    kill -9 "\${pids[i]}" 2>/dev/null && (( killed++ ))
                done
                (( killed > 0 )) && log_kick "usuario '\$user': \$total conexao(oes) (limite \$limit) - \$killed sessao(oes) derrubada(s)"
            fi
        done < "\$PM_DB"
    fi
    sleep "\$INTERVAL"
done
WORKEREOF

    chmod +x "$LIMITER_SCRIPT"
}

# ── Serviço systemd ───────────────────────────────────────────

_write_limiter_service(){
    cat > "$LIMITER_SERVICE" << SVC
[Unit]
Description=VPNManager Limitador de Conexoes
After=network.target

[Service]
User=root
ExecStart=/bin/bash ${LIMITER_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
}

# ── Ativar ────────────────────────────────────────────────────

limiter_install(){
    clear
    echo -e "${C_CYAN}== ${L_LM_INSTALL_TITLE} ==${C_NC}"
    echo
    echo " ${L_LM_INSTALL_DESC1}"
    echo " ${L_LM_INSTALL_DESC2}"
    echo " ${L_LM_INSTALL_DESC3}"
    echo
    read -p " ${L_LM_INSTALL_INTERVAL}${LIMITER_DEFAULT_INTERVAL}): " interval
    interval="${interval:-$LIMITER_DEFAULT_INTERVAL}"
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( interval < 3 )); then
        fail "Intervalo inválido (mínimo 3 segundos)."
        pause; return
    fi

    mkdir -p "$(dirname "$LIMITER_CONF")"
    touch "$LIMITER_LOG"

    _write_limiter_worker "$interval"
    _write_limiter_service

    cat > "$LIMITER_CONF" << CONF
LIMITER_INTERVAL="$interval"
CONF

    systemctl enable vpnlimiter 2>/dev/null
    systemctl restart vpnlimiter
    sleep 1

    if limiter_is_active; then
        ok "${L_LM_ACTIVE_MSG}${interval}${L_LM_ACTIVE_SUFFIX}"
    else
        fail "${L_LM_NOT_STARTED}"
        journalctl -u vpnlimiter -n 15 --no-pager 2>/dev/null
    fi
    pause
}

# ── Alterar intervalo ─────────────────────────────────────────

limiter_change_interval(){
    clear
    echo -e "${C_CYAN}== ${L_LM_CHANGE_TITLE} ==${C_NC}"
    _limiter_load_conf
    echo
    echo " ${L_LM_CHANGE_CURRENT}${LIMITER_INTERVAL:-$LIMITER_DEFAULT_INTERVAL}s"
    read -p " ${L_LM_CHANGE_NEW} " interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || (( interval < 3 )); then
        fail "${L_LM_INVALID_INTERVAL}"
        pause; return
    fi

    _write_limiter_worker "$interval"
    cat > "$LIMITER_CONF" << CONF
LIMITER_INTERVAL="$interval"
CONF
    systemctl restart vpnlimiter
    ok "${L_LM_CHANGE_DONE}${interval}s."
    pause
}

# ── Pausar / Retomar ──────────────────────────────────────────

limiter_toggle(){
    if limiter_is_active; then
        systemctl stop vpnlimiter
        ok "${L_LM_PAUSED_MSG}"
    else
        systemctl start vpnlimiter
        sleep 1
        limiter_is_active && ok "${L_LM_RESUMED}" || fail "${L_LM_RESUME_FAIL}"
    fi
    pause
}

# ── Ver log ───────────────────────────────────────────────────

limiter_view_log(){
    clear
    echo -e "${C_CYAN}== ${L_LM_LOG_TITLE} ==${C_NC}"
    echo
    if [[ -s "$LIMITER_LOG" ]]; then
        tail -n 30 "$LIMITER_LOG"
    else
        echo -e "${C_YELLOW}${L_LM_LOG_NONE}${C_NC}"
    fi
    pause
}

# ── Desinstalar ───────────────────────────────────────────────

limiter_uninstall(){
    clear
    echo -e "${C_RED}== ${L_LM_UNINSTALL_TITLE} ==${C_NC}"
    read -p "${L_LM_UNINSTALL_CONFIRM} " conf
    [[ "$conf" =~ ^[sS]$ ]] || return
    systemctl disable --now vpnlimiter 2>/dev/null
    rm -f "$LIMITER_SERVICE" "$LIMITER_SCRIPT" "$LIMITER_CONF"
    systemctl daemon-reload
    ok "${L_LM_UNINSTALL_DONE}"
    pause
}

# ── Menu ──────────────────────────────────────────────────────

limiter_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}               ${L_LM_TITLE}                       ${C_CYAN}║${C_NC}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo

        _limiter_load_conf
        if limiter_is_installed; then
            local badge
            limiter_is_active \
                && badge="${C_GREEN}● ${L_LM_ACTIVE}${C_NC}" \
                || badge="${C_RED}● ${L_LM_PAUSED}${C_NC}"
            echo -e " Status    : $badge"
            echo -e " ${L_LM_INTERVAL} : ${C_GREEN}${LIMITER_INTERVAL:-$LIMITER_DEFAULT_INTERVAL}s${C_NC}"
            local kicks; kicks=$(wc -l < "$LIMITER_LOG" 2>/dev/null); kicks="${kicks:-0}"
            echo -e " ${L_LM_SESSIONS_KICKED}: ${C_GREEN}${kicks}${C_NC}"
            echo
            echo "  1) $(limiter_is_active && echo "${L_LM_OPT_PAUSE}" || echo "${L_LM_OPT_RESUME}")"
            echo "  2) ${L_LM_OPT_CHANGE_INTERVAL}"
            echo "  3) ${L_LM_OPT_VIEW_LOG}"
            echo "  4) ${L_LM_OPT_REMOVE}"
            echo "  0) ${L_LM_OPT_BACK}"
        else
            echo -e " ${C_YELLOW}${L_LM_DISABLED}${C_NC}"
            echo " ${L_LM_DISABLED_MSG1}"
            echo " ${L_LM_DISABLED_MSG2}"
            echo
            echo "  1) ${L_LM_OPT_ENABLE}"
            echo "  0) ${L_LM_OPT_BACK}"
        fi
        echo
        read -p " ${L_CHOICE}" op

        if limiter_is_installed; then
            case $op in
                1) limiter_toggle ;;
                2) limiter_change_interval ;;
                3) limiter_view_log ;;
                4) limiter_uninstall ;;
                0) break ;;
                *) fail "${L_LM_INVALID}"; sleep 1 ;;
            esac
        else
            case $op in
                1) limiter_install ;;
                0) break ;;
                *) fail "${L_LM_INVALID}"; sleep 1 ;;
            esac
        fi
    done
}
