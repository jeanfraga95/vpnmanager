#!/bin/bash
#============================================================
# bhttp.sh - Gerenciador de portas BHTTP (Binary HTTP SSH)
#
# Usa o binário 'vpnproxy-unified' para criar entradas publicas que
# servem BHTTP/HCR/XHTTP/WS/CONNECT/SOCKS/TLS na MESMA porta.
#
#   vpnproxy-unified --port <PORTA> --static-target <SSH> \
#     --hcr-target ... --xhttp-target ... --ws-to ...
#
# Nao ha prompt de fallback: o destino e escolhido automaticamente,
# gravado em conf/bhttp_fallback.conf e reutilizado em todas as portas.
# --silent-ws e aplicado em todas elas (inclusive 80): cliente silencioso
# recebe 101; BHTTP/HCR/XHTTP/WS com dados seguem o roteamento normal.
#============================================================

source "$INSTALL_DIR/modules/common.sh"

BHTTP_BIN="$INSTALL_DIR/bin/bhttpssh_dtp"          # legado (nao usado para abrir portas)
UNIFIED_BIN="$INSTALL_DIR/bin/vpnproxy-unified"
BHTTP_SVC_PREFIX="vpnproxy-bhttp"
BHTTP_SSHD_PORT=2223
BHTTP_SSHD_CONF="/etc/ssh/sshd_config_bhttp"
FALLBACK_CONF="$INSTALL_DIR/conf/bhttp_fallback.conf"
BHTTP_CERT="$INSTALL_DIR/conf/bhttp_80_cert.pem"
BHTTP_KEY="$INSTALL_DIR/conf/bhttp_80_key.pem"

# ── Helpers ──────────────────────────────────────────────────

bhttp_is_installed(){ [[ -x "$UNIFIED_BIN" ]]; }

# A porta 80 pode pertencer a outro sistema (ex.: proto-server/dtproto).
# Nesses casos o VPNManager nunca a toca: 8080 vira a porta publica principal.
_bhttp_port_listener(){
    ss -lntp 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {print; exit}'
}
_bhttp_port_is_busy(){ [[ -n "$(_bhttp_port_listener "$1")" ]]; }
_bhttp_port_process(){
    local line; line=$(_bhttp_port_listener "$1")
    grep -o 'users:(("[^"]*"' <<<"$line" | head -1 | sed 's/users:(("//; s/"$//'
}
_bhttp_port_is_ours(){
    local line; line=$(_bhttp_port_listener "$1")
    [[ -n "$line" ]] && grep -Eq 'vpnproxy|bhttpssh|hcr-server' <<<"$line"
}

# Certificados usados pelo proxy unificado e pelo HCR interno.
# O instalador antigo criava esses arquivos via port80_stack.sh; aqui o
# modulo BHTTP passa a garanti-los sozinho (inclusive quando a 80 esta
# ocupada por outro sistema e o stack legado nao roda).
_bhttp_ensure_certs(){
    mkdir -p "$INSTALL_DIR/conf"
    local cn; cn="$(hostname 2>/dev/null || echo vpnmanager)"
    if [[ ! -f "$BHTTP_CERT" || ! -f "$BHTTP_KEY" ]]; then
        openssl req -x509 -newkey rsa:2048 -keyout "$BHTTP_KEY" \
            -out "$BHTTP_CERT" -days 3650 -nodes -subj "/CN=${cn}" \
            >/dev/null 2>&1 || return 1
        chmod 600 "$BHTTP_KEY"
        chmod 644 "$BHTTP_CERT"
    fi
    if [[ ! -f "$INSTALL_DIR/conf/hcr_80_cert.pem" || ! -f "$INSTALL_DIR/conf/hcr_80_key.pem" ]]; then
        openssl req -x509 -newkey rsa:2048 \
            -keyout "$INSTALL_DIR/conf/hcr_80_key.pem" \
            -out "$INSTALL_DIR/conf/hcr_80_cert.pem" -days 3650 -nodes \
            -subj "/CN=${cn}" >/dev/null 2>&1 || return 1
        chmod 600 "$INSTALL_DIR/conf/hcr_80_key.pem"
        chmod 644 "$INSTALL_DIR/conf/hcr_80_cert.pem"
    fi
}

