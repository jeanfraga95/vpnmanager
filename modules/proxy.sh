#!/bin/bash
#============================================================
# proxy.sh - Gerenciador de portas WebSocket / TLS-SSL / SSH XHTTP
#
# Usa os binários 'proxy' (WebSocket, multi-request HTTP),
# 'sslproxy' (TLS/SSL) e 'xhttpssh' (SSH XHTTP) para redirecionar
# uma porta pública até o serviço local.
#
#   WebSocket : ./proxy    --port <PORTA> --to <DESTINO>
#   TLS/SSL   : ./sslproxy --port <PORTA> --to <DESTINO>
#   SSH XHTTP : ./xhttpssh --port <PORTA> --to 22   (destino fixo: OpenSSH)
#
# O "SSH XHTTP" implementa o protocolo XHTTP real (confirmado via
# captura de pacotes de um app cliente de verdade): correlaciona
# sessões pelos cabeçalhos "x-http-sid"/"x-http-mode" (não pela URL),
# responde a perna de download com Content-Type: text/event-stream
# (evita buffer em CDNs como Azion), e o resto é encaminhado cru pro
# OpenSSH local. Não existe VLESS/UUID aqui — quem autentica é o
# próprio usuário/senha do SSH. Fonte em src/xhttpssh.
#
# "XHTTP (em Teste)" (binário 'xhttp2') usa o protocolo por
# "X-Session-ID", mesmo comportamento da referência
# gelwfdmzkz0.map.azionedge.net:
#   - SEM o header    X-Session-ID -> HTTP 400 "missing X-Session-ID header"
#   - GET  com header X-Session-ID -> 200 octet-stream (download SSH)
#   - POST com header X-Session-ID -> 204 (upload) / 404 se sessão não existe
# Upload otimizado: corpo do POST enviado direto ao SSH em chunkes
# (buffer 1 MB, sem acumular a requisição inteira em memória).
#============================================================
source "$INSTALL_DIR/modules/common.sh"

PROXY_BIN_DIR="$INSTALL_DIR/bin"
PROXY_WS_BIN="$PROXY_BIN_DIR/proxy"
PROXY_TLS_BIN="$PROXY_BIN_DIR/sslproxy"
PROXY_XHTTP_BIN="$PROXY_BIN_DIR/xhttpssh"
PROXY_XHTTP_DEST=22
PROXY_SVC_PREFIX="vpnproxy"

# ── Helpers ──────────────────────────────────────────────────

# tipo: "ws" (WebSocket), "tls" (TLS/SSL) ou "xhttp" (SSH XHTTP)
_proxy_bin(){
    case "$1" in
        ws)    echo "$PROXY_WS_BIN" ;;
        tls)   echo "$PROXY_TLS_BIN" ;;
        xhttp) echo "$PROXY_XHTTP_BIN" ;;
    esac
}

_proxy_label(){
    case "$1" in
        ws)    echo "WebSocket" ;;
        tls)   echo "TLS/SSL" ;;
        xhttp) echo "SSH XHTTP" ;;
    esac
}

proxy_ws_is_installed(){ [[ -x "$PROXY_WS_BIN" ]]; }
proxy_tls_is_installed(){ [[ -x "$PROXY_TLS_BIN" ]]; }
proxy_xhttp_is_installed(){ [[ -x "$PROXY_XHTTP_BIN" ]]; }
proxy_is_installed(){ proxy_ws_is_installed || proxy_tls_is_installed; }

_proxy_svc_name(){
    local tipo="$1" porta="$2"
    echo "${PROXY_SVC_PREFIX}-${tipo}-${porta}"
}

# lista as portas abertas de um tipo, uma por linha: "porta|destino|status"
_proxy_list_ports(){
    local tipo="$1"
    for f in /etc/systemd/system/${PROXY_SVC_PREFIX}-${tipo}-*.service; do
        [[ -f "$f" ]] || continue
        local sn porta destino status
        sn=$(basename "$f" .service)
        porta="${sn##*-}"
        destino=$(grep -oP -- '--?to[= ]\K[0-9]+' "$f" | head -1)
        [[ -z "$destino" ]] && destino="22"
        if systemctl is-active --quiet "$sn" 2>/dev/null; then
            status="ATIVO"
        else
            status="PARADO"
        fi
        echo "${porta}|${destino}|${status}"
    done | sort -t'|' -k1 -n
}

