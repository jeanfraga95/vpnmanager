#!/bin/bash
#============================================================
#  VPNManager Lite - Instalador
#============================================================
set -e

INSTALL_DIR="/etc/VPNManager"
BIN_LINK="/usr/local/bin/menuvpn"
LOG_FILE="/tmp/vpnmanager_install.log"
: > "$LOG_FILE"

G="\033[1;32m"; R="\033[1;31m"; C="\033[1;36m"; Y="\033[1;33m"; NC="\033[0m"

[[ "$EUID" -ne 0 ]] && { echo -e "${R}[ERRO]${NC} Execute como root."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Barra de progresso ──────────────────────────────────────
# Uso: run_step "Descrição" comando args...
# Toda a saída do comando vai para $LOG_FILE; em caso de erro,
# mostra o final do log e aborta.

TOTAL_STEPS=12
CUR_STEP=0

draw_progress(){
    local pct=$(( CUR_STEP * 100 / TOTAL_STEPS ))
    local filled=$(( pct / 2 ))
    local empty=$(( 50 - filled ))
    local bar; bar=$(printf "%${filled}s" | tr ' ' '#')
    local rest; rest=$(printf "%${empty}s" | tr ' ' '-')
    printf "\r${C}[%s%s] %3d%%${NC}  %-45s" "$bar" "$rest" "$pct" "$1"
}

run_step(){
    local desc="$1"; shift
    draw_progress "$desc"
    if ! "$@" >> "$LOG_FILE" 2>&1; then
        echo
        echo -e "${R}[ERRO]${NC} Falha em: $desc"
        echo -e "${Y}Últimas linhas do log ($LOG_FILE):${NC}"
        tail -n 20 "$LOG_FILE"
        exit 1
    fi
    CUR_STEP=$(( CUR_STEP + 1 ))
    draw_progress "$desc"
}

# ── Passo 1: estrutura de diretórios ────────────────────────

step_dirs(){
    mkdir -p "$INSTALL_DIR/modules" "$INSTALL_DIR/conf" "$INSTALL_DIR/bin"
    mkdir -p /etc/SSHPlus/senha /etc/PanelMaster /etc/usuarios
    touch /root/pm_users.db 2>/dev/null || true
    groupadd pmg_vpn 2>/dev/null || true
}

# ── Passo 2: copiar módulos ─────────────────────────────────

step_copy_modules(){
    cp "$SCRIPT_DIR/menu.sh"                 "$INSTALL_DIR/menu.sh"
    cp "$SCRIPT_DIR/modules/common.sh"       "$INSTALL_DIR/modules/common.sh"
    cp "$SCRIPT_DIR/modules/ssh_users.sh"    "$INSTALL_DIR/modules/ssh_users.sh"
    cp "$SCRIPT_DIR/modules/xray.sh"         "$INSTALL_DIR/modules/xray.sh"
    cp "$SCRIPT_DIR/modules/v2ray.sh"        "$INSTALL_DIR/modules/v2ray.sh"
    cp "$SCRIPT_DIR/modules/online_users.sh" "$INSTALL_DIR/modules/online_users.sh"
    cp "$SCRIPT_DIR/modules/slowdns.sh"      "$INSTALL_DIR/modules/slowdns.sh"
    cp "$SCRIPT_DIR/modules/badvpn.sh"       "$INSTALL_DIR/modules/badvpn.sh"
    cp "$SCRIPT_DIR/modules/telegram_bot.sh" "$INSTALL_DIR/modules/telegram_bot.sh"
    cp "$SCRIPT_DIR/modules/system_info.sh"  "$INSTALL_DIR/modules/system_info.sh"
    cp "$SCRIPT_DIR/modules/proxy.sh"        "$INSTALL_DIR/modules/proxy.sh"
    cp "$SCRIPT_DIR/modules/bhttp.sh"        "$INSTALL_DIR/modules/bhttp.sh"
    cp "$SCRIPT_DIR/modules/port80_stack.sh" "$INSTALL_DIR/modules/port80_stack.sh"
    cp "$SCRIPT_DIR/modules/limiter.sh"      "$INSTALL_DIR/modules/limiter.sh"
    cp "$SCRIPT_DIR/modules/banner.sh"       "$INSTALL_DIR/modules/banner.sh"
    cp "$SCRIPT_DIR/modules/outras_opcoes.sh" "$INSTALL_DIR/modules/outras_opcoes.sh"
    cp "$SCRIPT_DIR/modules/linguagem.sh"     "$INSTALL_DIR/modules/linguagem.sh"
    cp "$SCRIPT_DIR/modules/swap.sh"          "$INSTALL_DIR/modules/swap.sh"
    chmod +x "$INSTALL_DIR/menu.sh"
    chmod +x "$INSTALL_DIR/modules/"*.sh
    ln -sf "$INSTALL_DIR/menu.sh" "$BIN_LINK"
}

# ── Passo 3: dependências dos proxies (WebSocket/TLS-SSL) ──

step_proxy_deps(){
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a 2>/dev/null || true
    apt-get update -y
    apt-get install -y libevent-2.1-* libevent-openssl-2.1-* libssl3 libssl-dev openssl || true
    # curl (necessário pelo instalador oficial do Xray via processo
    # bash <(curl ...)) e jq (usado para gerar o config.json do Xray)
    apt-get install -y cron unzip python3 curl jq || true
}

# ── Passo 3b: ajustes de sistema (kernel/roteamento) ─────────
# Mesmos ajustes aplicados por instaladores VPN de mercado
# (sshplus etc.) para estabilidade e roteamento:
#   - desliga IPv6 (evita travamentos de conexão IPv6)
#   - ativa IP forward (roteamento de pacotes)
#   - desativa rp_filter (evita derrubar conexões legítimas)
#   - tcp_tw_reuse (reuso de sockets TIME_WAIT)

step_sys_tune(){
    # desliga IPv6
    if ! grep -q "disable_ipv6" /etc/sysctl.d/70-disable-ipv6.conf 2>/dev/null; then
        echo -e "net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1" > /etc/sysctl.d/70-disable-ipv6.conf
    fi
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true

    # IP forward + rp_filter + TIME_WAIT reuse
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || true

    # persiste no sysctl.conf (sem duplicar)
    _sysctl_persist(){ local k="$1" v="$2"; sed -i "/^[# ]*${k}[ ]*=/d" /etc/sysctl.conf; echo "${k} = ${v}" >> /etc/sysctl.conf; }
    _sysctl_persist "net.ipv4.ip_forward" "1"
    _sysctl_persist "net.ipv4.conf.all.rp_filter" "0"
    _sysctl_persist "net.ipv4.tcp_tw_reuse" "1"
    _sysctl_persist "net.ipv6.conf.all.disable_ipv6" "1"
    _sysctl_persist "net.ipv6.conf.default.disable_ipv6" "1"
    sysctl -p >/dev/null 2>&1 || true
}

# ── Passo 4: binário do proxy conforme arquitetura ──────────

step_proxy_bin(){
    local arch; arch="$(uname -m)"
    local src=""
    case "$arch" in
        x86_64|amd64)
            src="$SCRIPT_DIR/bin/x86_64" ;;
        aarch64|arm64)
            src="$SCRIPT_DIR/bin/aarch64" ;;
        *)
            echo "Arquitetura não suportada para os proxies: $arch"
            return 0 ;;
    esac
    [[ -d "$src" ]] || return 0

    # se já existem portas abertas (reinstalação), os binários atuais
    # estão em uso pelos serviços — para evitar "Text file busy" ao
    # sobrescrever, paramos esses serviços antes e religamos depois,
    # já com o binário atualizado.
    local was_active=()
    for svc in /etc/systemd/system/vpnproxy-*.service; do
        [[ -f "$svc" ]] || continue
        local sn; sn=$(basename "$svc" .service)
        systemctl is-active --quiet "$sn" 2>/dev/null && was_active+=("$sn")
        systemctl stop "$sn" 2>/dev/null || true
    done

    # troca atômica: copia para um arquivo temporário no mesmo
    # diretório e troca por cima com 'mv' — isso funciona mesmo que
    # algum processo ainda esteja com o binário antigo aberto (mv/
    # rename não mexe no inode em uso, só troca a entrada do
    # diretório), diferente de 'cp' direto no destino.
    local name
    for name in proxy sslproxy xhttpssh checkuser bhttpssh_dtp xhttp2 hcr-server hcr-dispatcher; do
        if [[ -f "$src/$name" ]]; then
            cp "$src/$name" "$INSTALL_DIR/bin/${name}.new"
            chmod +x "$INSTALL_DIR/bin/${name}.new"
            mv -f "$INSTALL_DIR/bin/${name}.new" "$INSTALL_DIR/bin/${name}"
        fi
    done

    for sn in "${was_active[@]}"; do
        systemctl start "$sn" 2>/dev/null || true
    done
}

