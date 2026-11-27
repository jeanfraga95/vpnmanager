#!/bin/bash
#============================================================
#  VPNManager Lite - Instalador
#============================================================
set -e
set -o pipefail

INSTALL_DIR="/etc/VPNManager"
BIN_LINK="/usr/local/bin/menuvpn"
LOG_FILE="/tmp/vpnmanager_install.log"
: > "$LOG_FILE"

# Trap de seguranca: se a instalacao falhar no meio, tenta religar
# os servicos de proxy que estavam ativos antes de comecar.
_PRESTARED_SVCS=""
_save_running_proxies(){
    local f sn
    for f in /etc/systemd/system/vpnproxy-*.service; do
        [[ -f "$f" ]] || continue
        sn=$(basename "$f" .service)
        systemctl is-active --quiet "$sn" 2>/dev/null && _PRESTARED_SVCS="$_PRESTARED_SVCS $sn"
    done
}
_cleanup_on_error(){
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo -e "${R}[AVISO]${NC} Instalacao falhou (codigo $rc). Restaurando servicos..."
        for sn in $_PRESTARED_SVCS; do
            systemctl start "$sn" 2>/dev/null || true
        done
    fi
    rm -f "${BASH_SOURCE[0]}.running" 2>/dev/null || true
}
_save_running_proxies
trap _cleanup_on_error EXIT

G="\033[1;32m"; R="\033[1;31m"; C="\033[1;36m"; Y="\033[1;33m"; NC="\033[0m"