# ── Abrir porta ──────────────────────────────────────────────

_proxy_write_service(){
    local tipo="$1" porta="$2" destino="$3"
    local bin sn
    bin=$(_proxy_bin "$tipo")
    sn=$(_proxy_svc_name "$tipo" "$porta")

    local exec_cmd="${bin} --port ${porta} --to ${destino}"

    cat > "/etc/systemd/system/${sn}.service" << SVC
[Unit]
Description=VPNManager Proxy $(_proxy_label "$tipo") port ${porta} -> ${destino}
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

proxy_open_port(){
    local tipo="$1"
    local bin; bin=$(_proxy_bin "$tipo")

    if [[ ! -x "$bin" ]]; then
        fail "${L_PX_BIN_NOT_FOUND_FOR}$(_proxy_label "$tipo")${L_PX_NOT_FOUND_SUFFIX}$bin)"
        pause; return
    fi

    echo
    read -p " ${L_PX_PORT_PROMPT}" porta
    if ! [[ "$porta" =~ ^[0-9]+$ ]] || (( porta < 1 || porta > 65535 )); then
        fail "${L_PX_INVALID_PORT}"
        pause; return
    fi

    local sn; sn=$(_proxy_svc_name "$tipo" "$porta")
    if [[ -f "/etc/systemd/system/${sn}.service" ]]; then
        fail "${L_PX_ALREADY_OPEN}$porta${L_PX_ALREADY_OPEN_MID}$(_proxy_label "$tipo")."
        pause; return
    fi
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${porta}\$"; then
        fail "${L_PX_PORT_IN_USE}$porta${L_PX_PORT_IN_USE_SUFFIX}"
        pause; return
    fi

    if [[ "$tipo" == "xhttp" ]]; then
        destino="$PROXY_XHTTP_DEST"
        echo " ${L_PX_DEST_FIXED}$destino${L_PX_DEST_FIXED_SUFFIX}"
    else
        read -p " ${L_PX_DEST_PROMPT}" destino
        destino="${destino:-22}"
        if ! [[ "$destino" =~ ^[0-9]+$ ]]; then
            fail "${L_PX_INVALID_DEST}"
            pause; return
        fi
    fi

    _proxy_write_service "$tipo" "$porta" "$destino"
    systemctl restart "$sn" >/dev/null 2>&1
    sleep 1

    if systemctl is-active --quiet "$sn"; then
        ok "${L_PX_PORT_OPENED}$porta ($(_proxy_label "$tipo"))${L_PX_PORT_OPENED_SUFFIX}$destino"
    else
        fail "${L_PX_START_FAIL}$sn -n 20"
    fi
    pause
}

# ── Fechar porta ─────────────────────────────────────────────

proxy_close_port(){
    local tipo="$1"
    local ports; ports=$(_proxy_list_ports "$tipo")

    if [[ -z "$ports" ]]; then
        fail "${L_PX_NONE_OPEN}$(_proxy_label "$tipo")${L_PX_NONE_OPEN_SUFFIX}"
        pause; return
    fi

    echo
    echo " ${L_PX_OPEN_PORTS} $(_proxy_label "$tipo"):"
    local i=1
    local -a plist=()
    while IFS='|' read -r porta destino status; do
        [[ -z "$porta" ]] && continue
        printf "  %d) Porta %-6s -> 127.0.0.1:%-6s [%s]\n" "$i" "$porta" "$destino" "$status"
        plist+=("$porta")
        (( i++ ))
    done <<< "$ports"
    echo "  0) ${L_PX_CANCEL}"
    echo
    read -p " ${L_PX_CHOOSE_CLOSE}" opt

    if [[ "$opt" == "0" || -z "$opt" ]]; then
        return
    fi
    if ! [[ "$opt" =~ ^[0-9]+$ ]] || (( opt < 1 || opt > ${#plist[@]} )); then
        fail "${L_PX_INVALID_PORT}"; pause; return
    fi

    local porta="${plist[$((opt-1))]}"
    local sn; sn=$(_proxy_svc_name "$tipo" "$porta")
    systemctl stop "$sn" >/dev/null 2>&1
    systemctl disable "$sn" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${sn}.service"
    systemctl daemon-reload
    ok "${L_PX_PORT_CLOSED}$porta ($(_proxy_label "$tipo"))${L_PX_PORT_CLOSED_SUFFIX}"
    pause
}

# ── Submenu por tipo ─────────────────────────────────────────

_proxy_type_menu(){
    local tipo="$1"
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        printf "${C_CYAN}║${C_WHITE}          ${L_PX_TYPE_TITLE}%-28s${C_CYAN}║${C_NC}\n" "$(_proxy_label "$tipo")"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo

        local ports; ports=$(_proxy_list_ports "$tipo")
        if [[ -z "$ports" ]]; then
            echo -e " ${C_YELLOW}${L_PX_NO_OPEN}${C_NC}"
        else
            echo " ${L_PX_OPEN_PORTS}:"
            while IFS='|' read -r porta destino status; do
                [[ -z "$porta" ]] && continue
                if [[ "$status" == "${L_ACTIVE}" ]]; then
                    printf "  127.0.0.1:%-6s -> destino %-6s  ${C_GREEN}● %s${C_NC}\n" "$porta" "$destino" "$status"
                else
                    printf "  127.0.0.1:%-6s -> destino %-6s  ${C_RED}● %s${C_NC}\n" "$porta" "$destino" "$status"
                fi
            done <<< "$ports"
        fi

        echo
        echo "  1) ${L_PX_OPT_OPEN}"
        echo "  2) ${L_PX_OPT_CLOSE}"
        echo "  0) ${L_PX_OPT_BACK}"
        echo
        read -p " ${L_CHOICE}" op
        case $op in
            1) proxy_open_port "$tipo" ;;
            2) proxy_close_port "$tipo" ;;
            0) break ;;
            *) fail "${L_PX_INVALID_PORT}"; sleep 1 ;;
        esac
    done
}