# ── Passo 4b: certificados SSL do sslproxy ──────────────────
# O binário 'sslproxy' (TLS/SSL) usa caminhos fixos
# /opt/magnumproxy/cert.pem e /opt/magnumproxy/key.pem e ABORTA
# (exit) se não existirem. Geramos um certificado autoassinado
# RSA-2048 válido por 10 anos, se ainda não houver.

step_sslproxy_certs(){
    mkdir -p /opt/magnumproxy
    if [[ ! -f /opt/magnumproxy/cert.pem || ! -f /opt/magnumproxy/key.pem ]]; then
        local cn; cn="$(hostname 2>/dev/null || echo vpnmanager)"
        openssl req -x509 -newkey rsa:2048 -keyout /opt/magnumproxy/key.pem \
            -out /opt/magnumproxy/cert.pem -days 3650 -nodes \
            -subj "/CN=${cn}" >/dev/null 2>&1 || return 1
        chmod 600 /opt/magnumproxy/key.pem
        chmod 644 /opt/magnumproxy/cert.pem
    fi
}

# ── Passo 3c: firewall — liberar loopback e sem limite de IP ─
# Muitos painéis instalam proteção connlimit (ex.: limite de 3
# conexões SYN simultâneas por IP na porta 22). Isso quebra os
# proxies: as conexões de backend (WS/TLS/XHTTP) para o SSH saem
# de 127.0.0.1 e, com CDN/polling ou vários usuários atrás da
# mesma NAT, o limite é estourado e o iptables corta com RST
# ("connection refused"). Aqui liberamos o loopback e removemos
# esses limites por IP.