# Garante a porta publica principal do BHTTP:
#  - 80 livre (ou ja do VPNManager): usa 80;
#  - 80 ocupada por outro sistema: nao mexe nela e usa 8080.
# Chamado pelo instalador e pode ser chamado pelo menu.
_bhttp_ensure_primary_port(){
    _bhttp_ensure_certs || return 1
    _bhttp_setup_sshd
    _bhttp_ensure_internals

    if ! _bhttp_port_is_busy 80 || _bhttp_port_is_ours 80; then
        if [[ ! -f /etc/systemd/system/vpnproxy-unified.service ]]; then
            local fb; fb=$(_bhttp_ensure_fallback)
            [[ "$fb" == "127.0.0.1:80" ]] && fb=""
            _bhttp_write_unified_service 80 "127.0.0.1:2223" "$fb"
        fi
        systemctl is-active --quiet vpnproxy-unified 2>/dev/null || \
            systemctl start vpnproxy-unified >/dev/null 2>&1 || true
        echo "BHTTP principal: porta 80"
    else
        local owner; owner=$(_bhttp_port_process 80)
        echo "AVISO: porta 80 em uso por ${owner:-outro servico}; VPNManager nao mexe nela."
        echo "BHTTP principal: porta 8080"
        printf '%s\n' '127.0.0.1:8080' > "$FALLBACK_CONF"
        _bhttp_ensure_fallback >/dev/null
        if ! systemctl is-active --quiet vpnproxy-unified-8080 2>/dev/null; then
            systemctl restart vpnproxy-unified-8080 >/dev/null 2>&1 || true
        fi
    fi
}

# Nome canonico do servico unificado de cada porta.
_bhttp_svc_name(){
    local porta="$1"
    case "$porta" in
        80)   echo "vpnproxy-unified" ;;
        8080) echo "vpnproxy-unified-8080" ;;
        *)    echo "vpnproxy-unified-${porta}" ;;
    esac
}