# ── XHTTP v2 — "XHTTP (em Teste)" ───────────────────────────
# Protocolo por header "X-Session-ID" (comportamento da referência):
#   SEM header  -> 400 "missing X-Session-ID header"
#   GET header  -> 200 application/octet-stream (download SSH, framed)
#   POST header -> 204 (upload streaming) / 404 se sessão não existe
# Upload otimizado: corpo do POST vai direto ao SSH (buffer 1 MB,
# chunked, sem ler a requisição inteira em memória).

PROXY_XHTTP2_BIN="$PROXY_BIN_DIR/xhttp2"
XHTTP2_SVC_PREFIX="vpnproxy-xhttp2"
XHTTP2_CERT="$INSTALL_DIR/conf/xhttp_443_cert.pem"
XHTTP2_KEY="$INSTALL_DIR/conf/xhttp_443_key.pem"

proxy_xhttp2_is_installed(){ [[ -x "$PROXY_XHTTP2_BIN" ]]; }

_xhttp2_list(){
    for f in /etc/systemd/system/${XHTTP2_SVC_PREFIX}-*.service; do
        [[ -f "$f" ]] || continue
        local porta mode status
        local sn; sn=$(basename "$f" .service)
        porta="${sn##*-}"
        if grep -q -- '--tls-port' "$f"; then
            mode="TLS"
        else
            mode="HTTP"
        fi
        if systemctl is-active --quiet "$sn" 2>/dev/null; then
            status="${L_ACTIVE}"
        else
            status="PARADO"
        fi
        echo "${porta}|${mode}|${status}"
    done | sort -t'|' -k1 -n
}

xhttp2_self_test(){
    local porta="$1" mode="$2"
    local url proto code
    if [[ "$mode" == "TLS" ]]; then
        url="https://127.0.0.1:${porta}/"
        proto="--insecure"
    else
        url="http://127.0.0.1:${porta}/"
        proto=""
    fi
    code=$(curl -s -o "/tmp/xhttp2_test_${porta}" -w "%{http_code}" $proto --max-time 6 "$url" 2>/dev/null)
    if [[ "$code" == "400" ]] && grep -q "missing X-Session-ID header" "/tmp/xhttp2_test_${porta}" 2>/dev/null; then
        ok "Porta ${porta}: browser recebe HTTP 400 \"missing X-Session-ID header\" (igual à referência)"
    elif [[ -z "$code" ]]; then
        fail "Porta ${porta}: sem resposta (serviço parado?)"
    else
        fail "Porta ${porta}: resposta inesperada (HTTP ${code})"
    fi
    rm -f "/tmp/xhttp2_test_${porta}"
}