step_iptables_lo(){
    # 1) aceita tudo vindo do loopback (backend dos proxies)
    if ! iptables -C INPUT -i lo -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -i lo -j ACCEPT
    fi

    # 2) remove qualquer connlimit (limite por IP) nas portas comuns
    local p
    for p in 22 80 443 8080 8443 8085 8899 9443 18085 2052 7270 3128 2223 60000 61000; do
        iptables -D INPUT -p tcp --dport "$p" --tcp-flags FIN,SYN,RST,ACK SYN \
            -m connlimit --connlimit-above 1 --connlimit-mask 32 --connlimit-saddr \
            -j REJECT --reject-with tcp-reset 2>/dev/null
        iptables -D INPUT -p tcp --dport "$p" --tcp-flags FIN,SYN,RST,ACK SYN \
            -m connlimit --connlimit-above 3 --connlimit-mask 32 --connlimit-saddr \
            -j REJECT --reject-with tcp-reset 2>/dev/null
        iptables -D INPUT -p tcp --dport "$p" --tcp-flags FIN,SYN,RST,ACK SYN \
            -m connlimit --connlimit-above 10 --connlimit-mask 32 --connlimit-saddr \
            -j REJECT --reject-with tcp-reset 2>/dev/null
    done
    iptables -D FORWARD -p tcp --tcp-flags FIN,SYN,RST,ACK SYN \
        -m connlimit --connlimit-above 10 --connlimit-mask 32 --connlimit-saddr \
        -j REJECT --reject-with tcp-reset 2>/dev/null

    # 3) persiste: garante o ACCEPT do loopback e remove os REJECT
    #    connlimit do rules.v4 (mantém o restante intacto)
    if [[ -f /etc/iptables/rules.v4 ]]; then
        grep -q "^\-A INPUT \-i lo \-j ACCEPT" /etc/iptables/rules.v4 \
            || sed -i '/^:OUTPUT ACCEPT/a -A INPUT -i lo -j ACCEPT' /etc/iptables/rules.v4
        sed -i '/connlimit.*--reject-with tcp-reset/d' /etc/iptables/rules.v4
    fi
}


# Corrige o erro "no matching host key type found" que ocorre
# em servidores recém-formatados sem par de chaves gerado.

# ── Passo 6: chaves de host SSH ─────────────────────────────
step_ssh_hostkeys(){
    [[ -f /etc/ssh/ssh_host_ed25519_key ]] || ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
    [[ -f /etc/ssh/ssh_host_ecdsa_key   ]] || ssh-keygen -t ecdsa   -f /etc/ssh/ssh_host_ecdsa_key   -N ""
    [[ -f /etc/ssh/ssh_host_rsa_key     ]] || ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N ""
    [[ -f /etc/ssh/ssh_host_dsa_key     ]] || ssh-keygen -t dsa     -f /etc/ssh/ssh_host_dsa_key     -N "" || true
    chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
    chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
}

# ── Passo 6: sshd_config / ssh_config ───────────────────────

_ssh_set_directive(){
    # $1 arquivo  $2 diretiva  $3 valor
    local file="$1" key="$2" val="$3"
    if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$file" 2>/dev/null; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$file"
    else
        echo "${key} ${val}" >> "$file"
    fi
}

