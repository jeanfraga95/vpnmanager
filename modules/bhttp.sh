#!/bin/bash
#============================================================
# bhttp.sh - Gerenciador de portas BHTTP (Binary HTTP SSH)
#
# Usa o binário 'bhttpssh_dtp' para criar túneis SSH via
# protocolo BHTTP (Binary HTTP) sobre portas que passam
# por firewalls/CAPTIVE portals (porta 80, etc).
#
#   BHTTP : ./bhttpssh_dtp --port <PORTA> --static-target <SSH> [--fallback-target <PROXY>]
#
# O BHTTP funciona como proxy transparente entre o app
# (conexão BHTTP) e o sshd local, permitindo túnel SSH
# mesmo em redes que bloqueiam portas não-padrão.
#============================================================

source "$INSTALL_DIR/modules/common.sh"

BHTTP_BIN="$INSTALL_DIR/bin/bhttpssh_dtp"
BHTTP_SVC_PREFIX="vpnproxy-bhttp"
BHTTP_SSHD_PORT=2223
BHTTP_SSHD_CONF="/etc/ssh/sshd_config_bhttp"

# ── Helpers ──────────────────────────────────────────────────

bhttp_is_installed(){ [[ -x "$BHTTP_BIN" ]]; }

_bhttp_svc_name(){
    local porta="$1"
    echo "${BHTTP_SVC_PREFIX}-${porta}"
}

# Normaliza um destino "host:porta": se o usuario digitar apenas
# uma porta (ex: 8080), completa com 127.0.0.1:porta.
_bhttp_norm_target(){
    local t="$1"
    t="${t//[[:space:]]/}"
    [[ -z "$t" ]] && { echo ""; return; }
    if [[ "$t" =~ ^[0-9]+$ ]]; then
        echo "127.0.0.1:${t}"
    elif [[ "$t" =~ ^:[0-9]+$ ]]; then
        echo "127.0.0.1${t}"
    else
        echo "$t"
    fi
}

# Lista portas BHTTP abertas: "porta|destino|fallback|status"
_bhttp_list_ports(){
    for f in /etc/systemd/system/${BHTTP_SVC_PREFIX}-*.service; do
        [[ -f "$f" ]] || continue
        local sn porta destino fallback status
        sn=$(basename "$f" .service)
        porta="${sn##*-}"
        destino=$(grep -oP -- '--static-target[= ]\K[0-9.:]+' "$f" | head -1)
        fallback=$(grep -oP -- '--fallback-target[= ]\K[0-9.:]+' "$f" | head -1)
        [[ -z "$destino" ]] && destino="127.0.0.1:2223"
        [[ -z "$fallback" ]] && fallback="-"
        if systemctl is-active --quiet "$sn" 2>/dev/null; then
            status="ATIVO"
        else
            status="PARADO"
        fi
        echo "${porta}|${destino}|${fallback}|${status}"
    done | sort -t'|' -k1 -n
}

# ── Escrever servico systemd ─────────────────────────────────

_bhttp_write_service(){
    local porta="$1" destino="$2" fallback="$3"
    local bin="$BHTTP_BIN"
    local sn; sn=$(_bhttp_svc_name "$porta")

    local exec_cmd="${bin} --port ${porta} --static-target ${destino}"
    [[ -n "$fallback" && "$fallback" != "-" ]] && exec_cmd="${exec_cmd} --fallback-target ${fallback}"

    cat > "/etc/systemd/system/${sn}.service" << SVC
[Unit]
Description=VPNManager BHTTP SSH tunnel port ${porta} -> ${destino}
After=network.target

[Service]
User=root
ExecStart=${exec_cmd}
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    systemctl enable "$sn" >/dev/null 2>&1
}

# ── Configurar sshd para BHTTP ───────────────────────────────