xhttp2_open_port(){
    if ! proxy_xhttp2_is_installed; then
        fail "Binário XHTTP (em Teste) não encontrado: $PROXY_XHTTP2_BIN"
        pause; return
    fi

    echo
    read -p " Porta do XHTTP (em Teste): " porta
    if ! [[ "$porta" =~ ^[0-9]+$ ]] || (( porta < 1 || porta > 65535 )); then
        fail "${L_PX_INVALID_PORT}"
        pause; return
    fi

    local sn="${XHTTP2_SVC_PREFIX}-${porta}"
    if [[ -f "/etc/systemd/system/${sn}.service" ]]; then
        fail "${L_PX_ALREADY_OPEN}$porta${L_PX_ALREADY_OPEN_MID}XHTTP (em Teste)."
        pause; return
    fi
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${porta}\$"; then
        fail "${L_PX_PORT_IN_USE}$porta${L_PX_PORT_IN_USE_SUFFIX}"
        pause; return
    fi

    read -p " Usar TLS? [s/N]: " tlss
    local exec_cmd mode
    if [[ "$tlss" =~ ^[sS]$ ]]; then
        mode="TLS"
        if [[ ! -f "$XHTTP2_CERT" || ! -f "$XHTTP2_KEY" ]]; then
            echo " Gerando certificado autoassinado..."
            openssl req -x509 -newkey rsa:2048 -keyout "$XHTTP2_KEY" \
                -out "$XHTTP2_CERT" -days 3650 -nodes \
                -subj "/CN=$(hostname 2>/dev/null || echo vpnmanager)" >/dev/null 2>&1 || {
                fail "Falha ao gerar certificado TLS."
                pause; return
            }
            chmod 600 "$XHTTP2_KEY"
        fi
        exec_cmd="${PROXY_XHTTP2_BIN} --tls-port ${porta} --tls-cert ${XHTTP2_CERT} --tls-key ${XHTTP2_KEY} --to 22"
    else
        mode="HTTP"
        exec_cmd="${PROXY_XHTTP2_BIN} --port ${porta} --to 22"
    fi

    cat > "/etc/systemd/system/${sn}.service" << SVC
[Unit]
Description=VPNManager XHTTP (em Teste) port ${porta} (${mode}) -> 127.0.0.1:22
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
    systemctl restart "$sn" >/dev/null 2>&1
    sleep 1

    if systemctl is-active --quiet "$sn"; then
        ok "XHTTP (em Teste) aberto na porta ${porta} (${mode}) -> 127.0.0.1:22"
        echo
        echo -e " ${C_YELLOW}Teste: abra no navegador ${C_CYAN}http://$(get_ip 2>/dev/null):${porta}/${C_NC}"
        echo -e " ${C_YELLOW}Deve aparecer: ${C_CYAN}\"missing X-Session-ID header\"${C_NC}"
        if [[ "$mode" == "TLS" ]]; then
            echo -e " ${C_YELLOW}(https://$(get_ip 2>/dev/null):${porta}/)${C_NC}"
        fi
    else
        fail "Falha ao iniciar $sn"
        journalctl -u "$sn" -n 15 --no-pager 2>/dev/null
    fi
    pause
}

