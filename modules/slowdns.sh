#!/bin/bash
#============================================================
# slowdns.sh - SlowDNS (dnstt) para tunelamento via DNS
#
# Fluxo: App (porta 53 UDP) → dnstt-server (5300) → sshd/VPN
# O script redireciona UDP 53 → 5300 via iptables/nftables.
# O usuário informa o domínio NS (ex: ns.exemplo.com) e o
# script gera o par de chaves e mostra a chave pública para
# configurar no app.
#============================================================
source "$INSTALL_DIR/modules/common.sh"

SDNS_DIR="/etc/slowdns"
SDNS_BIN_URL="https://github.com/n0nag0n/dnstt/releases/latest/download"
SDNS_SERVICE="/etc/systemd/system/slowdns.service"
SDNS_CONF="$SDNS_DIR/slowdns.conf"

# ── Helpers ──────────────────────────────────────────────────

slowdns_is_installed(){
    [[ -f /usr/local/bin/dnstt-server ]] && \
    [[ -f /etc/systemd/system/slowdns.service ]]
}

slowdns_is_active(){
    systemctl is-active --quiet slowdns 2>/dev/null
}

_sdns_load_conf(){
    [[ -f "$SDNS_CONF" ]] && source "$SDNS_CONF" 2>/dev/null
}

# ── Instalação do binário dnstt ───────────────────────────────