_bhttp_setup_sshd(){
    if [[ ! -f "$BHTTP_SSHD_CONF" ]]; then
        cat > "$BHTTP_SSHD_CONF" << CONF
Port ${BHTTP_SSHD_PORT}
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_rsa_key
PermitRootLogin yes
PasswordAuthentication yes
AllowTcpForwarding yes
GatewayPorts yes
ClientAliveInterval 30
ClientAliveCountMax 5
MaxSessions 100
LogLevel INFO
UsePAM yes
CONF
    fi

    # Servico sshd-bhttp
    if [[ ! -f /etc/systemd/system/sshd-bhttp.service ]]; then
        cat > /etc/systemd/system/sshd-bhttp.service << 'SVC'
[Unit]
Description=SSH server for BHTTP tunnel (port 2223)
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/sshd -D -f /etc/ssh/sshd_config_bhttp
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload
        systemctl enable sshd-bhttp 2>/dev/null
        systemctl start sshd-bhttp 2>/dev/null
        ok "sshd-bhttp iniciado na porta ${BHTTP_SSHD_PORT}"
    else
        systemctl is-active --quiet sshd-bhttp 2>/dev/null || {
            systemctl start sshd-bhttp 2>/dev/null
        }
    fi
}

# ── Abrir porta BHTTP ────────────────────────────────────────

bhttp_open_port(){
    if [[ ! -x "$BHTTP_BIN" ]]; then
        fail "${L_BH_BIN_NOT_FOUND}"
        pause; return
    fi

    echo
    read -p " ${L_BH_PORT_PROMPT}" porta
    if ! [[ "$porta" =~ ^[0-9]+$ ]] || (( porta < 1 || porta > 65535 )); then
        fail "${L_BH_INVALID_PORT}"
        pause; return
    fi

    if [[ "$porta" == "80" ]]; then
        echo
        echo " Configurando stack completa na porta 80 (WebSocket/BHTTP/HCR)..."
        bash "$INSTALL_DIR/modules/port80_stack.sh"
        ok "Porta 80 ativa: WebSocket/BHTTP/HCR"
        pause
        return
    fi

    local sn; sn=$(_bhttp_svc_name "$porta")
    if [[ -f "/etc/systemd/system/${sn}.service" ]]; then
        fail "${L_BH_ALREADY_OPEN}${porta}"
        pause; return
    fi
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${porta}\$"; then
        fail "${L_BH_PORT_IN_USE}${porta}"
        pause; return
    fi

    local destino
    read -p " ${L_BH_DEST_PROMPT}" destino
    destino="${destino:-127.0.0.1:2223}"
    destino="$(_bhttp_norm_target "$destino")"

    local fallback
    read -p " ${L_BH_FALLBACK_PROMPT}" fallback
    fallback="${fallback:-}"
    fallback="$(_bhttp_norm_target "$fallback")"

    _bhttp_setup_sshd
    _bhttp_write_service "$porta" "$destino" "$fallback"
    systemctl restart "$sn" >/dev/null 2>&1
    sleep 1

    if systemctl is-active --quiet "$sn"; then
        ok "${L_BH_PORT_OPENED}${porta} -> ${destino}"
        [[ -n "$fallback" && "$fallback" != "-" ]] && echo -e "  ${C_DIM}Fallback: ${fallback}${C_NC}"
    else
        fail "${L_BH_START_FAIL}${sn}"
        echo "  journalctl -u ${sn} -n 20"
    fi
    pause
}

# ── Fechar porta BHTTP ───────────────────────────────────────