xhttp2_close_port(){
    local ports; ports=$(_xhttp2_list)
    if [[ -z "$ports" ]]; then
        fail "Nenhuma porta XHTTP (em Teste) aberta."
        pause; return
    fi

    echo
    echo " Portas XHTTP (em Teste) abertas:"
    local i=1
    local -a plist=()
    while IFS='|' read -r porta mode status; do
        [[ -z "$porta" ]] && continue
        printf "  %d) Porta %-6s (%-4s) [%s]\n" "$i" "$porta" "$mode" "$status"
        plist+=("$porta")
        (( i++ ))
    done <<< "$ports"
    echo "  0) Cancelar"
    echo
    read -p " Escolha a porta para fechar: " opt

    if [[ "$opt" == "0" || -z "$opt" ]]; then
        return
    fi
    if ! [[ "$opt" =~ ^[0-9]+$ ]] || (( opt < 1 || opt > ${#plist[@]} )); then
        fail "${L_PX_INVALID_PORT}"; pause; return
    fi

    local porta="${plist[$((opt-1))]}"
    local sn="${XHTTP2_SVC_PREFIX}-${porta}"
    systemctl stop "$sn" >/dev/null 2>&1
    systemctl disable "$sn" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${sn}.service"
    systemctl daemon-reload
    ok "Porta ${porta} do XHTTP (em Teste) fechada."
    pause
}

_xhttp2_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}              XHTTP (em Teste)  [X-Session-ID]        ${C_CYAN}║${C_NC}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo

        local ports; ports=$(_xhttp2_list)
        if [[ -z "$ports" ]]; then
            echo -e " ${C_YELLOW}Nenhuma porta XHTTP (em Teste) aberta.${C_NC}"
        else
            echo " Portas abertas:"
            while IFS='|' read -r porta mode status; do
                [[ -z "$porta" ]] && continue
                if [[ "$status" == "${L_ACTIVE}" ]]; then
                    printf "  127.0.0.1:%-6s (%4s)  ${C_GREEN}● %s${C_NC}\n" "$porta" "$mode" "$status"
                else
                    printf "  127.0.0.1:%-6s (%4s)  ${C_RED}● %s${C_NC}\n" "$porta" "$mode" "$status"
                fi
            done <<< "$ports"
        fi
        echo
        echo "  1) Abrir nova porta XHTTP (em Teste)"
        echo "  2) Fechar porta XHTTP (em Teste)"
        echo "  3) Status / Testar resposta do browser"
        echo "  0) ${L_PX_OPT_BACK}"
        echo
        read -p " ${L_CHOICE}" op
        case $op in
            1) xhttp2_open_port ;;
            2) xhttp2_close_port ;;
            3)
                ports=$(_xhttp2_list)
                if [[ -z "$ports" ]]; then
                    fail "Nenhuma porta aberta."; sleep 1
                else
                    while IFS='|' read -r porta mode status; do
                        [[ -z "$porta" ]] && continue
                        printf "  127.0.0.1:%-6s (%4s) [%s]\n" "$porta" "$mode" "$status"
                        xhttp2_self_test "$porta" "$mode"
                    done <<< "$ports"
                    pause
                fi
                ;;
            0) break ;;
            *) fail "${L_PX_INVALID_PORT}"; sleep 1 ;;
        esac
    done
}

# ── Menu principal ──────────────────────────────

# ── Squid Proxy ────────────────────────────────────────────────

SQUID_CONF="/etc/squid/squid.conf"
SQUID_CRED="/etc/VPNManager/conf/squid_credentials"

squid_is_installed(){ command -v squid >/dev/null 2>&1; }

squid_is_running(){ systemctl is-active --quiet squid 2>/dev/null; }

squid_install(){
    clear
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
    echo -e "${C_CYAN}║${C_WHITE}          ${L_PX_SQUID}${C_CYAN}║${C_NC}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
    echo

    if squid_is_installed; then
        echo -e " ${C_GREEN}● ${L_PX_SQUID_INSTALLED}${C_NC}"
        echo
        squid_menu_manage
        return
    fi

    echo " ${L_PX_SQUID_INSTALLING}"
    echo

    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -y >/tmp/squid_apt.log 2>&1; then
        fail "${L_PX_SQUID_INSTALL_FAIL}"
        echo "Detalhes (apt-get update):"
        tail -n 15 /tmp/squid_apt.log
        pause; return
    fi
    if ! apt-get install -y squid >/tmp/squid_apt.log 2>&1; then
        fail "${L_PX_SQUID_INSTALL_FAIL}"
        echo "Detalhes (apt-get install squid):"
        tail -n 15 /tmp/squid_apt.log
        pause; return
    fi

    ok "${L_PX_SQUID_INSTALL_OK}"
    echo
    squid_configure
}