_install_dnstt(){
    if [[ -f /usr/local/bin/dnstt-server ]]; then
        ok "dnstt-server já instalado."
        return 0
    fi

    msg "Instalando dnstt-server..."

    # Tenta via apt (Ubuntu/Debian)
    apt-get update -qq 2>/dev/null
    if apt-get install -y dnstt > /tmp/dnstt_apt.log 2>&1; then
        # o apt pode instalar em path diferente
        local bin_path
        bin_path=$(command -v dnstt-server 2>/dev/null             || find /usr -name "dnstt-server" 2>/dev/null | head -1)
        if [[ -n "$bin_path" ]]; then
            [[ "$bin_path" != "/usr/local/bin/dnstt-server" ]] &&                 ln -sf "$bin_path" /usr/local/bin/dnstt-server
            ok "dnstt-server instalado via apt."
            return 0
        fi
    fi


    # Compila dnstt-server a partir do tarball do repositório oficial
    # Fonte: https://github.com/dnstt-xyz/dnstt_xyz_app (go_src/dnstt-server)

    # ── Garante Go >= 1.21 (apt instala versão antiga no Ubuntu) ──────
    local GO_BIN="/usr/local/go/bin/go"
    local go_ok=0

    # verifica se já tem versão adequada
    if command -v go &>/dev/null; then
        local cur_minor; cur_minor=$(go version 2>/dev/null | grep -oP 'go1\.\K[0-9]+')
        [[ "${cur_minor:-0}" -ge 21 ]] && go_ok=1 && GO_BIN=$(command -v go)
    fi
    if [[ -f /usr/local/go/bin/go ]]; then
        local cur_minor; cur_minor=$(/usr/local/go/bin/go version 2>/dev/null | grep -oP 'go1\.\K[0-9]+')
        [[ "${cur_minor:-0}" -ge 21 ]] && go_ok=1 && GO_BIN="/usr/local/go/bin/go"
    fi

    if [[ $go_ok -eq 0 ]]; then
        msg "Instalando Go atualizado (1.21+) via tarball oficial..."
        local go_latest="1.22.4"
        local go_arch
        case "$(uname -m)" in
            x86_64)  go_arch="amd64" ;;
            aarch64) go_arch="arm64" ;;
            armv7l)  go_arch="armv6l" ;;
            *)       go_arch="amd64" ;;
        esac
        local go_url="https://go.dev/dl/go${go_latest}.linux-${go_arch}.tar.gz"
        msg "Baixando Go ${go_latest} (${go_arch})..."
        rm -rf /usr/local/go
        curl -fsSL --max-time 120 "$go_url" -o /tmp/go_install.tar.gz 2>/tmp/go_dl.log || {
            fail "Falha ao baixar Go. Verifique a conexão."
            cat /tmp/go_dl.log
            return 1
        }
        tar -C /usr/local -xzf /tmp/go_install.tar.gz 2>/dev/null || {
            fail "Falha ao extrair Go."
            return 1
        }
        rm -f /tmp/go_install.tar.gz
        GO_BIN="/usr/local/go/bin/go"
        ok "Go instalado: $($GO_BIN version 2>/dev/null | awk '{print $3}')"
    else
        ok "Go adequado: $($GO_BIN version 2>/dev/null | awk '{print $3}')"
    fi

    export PATH=$PATH:/usr/local/go/bin

    local tmpdir; tmpdir=$(mktemp -d)
    local tarball="$tmpdir/dnstt.tar.gz"

    msg "Baixando código fonte do dnstt-server..."
    if ! curl -fsSL --max-time 60         "https://github.com/dnstt-xyz/dnstt_xyz_app/archive/refs/heads/main.tar.gz"         -o "$tarball" 2>/tmp/dnstt_dl.log; then
        fail "Falha ao baixar o tarball."
        cat /tmp/dnstt_dl.log
        rm -rf "$tmpdir"; return 1
    fi

    msg "Extraindo código fonte..."
    tar -xzf "$tarball" -C "$tmpdir"         --strip-components=1         "dnstt_xyz_app-main/go_src" 2>/tmp/dnstt_extract.log || {
        fail "Falha ao extrair. Detalhes:"
        cat /tmp/dnstt_extract.log
        rm -rf "$tmpdir"; return 1
    }

    local go_src="$tmpdir/go_src"
    [[ -d "$go_src/dnstt-server" ]] || {
        fail "Diretório dnstt-server não encontrado no tarball."
        rm -rf "$tmpdir"; return 1
    }

    msg "Compilando dnstt-server (pode levar 1-2 minutos)..."
    (
        cd "$go_src"
        GOPATH=/tmp/dnstt_gopath         "$GO_BIN" build -o /usr/local/bin/dnstt-server ./dnstt-server/
    ) > /tmp/dnstt_build.log 2>&1

    rm -rf "$tmpdir" /tmp/dnstt_gopath

    rm -rf "$tmpdir"

    if [[ -f /usr/local/bin/dnstt-server ]]; then
        chmod +x /usr/local/bin/dnstt-server
        ok "dnstt-server compilado e instalado com sucesso."
        return 0
    fi

    fail "Falha ao compilar dnstt-server. Detalhes:"
    tail -15 /tmp/dnstt_build.log
    return 1
}

# ── Geração de chaves ─────────────────────────────────────────

_generate_keys(){
    mkdir -p "$SDNS_DIR"
    if [[ -f "$SDNS_DIR/server.key" && -f "$SDNS_DIR/server.pub" ]]; then
        ok "Chaves existentes reaproveitadas."
        return 0
    fi
    msg "Gerando par de chaves dnstt..."
    dnstt-server -gen-key \
        -privkey-file "$SDNS_DIR/server.key" \
        -pubkey-file  "$SDNS_DIR/server.pub" \
        > /tmp/dnstt_keygen.log 2>&1 || {
        fail "Falha ao gerar chaves:"
        cat /tmp/dnstt_keygen.log
        return 1
    }
    chmod 600 "$SDNS_DIR/server.key"
    chmod 644 "$SDNS_DIR/server.pub"
    ok "Chaves geradas em $SDNS_DIR/"
}

# ── Redirecionamento de porta via iptables ────────────────────
# UDP 53 → 5300 (dnstt escuta na 5300, clientes enviam para 53)