# Porta a partir do nome do servico unificado.
_bhttp_port_from_svc(){
    local sn="$1"
    [[ "$sn" == "vpnproxy-unified" ]] && { echo "80"; return; }
    echo "${sn##*-}"
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

# Descobre um fallback ja existente. Ordem: configuracao salva,
# servicos unificados ativos, unidades BHTTP legadas, padrao 8080.
_bhttp_find_fallback(){
    local cfg target f sn porta_svc

    if [[ -f "$FALLBACK_CONF" ]]; then
        cfg=$(head -n 1 "$FALLBACK_CONF" | tr -d '[:space:]')
        cfg="$(_bhttp_norm_target "$cfg")"
        [[ -n "$cfg" ]] && { echo "$cfg"; return; }
    fi

    for f in /etc/systemd/system/vpnproxy-unified*.service \
             /etc/systemd/system/${BHTTP_SVC_PREFIX}-*.service; do
        [[ -f "$f" ]] || continue
        target=$(grep -oP -- '--fallback-target[= ]\K[0-9.:]+' "$f" | head -1)
        [[ -z "$target" ]] && continue
        sn=$(basename "$f" .service)
        porta_svc=$(_bhttp_port_from_svc "$sn")
        # Nunca usa a propria porta como fallback.
        [[ "$target" == "127.0.0.1:${porta_svc}" ]] && continue
        target="$(_bhttp_norm_target "$target")"
        [[ -n "$target" ]] && { echo "$target"; return; }
    done

    echo "127.0.0.1:8080"
}

# Garante que o alvo do fallback esteja disponivel, sem perguntar nada.
_bhttp_ensure_fallback(){
    local fb fport sn bin
    fb="$(_bhttp_find_fallback)"
    fb="$(_bhttp_norm_target "$fb")"
    [[ -z "$fb" ]] && fb="127.0.0.1:8080"

    mkdir -p "$(dirname "$FALLBACK_CONF")"
    printf '%s\n' "$fb" > "$FALLBACK_CONF"

    fport="${fb##*:}"
    if [[ "$fport" == "8080" ]]; then
        sn="vpnproxy-unified-8080"
        if [[ ! -f "/etc/systemd/system/${sn}.service" ]]; then
            _bhttp_write_unified_service 8080 "127.0.0.1:22" ""
        fi
        systemctl is-active --quiet "$sn" 2>/dev/null || \
            systemctl start "$sn" >/dev/null 2>&1 || true
    elif [[ "$fport" == "19080" ]]; then
        sn="vpnproxy-fallback"
        bin="$INSTALL_DIR/bin/fallback-proxy/fallback-proxy"
        if [[ -x "$bin" && ! -f "/etc/systemd/system/${sn}.service" ]]; then
            cat > "/etc/systemd/system/${sn}.service" << SVC
[Unit]
Description=VPNManager fallback interno 19080 (HCR + WebSocket + XHTTP)
After=network.target hcr-server.service vpnproxy-xhttp-11443.service
Wants=hcr-server.service vpnproxy-xhttp-11443.service

[Service]
Type=simple
ExecStart=${bin}
Restart=always
RestartSec=2s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SVC
            systemctl daemon-reload
            systemctl enable "$sn" >/dev/null 2>&1
        fi
        if [[ -f "/etc/systemd/system/${sn}.service" ]]; then
            systemctl is-active --quiet "$sn" 2>/dev/null || \
                systemctl start "$sn" >/dev/null 2>&1 || true
        fi
    fi

    printf '%s' "$fb"
}

# Backends internos precisam estar vivos; nunca reinicia os que ja estao.
_bhttp_ensure_internals(){
    local svc
    for svc in sshd-bhttp hcr-server vpnproxy-xhttp-11443; do
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl start "$svc" >/dev/null 2>&1 || true
        fi
    done
}

# Lista portas unificadas abertas: "porta|destino|fallback|status"
_bhttp_list_ports(){
    local f
    for f in /etc/systemd/system/vpnproxy-unified.service \
             /etc/systemd/system/vpnproxy-unified-*.service; do
        [[ -f "$f" ]] || continue
        local sn porta destino fallback status
        sn=$(basename "$f" .service)
        porta=$(_bhttp_port_from_svc "$sn")
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

# Baixo nivel: nao descobre fallback (evita recursao ao garantir a 8080).
# --silent-ws vai em TODAS as portas: cliente sem dados recebe 101 imediato;
# BHTTP/HCR/XHTTP/WS com dados continuam no roteamento normal.
_bhttp_write_unified_service(){
    local porta="$1" destino="$2" fallback="${3:-}"
    local sn; sn=$(_bhttp_svc_name "$porta")

    local exec_cmd="${UNIFIED_BIN} --port ${porta} --silent-ws --static-target ${destino}"
    [[ -n "$fallback" && "$fallback" != "-" ]] && exec_cmd="${exec_cmd} --fallback-target ${fallback}"
    exec_cmd="${exec_cmd} --idle 24h --quic-port ${porta}"
    exec_cmd="${exec_cmd} --tls-cert ${BHTTP_CERT} --tls-key ${BHTTP_KEY}"
    exec_cmd="${exec_cmd} --hcr-target 127.0.0.1:18082"
    exec_cmd="${exec_cmd} --xhttp-target 127.0.0.1:11443"
    exec_cmd="${exec_cmd} --ws-to 127.0.0.1:22"

    cat > "/etc/systemd/system/${sn}.service" << SVC
[Unit]
Description=VPNManager unified proxy ${porta} (BHTTP/HCR/WS/XHTTP/SSH) -> ${destino}
After=network-online.target ssh.service sshd-bhttp.service hcr-server.service vpnproxy-xhttp-11443.service
Wants=network-online.target ssh.service sshd-bhttp.service

[Service]
Type=simple
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

_bhttp_write_service(){
    local porta="$1" destino="$2" fallback="${3:-}"
    _bhttp_write_unified_service "$porta" "$destino" "$fallback"
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
    if ! bhttp_is_installed; then
        fail "${L_BH_BIN_NOT_FOUND}"
        pause; return
    fi

    echo
    read -p " ${L_BH_PORT_PROMPT}" porta
    if ! [[ "$porta" =~ ^[0-9]+$ ]] || (( porta < 1 || porta > 65535 )); then
        fail "${L_BH_INVALID_PORT}"
        pause; return
    fi

    # Se a 80 pertence a outro sistema (ex.: dtproto/proto-server), nao a
    # tocamos: redirecionamos a abertura para a 8080, porta principal aqui.
    if [[ "$porta" == "80" ]] && _bhttp_port_is_busy 80 && ! _bhttp_port_is_ours 80; then
        local owner; owner=$(_bhttp_port_process 80)
        msg "Porta 80 reservada por ${owner:-outro servico}; usando 8080."
        porta=8080
    fi

    local sn; sn=$(_bhttp_svc_name "$porta")
    if [[ -f "/etc/systemd/system/${sn}.service" ]]; then
        if [[ "$porta" == "8080" ]]; then
            systemctl is-active --quiet "$sn" 2>/dev/null || \
                systemctl restart "$sn" >/dev/null 2>&1 || true
            ok "Porta 8080 ja e a principal do BHTTP; servico ${sn} ativo."
            pause; return
        fi
        fail "${L_BH_ALREADY_OPEN}${porta}"
        pause; return
    fi
    if _bhttp_port_is_busy "$porta"; then
        fail "${L_BH_PORT_IN_USE}${porta}"
        pause; return
    fi

    local destino
    read -p " ${L_BH_DEST_PROMPT}" destino
    destino="${destino:-127.0.0.1:2223}"
    destino="$(_bhttp_norm_target "$destino")"

    # Fallback e decidido/configurado em background e reutilizado sempre.
    local fallback
    fallback=$(_bhttp_ensure_fallback)
    # Nunca aponta a propria porta como fallback (evita loop).
    [[ "$fallback" == "127.0.0.1:${porta}" ]] && fallback=""

    _bhttp_ensure_certs || { fail "Falha ao gerar certificados do BHTTP"; pause; return; }
    _bhttp_setup_sshd
    _bhttp_ensure_internals
    _bhttp_write_service "$porta" "$destino" "$fallback"
    systemctl restart "$sn" >/dev/null 2>&1
    sleep 1

    if systemctl is-active --quiet "$sn"; then
        ok "${L_BH_PORT_OPENED}${porta} -> ${destino}"
        echo -e "  ${C_DIM}Todos os protocolos na mesma porta; fallback automatico: ${fallback:-none}${C_NC}"
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
    if [[ "$porta" == "80" || "$porta" == "8080" ]]; then
        fail "Porta ${porta} e canonica; nao pode ser fechada por aqui."
        pause; return
    fi

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