squid_configure(){
    echo " ${L_PX_SQUID_CONFIGURING}"
    echo

    local port=3128
    read -p " ${L_PX_SQUID_PORT_PROMPT}" input_port
    port="${input_port:-3128}"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        fail "${L_PX_INVALID_PORT}"
        pause; return
    fi

    # Backup original config
    cp "$SQUID_CONF" "${SQUID_CONF}.bak" 2>/dev/null || true

    # Create PAM config for Squid (uses same auth as SSH)
    cat > /etc/pam.d/squid << 'PAM'
# PAM configuration for Squid Proxy
# Uses same authentication as SSH
@include common-auth
account required pam_permit.so
PAM

    # Write squid.conf with PAM authentication
    cat > "$SQUID_CONF" << CONF
# VPNManager Squid Proxy Configuration
# Generated: $(date)
# Authentication: OpenSSH (PAM)

http_port ${port}

# Access control
acl localhost src 127.0.0.1/32
acl to_localhost dst 127.0.0.0/8

acl localnet src 10.0.0.0/8
acl localnet src 172.16.0.0/12
acl localnet src 192.168.0.0/16

acl CONNECT method CONNECT
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 21
acl Safe_ports port 443
acl Safe_ports port 70
acl Safe_ports port 210
acl Safe_ports port 1025-65535
acl Safe_ports port 280
acl Safe_ports port 488
acl Safe_ports port 591
acl Safe_ports port 777

http_access allow manager
http_access allow localhost
http_access allow localnet
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports

# Authentication via OpenSSH (PAM)
auth_param basic program /usr/lib/squid/basic_pam_auth
auth_param basic children 5
auth_param basic realm VPNManager Squid Proxy
auth_param basic credentialsttl 2 hours

acl authenticated proxy_auth REQUIRED
http_access allow authenticated

# Logging
access_log /var/log/squid/access.log squid
cache_log /var/log/squid/cache.log

# Cache
cache_mem 64 MB
maximum_object_size 64 MB
cache_dir ufs /var/spool/squid 100 16 256

# Behavior
via on
forwarded_for on
httpd_suppress_version_string on
reply_header_max_size 128 KB

# Timeouts
connect_timeout 30 seconds
read_timeout 60 seconds
request_timeout 60 seconds

CONF

    # Save config info for display
    echo "port=$port" > "$SQUID_CRED"
    echo "auth=pam" >> "$SQUID_CRED"

    # Fix permissions
    chown -R proxy:proxy /var/spool/squid 2>/dev/null || true
    chown -R proxy:proxy /var/log/squid 2>/dev/null || true

    # Initialize cache directory
    squid -z --foreground 2>/dev/null || true

    # Restart squid
    systemctl restart squid 2>/dev/null || squid 2>/dev/null
    systemctl enable squid 2>/dev/null || true
    sleep 2

    if squid_is_running; then
        ok "${L_PX_SQUID_CONFIG_OK}"
        echo
        squid_show_details
    else
        fail "${L_PX_SQUID_INSTALL_FAIL}"
        echo "Detalhes do serviço squid:"
        journalctl -u squid -n 15 --no-pager 2>/dev/null
    fi
    pause
}

squid_show_details(){
    if [[ ! -f "$SQUID_CRED" ]]; then
        fail "${L_PX_SQUID_NOT_INSTALLED_MSG}"
        return
    fi

    local port server_ip
    port=$(grep "^port=" "$SQUID_CRED" | cut -d= -f2)
    server_ip=$(get_ip 2>/dev/null || hostname -I | awk '{print $1}')

    # Get a sample SSH user from the database
    local sample_user=""
    if [[ -f /root/pm_users.db ]]; then
        sample_user=$(head -1 /root/pm_users.db | awk '{print $1}')
    fi

    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
    echo -e "${C_CYAN}║${C_WHITE}          ${L_PX_SQUID_DETAILS}              ${C_CYAN}║${C_NC}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
    echo
    echo -e " ${C_GREEN}┌──────────────────────────────────────────────────────┐${C_NC}"
    echo -e " ${C_GREEN}│${C_WHITE}  ${L_PX_SQUID_HOST}: ${C_CYAN}${server_ip}${C_NC}"
    echo -e " ${C_GREEN}│${C_WHITE}  ${L_PX_SQUID_PORT}: ${C_CYAN}${port}${C_NC}"
    echo -e " ${C_GREEN}│${C_WHITE}  ${L_PX_SQUID_AUTH_INFO}"
    echo -e " ${C_GREEN}│${C_WHITE}  ${L_PX_SQUID_USER_HINT}: ${C_CYAN}${sample_user:-user}${C_NC}"
    echo -e " ${C_GREEN}└──────────────────────────────────────────────────────┘${C_NC}"
    echo
    echo -e " ${C_YELLOW}${L_PX_SQUID_USAGE}${C_NC}"
    echo
}

