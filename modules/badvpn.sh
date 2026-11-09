#!/bin/bash
#============================================================
# badvpn.sh - BadVPN UDPGW para streaming e jogos
#
# O UDPGW cria um relay UDP local que permite que clientes
# SSH encaminhem tráfego UDP (streaming, jogos, chamadas).
# O cliente HTTP Injector / NPV Tunnel / HTTP Custom conecta
# ao UDPGW via túnel SSH e envia o tráfego UDP pelo relay.
# Porta padrão: 7300 (local, só acessível via túnel SSH)
#============================================================
source "$INSTALL_DIR/modules/common.sh"

BADVPN_SERVICE="/etc/systemd/system/badvpn.service"
BADVPN_CONF="$INSTALL_DIR/conf/badvpn.conf"
BADVPN_DEFAULT_PORT=7300

# ── Helpers ──────────────────────────────────────────────────

badvpn_is_installed(){
    _badvpn_bin_path >/dev/null 2>&1
}

# Retorna o caminho real do binário badvpn-udpgw, onde quer que esteja
# (evita o bug de achar "instalado" via PATH mas o serviço apontar
# para um caminho fixo que não existe)
_badvpn_bin_path(){
    local p
    p=$(command -v badvpn-udpgw 2>/dev/null)
    if [[ -n "$p" && -x "$p" ]]; then
        echo "$p"
        return 0
    fi
    if [[ -x /usr/local/bin/badvpn-udpgw ]]; then
        echo "/usr/local/bin/badvpn-udpgw"
        return 0
    fi
    return 1
}

badvpn_is_active(){
    # verifica se pelo menos um badvpn-* está ativo
    for f in /etc/systemd/system/badvpn-*.service; do
        [[ -f "$f" ]] || continue
        local svc; svc=$(basename "$f" .service)
        systemctl is-active --quiet "$svc" 2>/dev/null && return 0
    done
    return 1
}

_badvpn_load_conf(){
    [[ -f "$BADVPN_CONF" ]] && source "$BADVPN_CONF" 2>/dev/null
}

# ── Instalação do binário ─────────────────────────────────────

_install_badvpn_bin(){
    if badvpn_is_installed; then
        ok "badvpn-udpgw já instalado em $(_badvpn_bin_path)."
        return 0
    fi

    msg "Instalando badvpn-udpgw..."

    # tenta via apt primeiro
    if apt-get install -y badvpn > /tmp/badvpn_apt.log 2>&1; then
        if command -v badvpn-udpgw &>/dev/null; then
            ok "badvpn instalado via apt."
            return 0
        fi
    fi

    # compila do fonte
    msg "Compilando badvpn do fonte..."
    apt-get install -y cmake make gcc > /dev/null 2>&1
    local tmpdir; tmpdir=$(mktemp -d)
    git clone --depth=1 https://github.com/ambrop72/badvpn.git \
        "$tmpdir/badvpn" > /tmp/badvpn_clone.log 2>&1 || {
        fail "Falha ao clonar badvpn."
        rm -rf "$tmpdir"; return 1
    }
    mkdir -p "$tmpdir/badvpn/build"
    (
        cd "$tmpdir/badvpn/build"
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
            > /tmp/badvpn_cmake.log 2>&1
        make > /tmp/badvpn_make.log 2>&1
        cp udpgw/badvpn-udpgw /usr/local/bin/
    ) || {
        fail "Falha ao compilar badvpn:"
        tail -5 /tmp/badvpn_make.log
        rm -rf "$tmpdir"; return 1
    }
    rm -rf "$tmpdir"
    chmod +x /usr/local/bin/badvpn-udpgw
    ok "badvpn-udpgw compilado e instalado."
    return 0
}

# ── Serviço systemd ───────────────────────────────────────────

_write_badvpn_service(){
    local ports_str="$1"   # "7300,7400,7500"
    local max_clients="$2"
    local bin_path
    bin_path=$(_badvpn_bin_path) || { fail "badvpn-udpgw não encontrado no sistema."; return 1; }
    IFS=',' read -ra PORTS <<< "$ports_str"

    # remove services antigos de outras portas
    for f in /etc/systemd/system/badvpn-*.service; do
        [[ -f "$f" ]] || continue
        local sn; sn=$(basename "$f" .service)
        systemctl disable "$sn" 2>/dev/null || true
        rm -f "$f"
    done

    for p in "${PORTS[@]}"; do
        p=$(echo "$p" | tr -d ' ')
        [[ -z "$p" ]] && continue
        cat > "/etc/systemd/system/badvpn-${p}.service" << SVC
[Unit]
Description=BadVPN UDPGW porta ${p}
After=network.target

[Service]
User=root
ExecStart=${bin_path} --listen-addr 127.0.0.1:${p} --max-clients ${max_clients} --max-connections-for-client 10
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
        systemctl enable "badvpn-${p}" 2>/dev/null
    done
    systemctl daemon-reload
}