_setup_iptables(){
    local internal_port="$1"

    # adiciona regra se não existir
    if ! iptables -t nat -C PREROUTING -p udp --dport 53 \
            -j REDIRECT --to-port "$internal_port" 2>/dev/null; then
        iptables -t nat -A PREROUTING -p udp --dport 53 \
            -j REDIRECT --to-port "$internal_port"
        ok "iptables: UDP 53 → $internal_port"
    else
        ok "Regra iptables já existe."
    fi

    # persiste com iptables-persistent se disponível
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
        iptables-save > /etc/iptables.rules 2>/dev/null || true
    fi
}

_remove_iptables(){
    local internal_port="${1:-5300}"
    iptables -t nat -D PREROUTING -p udp --dport 53 \
        -j REDIRECT --to-port "$internal_port" 2>/dev/null || true
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    fi
}

# ── Serviço systemd ───────────────────────────────────────────

_write_slowdns_service(){
    local ns_domain="$1" internal_port="$2" upstream_addr="$3"
    cat > "$SDNS_SERVICE" << SVC
[Unit]
Description=SlowDNS (dnstt) Server
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/dnstt-server \\
    -udp :${internal_port} \\
    -privkey-file ${SDNS_DIR}/server.key \\
    ${ns_domain} ${upstream_addr}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
}

# ── Instalação principal ──────────────────────────────────────

slowdns_install(){
    clear
    echo -e "${C_CYAN}== Configurar SlowDNS (dnstt) ==${C_NC}"
    echo
    echo " O SlowDNS tunela tráfego via DNS UDP."
    echo " Fluxo: App (UDP 53) → iptables → dnstt (5300) → SSH/VPN"
    echo
    echo " Pré-requisito: você precisa ter um domínio com registro NS"
    echo " apontando para o IP desta VPS. Exemplo:"
    echo -e "   ${C_GREEN}ns1.seudominio.com${C_NC} → A record → IP desta VPS"
    echo -e "   ${C_GREEN}tunnel.seudominio.com${C_NC} → NS → ns1.seudominio.com"
    echo
    read -p " Domínio NS para o túnel (ex: tunnel.seudominio.com): " ns_domain
    [[ -z "$ns_domain" ]] && { fail "Domínio não pode ser vazio."; pause; return; }

    # porta interna fixa em 5300 (UDP 53 → 5300)
    local internal_port=5300

    # destino final fixo: SSH local (porta 22 ou configurada no sshd)
    local sshd_port
    sshd_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    sshd_port="${sshd_port:-22}"
    local upstream_addr="127.0.0.1:${sshd_port}"

    _install_dnstt || { pause; return; }
    _generate_keys || { pause; return; }
    _write_slowdns_service "$ns_domain" "$internal_port" "$upstream_addr"
    _setup_iptables "$internal_port"

    systemctl enable slowdns 2>/dev/null
    systemctl restart slowdns
    sleep 2

    # salva configuração
    mkdir -p "$SDNS_DIR"
    cat > "$SDNS_CONF" << CONF
SDNS_NS_DOMAIN="$ns_domain"
SDNS_INT_PORT="$internal_port"
SDNS_UPSTREAM="$upstream_addr"
CONF

    if systemctl is-active --quiet slowdns; then
        ok "SlowDNS ativo na porta $internal_port (UDP 53 → $internal_port)."
    else
        fail "SlowDNS não iniciou."
        journalctl -u slowdns -n 20 --no-pager 2>/dev/null
        pause; return
    fi

    ufw allow 53/udp >/dev/null 2>&1

    echo
    echo -e "${C_CYAN}════════════════════════════════════════════════════${C_NC}"
    echo -e "${C_WHITE} CONFIGURAÇÃO DO APP (SlowDNS / HTTP Custom)${C_NC}"
    echo -e "${C_CYAN}════════════════════════════════════════════════════${C_NC}"
    echo " Domínio NS  : $ns_domain"
    echo " Porta DNS   : 53 (UDP)"
    echo -e " Chave pública (Public Key):"
    echo
    if [[ -f "$SDNS_DIR/server.pub" ]]; then
        echo -e "  ${C_GREEN}$(cat "$SDNS_DIR/server.pub")${C_NC}"
    else
        echo -e "  ${C_YELLOW}(arquivo não encontrado: $SDNS_DIR/server.pub)${C_NC}"
    fi
    echo
    echo " Cole a chave pública no campo 'Server Public Key' do app."
    echo -e "${C_CYAN}════════════════════════════════════════════════════${C_NC}"
    pause
}