[[ "$EUID" -ne 0 ]] && { echo -e "${R}[ERRO]${NC} Execute como root."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Barra de progresso ──────────────────────────────────────
# Uso: run_step "Descrição" comando args...
# Toda a saída do comando vai para $LOG_FILE; em caso de erro,
# mostra o final do log e aborta.

TOTAL_STEPS=15
CUR_STEP=0

# Arquivos que precisam existir junto do instalador. Sempre que o script
# e executado fora do diretorio do repo (ex.: /root), a copia falhava
# silenciosamente e o menu nao abria apos a "instalacao".
REQUIRED_MODULES=(
    common.sh ssh_users.sh xray.sh v2ray.sh online_users.sh slowdns.sh
    badvpn.sh telegram_bot.sh system_info.sh proxy.sh bhttp.sh
    port80_stack.sh enable_vpn_ports.sh limiter.sh banner.sh outras_opcoes.sh linguagem.sh
    swap.sh healthcheck.sh sshd_auth_guard.sh theme.sh ram_clean.sh
    vpnmanager-healthcheck.service vpnmanager-healthcheck.timer
)

# Units publicas do proxy unificado (copiadas para /etc/systemd/system).
UNIFIED_UNITS=(vpnproxy-unified.service vpnproxy-unified-8080.service)

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

# ── Passo 0: validar o diretorio de origem ─────────────────

step_validate_source(){
    local missing=() m arch
    [[ -f "$SCRIPT_DIR/menu.sh" ]] || missing+=("menu.sh")
    for m in "${REQUIRED_MODULES[@]}"; do
        [[ -f "$SCRIPT_DIR/modules/$m" ]] || missing+=("modules/$m")
    done
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
    esac
    [[ -d "$SCRIPT_DIR/bin/$arch" ]] || missing+=("bin/$arch")
    [[ -f "$SCRIPT_DIR/bin/$arch/vpnproxy-unified" ]] || missing+=("bin/$arch/vpnproxy-unified")
    for u in "${UNIFIED_UNITS[@]}"; do
        [[ -f "$SCRIPT_DIR/systemd/$u" ]] || missing+=("systemd/$u")
    done

    if (( ${#missing[@]} )); then
        echo
        echo -e "${R}[ERRO]${NC} Instalador incompleto em: ${SCRIPT_DIR}"
        printf '  falta: %s\n' "${missing[@]}" | head -30
        echo "  Execute install.sh de dentro do diretorio do repositorio VPNManager"
        echo "  (ex.: cd /tmp/vpnmanager_repo && bash install.sh)."
        return 1
    fi
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
    local f
    for f in menu.sh "${REQUIRED_MODULES[@]/#/modules/}"; do
        if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
            echo "ERRO: arquivo ausente no instalador: $SCRIPT_DIR/$f"
            return 1
        fi
        cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
    done
    chmod +x "$INSTALL_DIR/menu.sh"
    chmod +x "$INSTALL_DIR/modules/"*.sh
    ln -sf "$INSTALL_DIR/menu.sh" "$BIN_LINK"

    # Units do proxy unificado: o passo de portas habilita e inicia as duas.
    local u
    for u in "${UNIFIED_UNITS[@]}"; do
        cp "$SCRIPT_DIR/systemd/$u" "/etc/systemd/system/$u"
    done
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
    # Backlog de rede maior (absorve rajadas; alinhado com a sshplus).
    if [ -f "$SCRIPT_DIR/sysctl-99-udp-buffers.conf" ]; then
        cp "$SCRIPT_DIR/sysctl-99-udp-buffers.conf" /etc/sysctl.d/99-udp-buffers.conf
        sysctl -w net.core.netdev_max_backlog=100000 >/dev/null 2>&1 || true
    fi
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
    for name in proxy sslproxy xhttpssh checkuser bhttpssh_dtp xhttp2 hcr-server hcr-dispatcher vpnproxy-unified; do
        if [[ -f "$src/$name" ]]; then
            cp "$src/$name" "$INSTALL_DIR/bin/${name}.new"
            chmod +x "$INSTALL_DIR/bin/${name}.new"
            mv -f "$INSTALL_DIR/bin/${name}.new" "$INSTALL_DIR/bin/${name}"
        fi
    done

    for sn in "${was_active[@]}"; do
        systemctl start "$sn" 2>/dev/null || true
    done

    if [[ ! -x "$INSTALL_DIR/bin/vpnproxy-unified" ]]; then
        echo "ERRO: binario vpnproxy-unified ausente em $src (necessario pelo BHTTP)."
        return 1
    fi
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
    # 1) aceita tudo vindo do loopback (backend dos proxies) e garante que
    #    a regra seja a PRIMEIRA, antes de limites de hitcount/connlimit
    #    (ex.: regra de 10 conexoes/min na 22 que tambem batia no loopback).
    iptables -D INPUT -i lo -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -i lo -j ACCEPT

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
        sed -i '/^-A INPUT -i lo -j ACCEPT$/d' /etc/iptables/rules.v4
        sed -i '/^:OUTPUT ACCEPT/a -A INPUT -i lo -j ACCEPT' /etc/iptables/rules.v4
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
    # health-check: reinicia automaticamente servicos que morrerem.
    # As units vem do repo via REQUIRED_MODULES (antes nao eram copiadas).
    if [[ -f "$INSTALL_DIR/modules/vpnmanager-healthcheck.service" ]]; then
        cp "$INSTALL_DIR/modules/vpnmanager-healthcheck.service" /etc/systemd/system/ 2>/dev/null || true
        cp "$INSTALL_DIR/modules/vpnmanager-healthcheck.timer" /etc/systemd/system/ 2>/dev/null || true
    fi
    chmod +x "$INSTALL_DIR/modules/healthcheck.sh" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/modules/sshd_auth_guard.sh" 2>/dev/null || true
    bash "$INSTALL_DIR/modules/sshd_auth_guard.sh" >/dev/null 2>&1 || true
    timeout 15 systemctl daemon-reload 2>/dev/null || true
    systemctl enable vpnmanager-healthcheck.timer >/dev/null 2>&1 || true
    systemctl start vpnmanager-healthcheck.timer >/dev/null 2>&1 || true
}

# ── Passo 12: backends internos (BHTTP + WebSocket + HCR + XHTTP) ──
# O listener publico nao e mais criado pelo stack legado: ele sempre usa
# o binario unificado (vpnproxy-unified), habilitado no passo seguinte.
# Aqui criamos somente sshd-bhttp(2223), HCR(18082) e XHTTP(11443).
step_port80_stack(){
    if [[ -f "$INSTALL_DIR/modules/port80_stack.sh" ]]; then
        VPNMANAGER_SKIP_PUBLIC=1 bash "$INSTALL_DIR/modules/port80_stack.sh" >/dev/null 2>&1 || true
    fi
    # Remove apenas servicos avulsos antigos do proprios VPNManager.
    for sn in vpnproxy-bhttp-80 vpnproxy-ws-8080 vpnproxy-hcr-tcp \
              vpnproxy-hcr-quic vpnproxy-bhttp-18083 vpnproxy-port80 \
              hcr-dispatcher nginx; do
        systemctl stop "$sn" >/dev/null 2>&1 || true
        systemctl disable "$sn" >/dev/null 2>&1 || true
    done
    return 0
}

# ── Passo 13: portas publicas + proxy unificado + Xray ────────
# Idempotente: habilita 80 (BHTTP/proxy/HCR/XHTTP), 8080 (proxy) e
# 443 (Xray) somente quando ainda nao estao habilitadas. Nunca mexe
# em servico de terceiros que ja ocupe essas portas.
step_vpn_ports(){
    [[ -f "$INSTALL_DIR/modules/enable_vpn_ports.sh" ]] || {
        echo "ERRO: modulo enable_vpn_ports.sh ausente."
        return 1
    }
    timeout 15 systemctl daemon-reload >/dev/null 2>&1 || true
    bash "$INSTALL_DIR/modules/enable_vpn_ports.sh"
}

# ── Passo 14: verificacao final da instalacao ───────────────
step_verify_install(){
    local f
    [[ -x "$INSTALL_DIR/menu.sh" ]] || {
        echo "ERRO: $INSTALL_DIR/menu.sh nao foi instalado."; return 1;
    }
    bash -n "$INSTALL_DIR/menu.sh" || {
        echo "ERRO: sintaxe invalida em $INSTALL_DIR/menu.sh"; return 1;
    }
    for f in menu.sh "${REQUIRED_MODULES[@]/#/modules/}"; do
        [[ -f "$INSTALL_DIR/$f" ]] || {
            echo "ERRO: arquivo instalado ausente: $INSTALL_DIR/$f"; return 1;
        }
    done
    [[ "$(readlink -f "$BIN_LINK" 2>/dev/null)" == "$INSTALL_DIR/menu.sh" ]] || \
        ln -sf "$INSTALL_DIR/menu.sh" "$BIN_LINK"
    [[ -x "$INSTALL_DIR/bin/vpnproxy-unified" ]] || {
        echo "ERRO: $INSTALL_DIR/bin/vpnproxy-unified ausente."; return 1;
    }
    local u
    for u in "${UNIFIED_UNITS[@]}"; do
        [[ -f "/etc/systemd/system/$u" ]] || {
            echo "ERRO: unit /etc/systemd/system/$u ausente."; return 1;
        }
    done
}

# ── Execução ─────────────────────────────────────────────────

echo -e "${C}Instalando VPNManager Lite...${NC}"
echo
run_step "Validando origem do instalador"      step_validate_source
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
run_step "Configurando backends internos (BHTTP/HCR/XHTTP)" step_port80_stack
run_step "Habilitando portas 80/8080/443 (proxy e Xray)" step_vpn_ports
run_step "Verificando instalacao"              step_verify_install
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
PRIMARY_PORT=8080
systemctl is-active --quiet vpnproxy-unified 2>/dev/null && PRIMARY_PORT=80
echo -e "  ${C}Porta ${PRIMARY_PORT}:${NC} BHTTP + WebSocket + HCR + XHTTP (proxy unificado)"
echo -e "  ${C}Porta 8080:${NC}    proxy unificado (mesmos protocolos da 80)"
if systemctl is-active --quiet xray 2>/dev/null && \
   grep -q '^XRAY_PORT=443' "$INSTALL_DIR/conf/vpnmanager.conf" 2>/dev/null; then
    echo -e "  ${C}Porta 443:${NC}     Xray VLESS (xhttp/tls) configurado"
else
    echo -e "  ${Y}Porta 443:${NC}     liberada no firewall (dono existente preservado)"
fi
[[ "$PRIMARY_PORT" == 8080 ]] && \
    echo -e "  ${Y}Porta 80:${NC}     reservada para outro sistema (nao foi alterada)"
echo -e "  ${C}Interno:${NC}  sshd-bhttp 2223, HCR 18082, XHTTP 11443"
echo
echo -e "  Execute: ${G}menuvpn${NC}"