# Para todos os services badvpn-*
_stop_all_badvpn(){
    for f in /etc/systemd/system/badvpn-*.service; do
        [[ -f "$f" ]] || continue
        local sn; sn=$(basename "$f" .service)
        systemctl stop "$sn" 2>/dev/null || true
        systemctl disable "$sn" 2>/dev/null || true
        rm -f "$f"
    done
    systemctl daemon-reload
}

# Inicia todos os services badvpn-*
_start_all_badvpn(){
    local ok_count=0
    for f in /etc/systemd/system/badvpn-*.service; do
        [[ -f "$f" ]] || continue
        local sn; sn=$(basename "$f" .service)
        systemctl start "$sn" 2>/dev/null && (( ok_count++ ))
    done
    return $(( ok_count > 0 ? 0 : 1 ))
}

# Reinicia todos os services badvpn-*
_restart_all_badvpn(){
    local ok_count=0 total=0
    for f in /etc/systemd/system/badvpn-*.service; do
        [[ -f "$f" ]] || continue
        (( total++ ))
        local sn; sn=$(basename "$f" .service)
        systemctl restart "$sn" 2>/dev/null && (( ok_count++ ))
    done
    [[ "$total" -gt 0 && "$ok_count" -eq "$total" ]]
}

# ── Instalação principal ──────────────────────────────────────

badvpn_install(){
    clear
    echo -e "${C_CYAN}== Configurar BadVPN UDPGW ==${C_NC}"
    echo
    echo " O BadVPN UDPGW é um relay UDP local."
    echo " Permite streaming, jogos e chamadas via túnel SSH."
    echo
    echo " Como usar no app:"
    echo -e "  ${C_GREEN}HTTP Injector / NPV Tunnel / HTTP Custom:${C_NC}"
    echo "  → Ativar UDPGW → Host: 127.0.0.1 → Porta: (escolhida abaixo)"
    echo

    echo " Informe uma ou mais portas separadas por vírgula."
    echo " Exemplo: 7300,7400,7500"
    read -p " Porta(s) UDPGW [padrão: 7300]: " popt
    local ports="${popt:-7300}"
    # valida cada porta
    local valid_ports=""
    IFS=',' read -ra PLIST <<< "$ports"
    for p in "${PLIST[@]}"; do
        p=$(echo "$p" | tr -d ' ')
        if [[ "$p" =~ ^[0-9]+$ ]]; then
            valid_ports+="${p},"
        else
            fail "Porta inválida ignorada: $p"
        fi
    done
    valid_ports="${valid_ports%,}"
    [[ -z "$valid_ports" ]] && { fail "Nenhuma porta válida informada."; pause; return; }

    local max_clients=1000
    read -p " Máximo de clientes simultâneos [padrão: 1000]: " mcopt
    [[ -n "$mcopt" && "$mcopt" =~ ^[0-9]+$ ]] && max_clients="$mcopt"

    _install_badvpn_bin || { pause; return; }
    _stop_all_badvpn
    _write_badvpn_service "$valid_ports" "$max_clients" || { pause; return; }
    sleep 1
    _start_all_badvpn
    sleep 2

    mkdir -p "$(dirname "$BADVPN_CONF")"
    cat > "$BADVPN_CONF" << CONF
BADVPN_PORTS="$valid_ports"
BADVPN_MAX_CLIENTS="$max_clients"
CONF

    if badvpn_is_active; then
        IFS=',' read -ra PLIST2 <<< "$valid_ports"
        for p in "${PLIST2[@]}"; do
            ok "BadVPN UDPGW ativo em 127.0.0.1:$p (max $max_clients clientes)"
        done
    else
        fail "BadVPN não iniciou. Verifique:"
        journalctl -u "badvpn-$(echo "$valid_ports" | cut -d, -f1)" -n 10 --no-pager 2>/dev/null
        pause; return
    fi

    echo
    echo -e "${C_CYAN}════════════════════════════════════════════════════${C_NC}"
    echo -e "${C_WHITE} CONFIGURAÇÃO NO APP${C_NC}"
    echo -e "${C_CYAN}════════════════════════════════════════════════════${C_NC}"
    echo " UDPGW Host   : 127.0.0.1"
    echo " UDPGW Portas : $valid_ports"
    echo " Max Clientes : $max_clients (por porta)"
    echo
    echo " No app: ative o UDPGW, informe 127.0.0.1 e uma das portas."
    echo -e "${C_CYAN}════════════════════════════════════════════════════${C_NC}"
    pause
}

