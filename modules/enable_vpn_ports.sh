#!/bin/bash
#============================================================
# enable_vpn_ports.sh - habilita portas publicas e servicos do VPNManager
#============================================================
# Chamado pelo install.sh (e reexecutavel a qualquer momento).
# Idempotente e nao destrutivo:
#
#   * 80   -> vpnproxy-unified (BHTTP + WS/HCR/XHTTP -> 127.0.0.1:22),
#             somente se a porta estiver livre ou ja for nossa. Se outro
#             sistema (ex.: proto-server/dtproto) a ocupa, nada e tocado.
#   * 8080 -> vpnproxy-unified-8080 (mesmos protocolos da 80), sempre.
#   * 443  -> Xray VLESS (xhttp/tls, fallback SSH -> 22) somente se a
#             porta estiver livre ou ja for Xray. Se stunnel/outro servico
#             a ocupa, apenas liberamos o firewall e preservamos o dono.
#
# Uso: bash /etc/VPNManager/modules/enable_vpn_ports.sh
#============================================================
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/etc/VPNManager}"
MODULES="$INSTALL_DIR/modules"
CONF="$INSTALL_DIR/conf/vpnmanager.conf"

[[ -f "$MODULES/common.sh" ]] && source "$MODULES/common.sh"
[[ -f "$MODULES/linguagem.sh" ]] && source "$MODULES/linguagem.sh"

# Cores e funcoes de log (garantem saida mesmo se os modulos nao carregarem)
C_GREEN="${C_GREEN:-\033[1;32m}"; C_YELLOW="${C_YELLOW:-\033[1;33m}"
C_CYAN="${C_CYAN:-\033[1;36m}";   C_RED="${C_RED:-\033[1;31m}"
C_NC="${C_NC:-\033[0m}"
msg(){  echo -e "${C_CYAN}[*]${C_NC} $*"; }
ok(){   echo -e "${C_GREEN}[OK]${C_NC} $*"; }
warn(){ echo -e "${C_YELLOW}[AVISO]${C_NC} $*"; }
fail(){ echo -e "${C_RED}[ERRO]${C_NC} $*"; }
conf_get(){ [[ -f "$CONF" ]] && grep "^$1=" "$CONF" | cut -d'=' -f2-; }
conf_set(){
    local key="$1" val="$2" lock="${CONF}.lock"
    exec 9>"$lock"; flock -x 9
    touch "$CONF"
    if grep -q "^$key=" "$CONF" 2>/dev/null; then
        sed -i "s|^$key=.*|$key=$val|" "$CONF"
    else
        echo "$key=$val" >> "$CONF"
    fi
    flock -u 9
}