# ── Ver chave pública ─────────────────────────────────────────

slowdns_show_key(){
    clear
    echo -e "${C_CYAN}== Chave Pública SlowDNS ==${C_NC}"
    echo
    _sdns_load_conf
    echo " Domínio NS : ${SDNS_NS_DOMAIN:-(não configurado)}"
    echo " Porta      : ${SDNS_INT_PORT:-5300}"
    echo
    if [[ -f "$SDNS_DIR/server.pub" ]]; then
        echo -e " ${C_WHITE}Chave pública (cole no app):${C_NC}"
        echo
        echo -e "  ${C_GREEN}$(cat "$SDNS_DIR/server.pub")${C_NC}"
    else
        echo -e " ${C_YELLOW}Chave não encontrada. Configure o SlowDNS primeiro.${C_NC}"
    fi
    echo
    pause
}

# ── Desinstalar ───────────────────────────────────────────────

slowdns_uninstall(){
    clear
    echo -e "${C_RED}== Desinstalar SlowDNS ==${C_NC}"
    read -p "Confirma remoção completa? [s/N]: " conf
    [[ "$conf" =~ ^[sS]$ ]] || return
    _sdns_load_conf
    systemctl disable --now slowdns 2>/dev/null
    rm -f "$SDNS_SERVICE"
    rm -f /usr/local/bin/dnstt-server
    rm -rf "$SDNS_DIR"
    _remove_iptables "${SDNS_INT_PORT:-5300}"
    systemctl daemon-reload
    ok "SlowDNS removido."
    pause
}

# ── Menu ──────────────────────────────────────────────────────

slowdns_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}                       SLOWDNS (dnstt)                     ${C_CYAN}║${C_NC}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo

        _sdns_load_conf
        if slowdns_is_installed; then
            local badge
            slowdns_is_active \
                && badge="${C_GREEN}● ATIVO${C_NC}" \
                || badge="${C_RED}● PARADO${C_NC}"
            echo -e " Status  : $badge"
            echo -e " Domínio : ${C_GREEN}${SDNS_NS_DOMAIN:-(não configurado)}${C_NC}"
            echo -e " Porta   : ${C_GREEN}${SDNS_INT_PORT:-5300}${C_NC} (UDP 53 → ${SDNS_INT_PORT:-5300})"
            echo -e " Destino : ${C_GREEN}${SDNS_UPSTREAM:-127.0.0.1:22}${C_NC}"
            echo
            echo "  1) Ver chave pública (Public Key)"
            echo "  2) Reiniciar SlowDNS"
            echo "  3) Reconfigurar"
            echo "  4) Desinstalar"
            echo "  0) Voltar"
        else
            echo -e " ${C_YELLOW}SlowDNS não configurado.${C_NC}"
            echo
            echo "  1) Configurar SlowDNS"
            echo "  0) Voltar"
        fi
        echo
        read -p " Escolha: " op

        if slowdns_is_installed; then
            case $op in
                1) slowdns_show_key ;;
                2) systemctl restart slowdns && ok "Reiniciado." || fail "Erro."; sleep 2 ;;
                3) slowdns_uninstall; slowdns_install ;;
                4) slowdns_uninstall ;;
                0) break ;;
                *) fail "Opção inválida."; sleep 1 ;;
            esac
        else
            case $op in
                1) slowdns_install ;;
                0) break ;;
                *) fail "Opção inválida."; sleep 1 ;;
            esac
        fi
    done
}