badvpn_reconfigure(){
    clear
    echo -e "${C_CYAN}== Reconfigurar BadVPN UDPGW ==${C_NC}"
    echo
    echo " Informe uma ou mais portas separadas por vírgula."
    echo " Exemplo: 7300,7400,7500"
    read -p " Porta(s) UDPGW [padrão: 7300]: " popt
    local ports="${popt:-7300}"
    local valid_ports=""
    IFS=',' read -ra PLIST <<< "$ports"
    for p in "${PLIST[@]}"; do
        p=$(echo "$p" | tr -d ' ')
        if [[ "$p" =~ ^[0-9]+$ ]]; then
            valid_ports+="${p},"
        else
            fail "Porta inválida ignorada: $p"
        fi
    done
    valid_ports="${valid_ports%,}"
    [[ -z "$valid_ports" ]] && { fail "Nenhuma porta válida informada."; pause; return; }

    local max_clients=1000
    read -p " Máximo de clientes simultâneos [padrão: 1000]: " mcopt
    [[ -n "$mcopt" && "$mcopt" =~ ^[0-9]+$ ]] && max_clients="$mcopt"

    _stop_all_badvpn
    _write_badvpn_service "$valid_ports" "$max_clients" || { pause; return; }
    sleep 1
    _start_all_badvpn
    sleep 2

    cat > "$BADVPN_CONF" << CONF
BADVPN_PORTS="$valid_ports"
BADVPN_MAX_CLIENTS="$max_clients"
CONF

    if badvpn_is_active; then
        IFS=',' read -ra PLIST2 <<< "$valid_ports"
        for p in "${PLIST2[@]}"; do
            ok "BadVPN UDPGW ativo em 127.0.0.1:$p (max $max_clients clientes)"
        done
    else
        fail "BadVPN não iniciou. Verifique:"
        journalctl -u "badvpn-$(echo "$valid_ports" | cut -d, -f1)" -n 10 --no-pager 2>/dev/null
    fi
    pause
}

# ── Abrir/Fechar porta individual ───────────────────────────
# Diferente de badvpn_install/reconfigure (que substitui TODAS as
# portas de uma vez), estas funções adicionam ou removem uma única
# porta, preservando as demais já configuradas.

badvpn_open_port(){
    clear
    echo -e "${C_CYAN}== Abrir porta BadVPN ==${C_NC}"
    echo
    _badvpn_load_conf
    local current="${BADVPN_PORTS:-}"

    read -p " Nova porta UDPGW a abrir: " p
    p=$(echo "$p" | tr -d ' ')
    if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
        fail "Porta inválida."
        pause; return
    fi

    IFS=',' read -ra _plist <<< "$current"
    for existing in "${_plist[@]}"; do
        if [[ "$existing" == "$p" ]]; then
            fail "A porta $p já está aberta no BadVPN."
            pause; return
        fi
    done

    if ss -uln 2>/dev/null | awk '{print $5}' | grep -q ":${p}\$"; then
        fail "A porta $p já está em uso por outro serviço."
        pause; return
    fi

    local new_ports="${current:+$current,}$p"
    local max_clients="${BADVPN_MAX_CLIENTS:-1000}"

    _install_badvpn_bin || { pause; return; }
    _stop_all_badvpn
    _write_badvpn_service "$new_ports" "$max_clients" || { pause; return; }
    sleep 1
    _start_all_badvpn
    sleep 1

    mkdir -p "$(dirname "$BADVPN_CONF")"
    cat > "$BADVPN_CONF" << CONF
BADVPN_PORTS="$new_ports"
BADVPN_MAX_CLIENTS="$max_clients"
CONF

    if systemctl is-active --quiet "badvpn-${p}"; then
        ok "Porta $p aberta no BadVPN UDPGW (127.0.0.1:$p)"
    else
        fail "A porta $p não iniciou. Verifique: journalctl -u badvpn-$p -n 20"
    fi
    pause
}