step_ssh_config(){
    local sshd_conf="/etc/ssh/sshd_config"
    local ssh_conf="/etc/ssh/ssh_config"

    cp "$sshd_conf" "${sshd_conf}.bak.$(date +%s)" 2>/dev/null || true

    _ssh_set_directive "$sshd_conf" "PermitRootLogin"     "yes"
    _ssh_set_directive "$sshd_conf" "PasswordAuthentication" "yes"
    _ssh_set_directive "$sshd_conf" "AllowAgentForwarding" "yes"
    _ssh_set_directive "$sshd_conf" "AllowTcpForwarding"   "yes"
    _ssh_set_directive "$sshd_conf" "GatewayPorts"         "yes"
    _ssh_set_directive "$sshd_conf" "X11Forwarding"        "yes"
    _ssh_set_directive "$sshd_conf" "PermitTTY"            "yes"
    _ssh_set_directive "$sshd_conf" "TCPKeepAlive"         "yes"
    _ssh_set_directive "$sshd_conf" "PermitTunnel"         "yes"

    # IMPORTANTE: Tunnel=yes no ssh_config faz o cliente ssh tentar
    # criar um dispositivo tun (tun0/tun1...) em TODA conexão e isso
    # segura a sessão aberta após o comando remoto terminar (hang de
    # ~40s no teardown, rc=124). Mantemos PermitTunnel=yes no sshd
    # (permite túnel quando solicitado explicitamente) mas deixamos o
    # cliente com Tunnel=no para não travar conexões normais.
    if [[ -f "$ssh_conf" ]]; then
        _ssh_set_directive "$ssh_conf" "Tunnel" "no"
    fi

    sshd -t
}

# ── Passo 7: reiniciar serviço SSH ──────────────────────────
# Nunca deixa esta etapa travar ou abortar a instalação: se o
# systemd estiver ocupado/sobrecarregado num pico, o sshd atual
# (com a config anterior) continua rodando normalmente — só os
# ajustes novos do sshd_config não entram em vigor até um restart
# manual (ou reboot) mais tarde. SSH_RESTART_OK fica registrado
# para avisar o usuário no resumo final.

SSH_RESTART_OK=1

step_ssh_restart(){
    if timeout 15 systemctl restart ssh 2>/dev/null; then return 0; fi
    if timeout 15 systemctl restart sshd 2>/dev/null; then return 0; fi
    if timeout 15 service ssh restart 2>/dev/null; then return 0; fi
    echo "AVISO: não foi possível reiniciar o SSH agora (systemd ocupado/travado)."
    SSH_RESTART_OK=0
    return 0
}

# ── Passo 8: finalização ────────────────────────────────────

step_finish(){
    # instalar servico checkuser (binario VPNManager customizado)
    if [[ -f "$INSTALL_DIR/bin/checkuser" ]] || [[ -f "/usr/local/bin/checkuser" ]]; then
        # copiar binario customizado
        if [[ -f "$INSTALL_DIR/bin/checkuser" ]]; then
            cp "$INSTALL_DIR/bin/checkuser" /usr/local/bin/checkuser
            chmod +x /usr/local/bin/checkuser
        fi

        cat > /etc/systemd/system/checkuser.service <<'SVC'
[Unit]
Description=CheckUser VPNManager
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/checkuser --port 2052 --db /root/pm_users.db
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable checkuser 2>/dev/null || true
        systemctl start checkuser 2>/dev/null || true
    fi
    timeout 15 systemctl daemon-reload 2>/dev/null || true
}

# ── Execução ─────────────────────────────────────────────────

echo -e "${C}Instalando VPNManager Lite...${NC}"
echo
run_step "Criando estrutura de diretórios"     step_dirs
run_step "Copiando módulos do painel"          step_copy_modules
run_step "Instalando dependências dos proxies" step_proxy_deps
run_step "Ajustando kernel/roteamento"          step_sys_tune
run_step "Liberando loopback no firewall"       step_iptables_lo
run_step "Instalando binários WS/TLS-SSL"      step_proxy_bin
run_step "Certificados SSL do sslproxy"        step_sslproxy_certs
run_step "Gerando chaves de host SSH"          step_ssh_hostkeys
run_step "Ajustando sshd_config"               step_ssh_config
run_step "Reiniciando serviço SSH"             step_ssh_restart
run_step "Finalizando"                         step_finish
run_step "Configurando stack port 80 (WebSocket/BHTTP/HCR)" step_hcr
echo
echo
echo -e "${G}[OK]${NC} Instalação concluída!"
echo
if [[ "$SSH_RESTART_OK" -eq 0 ]]; then
    echo -e "${Y}[AVISO]${NC} O SSH não foi reiniciado agora (systemd estava ocupado/travado"
    echo "  no momento da instalação). O sshd atual continua ativo com a"
    echo "  configuração anterior. Quando o sistema estiver menos ocupado, rode:"
    echo -e "    ${C}systemctl restart ssh${NC}"
    echo
    echo "  Se 'systemctl' continuar travando/demorando muito em qualquer"
    echo "  comando, o systemd pode estar sobrecarregado — verifique:"
    echo -e "    ${C}top${NC}  (uso de CPU/memória)"
    echo -e "    ${C}free -m${NC}  (memória disponível)"
    echo "  Se persistir, um reboot da VPS costuma resolver."
    echo
fi
echo -e "  Execute: ${G}menuvpn${NC}"