squid_uninstall(){
    clear
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
    echo -e "${C_CYAN}║${C_WHITE}          ${L_PX_SQUID_OPT_UNINSTALL}              ${C_CYAN}║${C_NC}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
    echo

    if ! squid_is_installed; then
        fail "${L_PX_SQUID_NOT_INSTALLED_MSG}"
        pause; return
    fi

    echo -e " ${C_YELLOW}${L_PX_SQUID_CONFIRM_UNINSTALL}${C_NC}"
    read -p " (s/n): " confirm
    if [[ ! "$confirm" =~ ^[sS]$ ]]; then
        return
    fi

    echo " ${L_PX_SQUID_STOPPING}"
    systemctl stop squid 2>/dev/null || true
    systemctl disable squid 2>/dev/null || true

    echo " ${L_PX_SQUID_REMOVING_CONFIG}"
    rm -f "$SQUID_CONF"
    rm -f "$SQUID_CRED"
    rm -f /etc/squid/passwd

    echo " ${L_PX_SQUID_REMOVING_PACKAGE}"
    apt-get remove -y squid --purge >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true

    ok "${L_PX_SQUID_UNINSTALL_OK}"
    pause
}

squid_menu_manage(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}          ${L_PX_SQUID}              ${C_CYAN}║${C_NC}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo

        if squid_is_installed; then
            echo -e " ${C_GREEN}● ${L_PX_SQUID_INSTALLED}${C_NC}"
        else
            echo -e " ${C_RED}● ${L_PX_SQUID_NOT_INSTALLED}${C_NC}"
        fi
        echo

        echo "  1) ${L_PX_SQUID_OPT_VIEW}"
        echo "  2) ${L_PX_SQUID_OPT_UNINSTALL}"
        echo "  0) ${L_PX_OPT_BACK}"
        echo
        read -p " ${L_CHOICE}" op
        case $op in
            1) squid_show_details; pause ;;
            2) squid_uninstall; break ;;
            0) break ;;
            *) fail "${L_PX_INVALID_PORT}"; sleep 1 ;;
        esac
    done
}

proxy_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}                     ${L_PX_TITLE}                           ${C_CYAN}║${C_NC}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_CYAN}${C_NC}"
        echo
        echo " ${L_PX_TYPE_PROMPT}"
        echo
        if proxy_ws_is_installed; then
            echo "  1) ${L_PX_WS}"
        else
            echo -e "  1) ${L_PX_WS} ${C_YELLOW}${L_PX_WS_UNAVAIL}${C_NC}"
        fi
        if proxy_tls_is_installed; then
            echo "  2) ${L_PX_TLS}"
        else
            echo -e "  2) ${L_PX_TLS} ${C_YELLOW}${L_PX_TLS_UNAVAIL}${C_NC}"
        fi
        if proxy_xhttp_is_installed; then
            echo "  3) ${L_PX_XHTTP}"
        else
            echo -e "  3) ${L_PX_XHTTP} ${C_YELLOW}${L_PX_XHTTP_UNAVAIL}${C_NC}"
        fi
        if squid_is_installed; then
            echo -e "  4) ${L_PX_SQUID}  ${C_GREEN}[${L_ACTIVE}]${C_NC}"
        else
            echo "  4) ${L_PX_SQUID}"
        fi
        if proxy_xhttp2_is_installed; then
            echo "  5) XHTTP (em Teste)  [X-Session-ID]"
        else
            echo -e "  5) XHTTP (em Teste)  ${C_YELLOW}[binário indisponível]${C_NC}"
        fi
        echo "  0) ${L_PX_OPT_BACK}"
        echo
        read -p " ${L_CHOICE}" op
        case $op in
            1) proxy_ws_is_installed     && _proxy_type_menu "ws"     || { fail "${L_PX_BIN_NOT_FOUND}"; sleep 2; } ;;
            2) proxy_tls_is_installed    && _proxy_type_menu "tls"    || { fail "${L_PX_BIN_NOT_FOUND}"; sleep 2; } ;;
            3) proxy_xhttp_is_installed  && _proxy_type_menu "xhttp"  || { fail "${L_PX_BIN_NOT_FOUND}"; sleep 2; } ;;
            4) squid_install ;;
            5) proxy_xhttp2_is_installed && _xhttp2_menu              || { fail "${L_PX_BIN_NOT_FOUND}"; sleep 2; } ;;
            0) break ;;
            *) fail "${L_PX_INVALID_PORT}"; sleep 1 ;;
        esac
    done
}