badvpn_close_port(){
    clear
    echo -e "${C_CYAN}== Fechar porta BadVPN ==${C_NC}"
    echo
    _badvpn_load_conf
    local current="${BADVPN_PORTS:-}"

    if [[ -z "$current" ]]; then
        fail "Nenhuma porta BadVPN configurada."
        pause; return
    fi

    IFS=',' read -ra _plist <<< "$current"
    echo " Portas abertas:"
    local i=1
    for p in "${_plist[@]}"; do
        [[ -z "$p" ]] && continue
        if systemctl is-active --quiet "badvpn-${p}" 2>/dev/null; then
            printf "  %d) 127.0.0.1:%-6s [ATIVO]\n" "$i" "$p"
        else
            printf "  %d) 127.0.0.1:%-6s [PARADO]\n" "$i" "$p"
        fi
        (( i++ ))
    done
    echo "  0) Cancelar"
    echo
    read -p " Escolha a porta para fechar: " opt

    if [[ "$opt" == "0" || -z "$opt" ]]; then
        return
    fi
    if ! [[ "$opt" =~ ^[0-9]+$ ]] || (( opt < 1 || opt > ${#_plist[@]} )); then
        fail "Opção inválida."
        pause; return
    fi

    local target="${_plist[$((opt-1))]}"
    local new_list=""
    for p in "${_plist[@]}"; do
        [[ "$p" == "$target" ]] && continue
        new_list+="${p},"
    done
    new_list="${new_list%,}"

    local max_clients="${BADVPN_MAX_CLIENTS:-1000}"
    _stop_all_badvpn

    if [[ -n "$new_list" ]]; then
        _write_badvpn_service "$new_list" "$max_clients"
        sleep 1
        _start_all_badvpn
    fi

    cat > "$BADVPN_CONF" << CONF
BADVPN_PORTS="$new_list"
BADVPN_MAX_CLIENTS="$max_clients"
CONF

    ok "Porta $target fechada."
    pause
}

# ── Desinstalar ───────────────────────────────────────────────

badvpn_uninstall(){
    clear
    echo -e "${C_RED}== Desinstalar BadVPN ==${C_NC}"
    read -p "Confirma remoção? [s/N]: " conf
    [[ "$conf" =~ ^[sS]$ ]] || return
    _stop_all_badvpn
    rm -f "$BADVPN_CONF"
    local bin_path; bin_path=$(_badvpn_bin_path 2>/dev/null)
    apt-get remove -y badvpn > /dev/null 2>&1 || true
    [[ -n "$bin_path" && -f "$bin_path" ]] && rm -f "$bin_path"
    rm -f /usr/local/bin/badvpn-udpgw
    ok "BadVPN removido."
    pause
}

# ── Menu ──────────────────────────────────────────────────────

badvpn_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}                   BADVPN UDPGW                            ${C_CYAN}║${C_NC}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo

        _badvpn_load_conf
        if badvpn_is_installed; then
            echo -e " Binário : ${C_GREEN}$(_badvpn_bin_path 2>/dev/null || echo '?')${C_NC}"
            echo " Portas  :"
            IFS=',' read -ra _plist <<< "${BADVPN_PORTS:-$BADVPN_DEFAULT_PORT}"
            for p in "${_plist[@]}"; do
                [[ -z "$p" ]] && continue
                if systemctl is-active --quiet "badvpn-${p}" 2>/dev/null; then
                    echo -e "   127.0.0.1:${p}  ${C_GREEN}● ATIVO${C_NC}"
                else
                    echo -e "   127.0.0.1:${p}  ${C_RED}● PARADO${C_NC}"
                fi
            done
            echo -e " Clientes: ${C_GREEN}${BADVPN_MAX_CLIENTS:-1000}${C_NC} máx por porta"
            echo
            echo "  1) Reiniciar BadVPN"
            echo "  2) Abrir nova porta"
            echo "  3) Fechar porta"
            echo "  4) Reconfigurar (todas as portas/clientes)"
            echo "  5) Desinstalar"
            echo "  0) Voltar"
        else
            echo -e " ${C_YELLOW}BadVPN não configurado.${C_NC}"
            echo
            echo "  1) Instalar e configurar BadVPN"
            echo "  0) Voltar"
        fi
        echo
        read -p " Escolha: " op

        if badvpn_is_installed; then
            case $op in
                1) _restart_all_badvpn && ok "Reiniciado." || fail "Erro ao reiniciar."; sleep 2 ;;
                2) badvpn_open_port ;;
                3) badvpn_close_port ;;
                4) badvpn_reconfigure ;;
                5) badvpn_uninstall ;;
                0) break ;;
                *) fail "Opção inválida."; sleep 1 ;;
            esac
        else
            case $op in
                1) badvpn_install ;;
                0) break ;;
                *) fail "Opção inválida."; sleep 1 ;;
            esac
        fi
    done
}