bhttp_close_port(){
    local ports; ports=$(_bhttp_list_ports)

    if [[ -z "$ports" ]]; then
        fail "${L_BH_NONE_OPEN}"
        pause; return
    fi

    echo
    echo " ${L_BH_OPEN_PORTS}:"
    local i=1
    local -a plist=()
    while IFS='|' read -r porta destino fallback status; do
        [[ -z "$porta" ]] && continue
        local info="${porta} -> ${destino}"
        [[ -n "$fallback" && "$fallback" != "-" ]] && info="${info} (fb: ${fallback})"
        printf "  %d) %-40s [%s]\n" "$i" "$info" "$status"
        plist+=("$porta")
        (( i++ ))
    done <<< "$ports"
    echo "  0) ${L_BH_CANCEL}"
    echo
    read -p " ${L_BH_CHOOSE_CLOSE}" opt

    if [[ "$opt" == "0" || -z "$opt" ]]; then
        return
    fi
    if ! [[ "$opt" =~ ^[0-9]+$ ]] || (( opt < 1 || opt > ${#plist[@]} )); then
        fail "${L_BH_INVALID_CHOICE}"; pause; return
    fi

    local porta="${plist[$((opt-1))]}"
    local sn; sn=$(_bhttp_svc_name "$porta")
    systemctl stop "$sn" >/dev/null 2>&1
    systemctl disable "$sn" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${sn}.service"
    systemctl daemon-reload
    ok "${L_BH_PORT_CLOSED}${porta}"
    pause
}

# ── Ver portas abertas ───────────────────────────────────────

bhttp_list_ports(){
    local ports; ports=$(_bhttp_list_ports)

    echo
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
    printf "${C_CYAN}║${C_WHITE}          %-44s${C_CYAN}║${C_NC}\n" "${L_BH_TITLE}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
    echo

    if [[ -z "$ports" ]]; then
        echo -e "  ${C_YELLOW}${L_BH_NO_OPEN}${C_NC}"
    else
        echo "  ${L_BH_OPEN_PORTS}:"
        echo
        while IFS='|' read -r porta destino fallback status; do
            [[ -z "$porta" ]] && continue
            local icon
            if [[ "$status" == "ATIVO" ]]; then
                icon="${C_GREEN}●${C_NC}"
            else
                icon="${C_RED}●${C_NC}"
            fi
            local info="porta ${porta} -> ${destino}"
            [[ -n "$fallback" && "$fallback" != "-" ]] && info="${info} (fb: ${fallback})"
            printf "  %b %-40s [%s]\n" "$icon" "$info" "$status"
        done <<< "$ports"
    fi

    echo
    # Status do sshd-bhttp
    if systemctl is-active --quiet sshd-bhttp 2>/dev/null; then
        echo -e "  ${C_GREEN}●${C_NC} sshd-bhttp (porta ${BHTTP_SSHD_PORT}) ${C_GREEN}ATIVO${C_NC}"
    else
        echo -e "  ${C_RED}●${C_NC} sshd-bhttp (porta ${BHTTP_SSHD_PORT}) ${C_RED}PARADO${C_NC}"
    fi
    echo
    pause
}

# ── Menu BHTTP ───────────────────────────────────────────────

bhttp_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        printf "${C_CYAN}║${C_WHITE}          %-44s${C_CYAN}║${C_NC}\n" "${L_BH_TITLE}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo

        if bhttp_is_installed; then
            echo -e "  ${C_GREEN}● ${L_BH_INSTALLED}${C_NC}"
        else
            echo -e "  ${C_RED}● ${L_BH_NOT_INSTALLED}${C_NC}"
        fi

        # Mostrar portas abertas resumido
        local ports; ports=$(_bhttp_list_ports)
        if [[ -n "$ports" ]]; then
            echo
            while IFS='|' read -r porta destino fallback status; do
                [[ -z "$porta" ]] && continue
                local icon
                [[ "$status" == "ATIVO" ]] && icon="${C_GREEN}●${C_NC}" || icon="${C_RED}●${C_NC}"
                printf "  %b %-10s -> %-20s\n" "$icon" ":${porta}" "$destino"
            done <<< "$ports"
        fi

        echo
        echo "  1) ${L_BH_OPT_OPEN}"
        echo "  2) ${L_BH_OPT_CLOSE}"
        echo "  3) ${L_BH_OPT_LIST}"
        echo "  0) ${L_BH_OPT_BACK}"
        echo
        read -p " ${L_CHOICE}" op
        case $op in
            1) bhttp_open_port ;;
            2) bhttp_close_port ;;
            3) bhttp_list_ports ;;
            0) break ;;
            *) fail "${L_INVALID_CHOICE}"; sleep 1 ;;
        esac
    done
}