# Processo que escuta numa porta TCP publica.
# O campo users:(("nome",pid=...)) do ss trunca o nome em 15 caracteres
# ("vpnproxy-unifie"), entao resolvemos o nome real via /proc/<pid>/exe.
_port_owner(){
    local port="$1" line pid exe
    line=$(ss -lntp 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p {print $NF; exit}')
    [[ -z "$line" ]] && return 0
    pid=$(printf '%s' "$line" | grep -oP 'pid=\K[0-9]+' | head -1)
    if [[ -n "$pid" && -r "/proc/$pid/exe" ]]; then
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
        if [[ -n "$exe" ]]; then
            # binario substituido/apagado aparece como "/usr/bin/stunnel4 (deleted)"
            exe=${exe% \(deleted\)}
            basename "$exe"
            return 0
        fi
    fi
    printf '%s' "$line" | sed -nE 's/.*\("([^"]+)".*/\1/p'
}

# Libera a porta em UFW, firewalld e iptables. Nunca remove regras alheias.
_fw_allow(){
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        if ! ufw status 2>/dev/null | grep -Eq "^${port}/tcp[[:space:]]+(ALLOW|LIMIT)"; then
            ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then
        if ! firewall-cmd --permanent --list-ports 2>/dev/null | grep -q "^${port}/tcp$"; then
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi
    fi
    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
        fi
        if [[ -f /etc/iptables/rules.v4 ]] && \
           ! grep -q -- "--dport ${port} -j ACCEPT" /etc/iptables/rules.v4 2>/dev/null; then
            sed -i "/^:OUTPUT ACCEPT/a -A INPUT -p tcp --dport ${port} -j ACCEPT" \
                /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
}

# Garante que a unit unificada de uma porta esteja enable + ativa.
_ensure_unified(){
    local port="$1" unit="$2"
    [[ -f "/etc/systemd/system/${unit}.service" ]] || {
        warn "Unit ${unit}.service nao encontrada; nada a habilitar na porta ${port}."
        return 0
    }
    systemctl enable "$unit" >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
        systemctl restart "$unit" >/dev/null 2>&1 || true
    fi
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        ok "Porta ${port}: ${unit} ativo (BHTTP + WS/HCR/XHTTP -> 127.0.0.1:22)"
    else
        warn "Porta ${port}: ${unit} nao iniciou (ver: journalctl -u ${unit})"
    fi
}

# Configura o Xray na 443 apenas quando a porta nao pertence a outro sistema.
_ensure_xray_443(){
    local port=443 owner host uuid
    owner=$(_port_owner "$port")

    if [[ -n "$owner" && "$owner" != "xray" ]]; then
        warn "Porta ${port} pertence a '${owner}'; Xray nao foi alterado (firewall liberado)."
        return 0
    fi
    if [[ "$owner" == "xray" && "$(conf_get XRAY_PORT)" == "$port" && -s "$CRED_FILE" ]]; then
        ok "Xray ja configurado e ativo na porta ${port}."
        return 0
    fi
    [[ -f "$MODULES/xray.sh" ]] || { warn "Modulo xray.sh ausente; Xray nao configurado."; return 0; }

    source "$MODULES/xray.sh"

    if ! install_xray_core >/dev/null 2>&1; then
        warn "Nao foi possivel instalar/atualizar o Xray-core (firewall liberado)."
        return 0
    fi

    host=$(get_ip 2>/dev/null || true)
    [[ -z "$host" || "$host" == "N/D" ]] && host=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$host" ]] && host="127.0.0.1"

    if ! generate_selfsigned_cert "$host" >/dev/null 2>&1; then
        warn "Nao foi possivel gerar o certificado do Xray (firewall liberado)."
        return 0
    fi

    uuid=$(gen_uuid)
    if ! write_xray_config "$port" "tls" "$uuid" "22" "xhttp" >/dev/null 2>&1; then
        warn "Nao foi possivel escrever o config do Xray (firewall liberado)."
        return 0
    fi

    if xray_restart_and_check "$port" >/dev/null 2>&1; then
        conf_set "XRAY_PORT"      "$port"
        conf_set "XRAY_HOST"      "$host"
        conf_set "XRAY_MODE"      "tls"
        conf_set "XRAY_TRANSPORT" "xhttp"
        xray_save_credentials "$port" "tls" "$host" "$uuid" "xhttp" >/dev/null 2>&1 || true
        ok "Xray VLESS (xhttp/tls) ativo na porta ${port}, fallback SSH -> 22."
    else
        warn "Xray nao iniciou na porta ${port}; firewall liberado e servicos preservados."
    fi
}

main(){
    msg "Habilitando portas publicas do VPNManager (80, 8080, 443)..."
    local p
    for p in 80 8080 443; do _fw_allow "$p"; done

    # Backends internos (sshd-bhttp 2223, HCR 18082, XHTTP 11443).
    if [[ -f "$MODULES/port80_stack.sh" ]]; then
        VPNMANAGER_SKIP_PUBLIC=1 bash "$MODULES/port80_stack.sh" >/dev/null 2>&1 || true
    fi

    local owner80
    owner80=$(_port_owner 80)
    if [[ -z "$owner80" || "$owner80" == "vpnproxy-unified" ]]; then
        _ensure_unified 80 vpnproxy-unified
    else
        warn "Porta 80 pertence a '${owner80}'; VPNManager nao a altera (principal: 8080)."
    fi
    _ensure_unified 8080 vpnproxy-unified-8080
    _ensure_xray_443

    echo
    msg "Resumo das portas publicas:"
    for p in 80 8080 443; do
        local own; own=$(_port_owner "$p")
        printf '  %-5s -> %s\n' "$p" "${own:-livre}"
    done
    return 0
}

main "$@"
