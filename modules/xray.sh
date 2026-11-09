#!/bin/bash
#============================================================
# xray.sh - instalação, gerenciamento e credenciais do Xray
# Config gerada é compatível byte-a-byte com o config.json de
# referência confirmado funcional pelo usuário (path fixo "/",
# xhttpSettings completo, certificado autoassinado opcional).
#============================================================
source "$INSTALL_DIR/modules/common.sh"

XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_SSL_DIR="$XRAY_DIR/ssl"

gen_uuid(){ cat /proc/sys/kernel/random/uuid; }

xray_is_installed(){
    command -v xray &>/dev/null && [[ -f /etc/systemd/system/xray.service ]]
}

#------------------------------------------------------------
# Remoção completa (binário, config, certs, serviço)
#------------------------------------------------------------
xray_full_uninstall(){
    systemctl disable --now xray 2>/dev/null
    bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove --purge >/dev/null 2>&1
    rm -rf "$XRAY_DIR"
    rm -f /etc/systemd/system/xray.service
    rm -f "$CRED_FILE"
    systemctl daemon-reload
}

#------------------------------------------------------------
# Instala o binário do Xray-core, garantindo que o service file
# do systemd existe mesmo se o instalador achar "já atualizado"
#------------------------------------------------------------
install_xray_core(){
    rm -f /tmp/xray_install.log

    if ! command -v curl &>/dev/null; then
        fail "curl não encontrado. Instale com: apt-get install -y curl"
        return 1
    fi
    if ! command -v jq &>/dev/null; then
        fail "jq não encontrado. Instale com: apt-get install -y jq"
        return 1
    fi

    if command -v xray &>/dev/null; then
        # Binário já existe (cenário: service file foi removido por algum
        # motivo, ou estamos reinstalando por cima). --reinstall exige que
        # o Xray já esteja instalado — sem isso ele recusa com
        # "error: Xray is not installed" e sai, então só usamos a flag
        # quando sabemos que há uma instalação prévia de fato.
        msg "Xray-core já instalado, recriando serviço/atualizando..."
        bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install --reinstall >/tmp/xray_install.log 2>&1
    else
        # Instalação do zero — sem --reinstall, que falharia justamente
        # por não haver nada instalado ainda para "reinstalar".
        msg "Instalando Xray-core (script oficial XTLS)..."
        bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install >/tmp/xray_install.log 2>&1
    fi
    systemctl daemon-reload

    if ! command -v xray &>/dev/null; then
        fail "Falha ao instalar o binário do Xray-core. Detalhes:"
        tail -n 15 /tmp/xray_install.log
        return 1
    fi
    if [[ ! -f /etc/systemd/system/xray.service ]]; then
        fail "O serviço systemd do Xray não foi criado. Detalhes:"
        tail -n 15 /tmp/xray_install.log
        return 1
    fi

    # O instalador oficial usa "User=nobody", o que o systemd moderno
    # reporta como aviso de segurança (não impede o serviço de rodar,
    # mas trocamos por root por consistência com o resto do painel).
    if grep -q "^User=nobody" /etc/systemd/system/xray.service 2>/dev/null; then
        sed -i "s|^User=nobody|User=root|" /etc/systemd/system/xray.service
        systemctl daemon-reload
    fi
    return 0
}

#------------------------------------------------------------
# Gera certificado autoassinado (não exige domínio nem porta 80
# liberada — funciona só com IP, como pedido)
#------------------------------------------------------------
generate_selfsigned_cert(){
    local ip="$1"
    mkdir -p "$XRAY_SSL_DIR"
    if [[ -s "$XRAY_SSL_DIR/cert.pem" && -s "$XRAY_SSL_DIR/priv.key" ]]; then
        ok "Certificado autoassinado já existe. Reaproveitando."
        return 0
    fi
    msg "Gerando certificado autoassinado (válido por 10 anos)..."
    if ! openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$XRAY_SSL_DIR/priv.key" \
        -out "$XRAY_SSL_DIR/cert.pem" \
        -days 3650 \
        -subj "/CN=$ip" \
        -addext "subjectAltName=IP:$ip" >/tmp/cert_gen.log 2>&1; then
        fail "Falha ao gerar certificado. Detalhes:"
        cat /tmp/cert_gen.log
        return 1
    fi
    return 0
}

#------------------------------------------------------------
# Escreve o config.json via jq — 100% seguro contra problemas
# de escaping. Suporta xhttp, httpupgrade, h2, grpc.
# path fixo "/" em todos os transportes.
#------------------------------------------------------------
write_xray_config(){
    local port="$1" mode="$2" uuid="$3" ssh_fallback_port="$4" transport="${5:-xhttp}"
    mkdir -p "$XRAY_DIR"

    # ── streamSettings via jq ─────────────────────────────────
    local stream_json
    stream_json=$(jq -n         --arg net  "$transport"         --arg mode "$mode"         --arg cert "$XRAY_SSL_DIR/cert.pem"         --arg key  "$XRAY_SSL_DIR/priv.key"         '{ network: $net } |
         # settings de transporte por tipo
         # H2 foi removido no Xray 26.x — use XHTTP com mode=stream
         if   $net == "xhttp" then . + { xhttpSettings: {
               path: "/", host: "", mode: "auto", noSSEHeader: false,
               scMaxBufferedPosts: 30,
               scMaxEachPostBytes: "1000000",
               scStreamUpServerSecs: "20-80",
               xPaddingBytes: "100-1000", headers: {} } }
         elif $net == "httpupgrade" then . + { httpupgradeSettings: { path: "/", host: "" } }
         elif $net == "grpc"        then . + { grpcSettings:        { serviceName: "/", multiMode: false } }
         else . end |
         # TLS
         if $mode == "tls" then
             . + { security: "tls",
                   tlsSettings: {
                       certificates: [{ certificateFile: $cert, keyFile: $key }],
                       alpn: ["h2","http/1.1"] } }
         else . + { security: "none" } end')

    # ── fallbacks (apenas xhttp e httpupgrade) ─────────────────
    local fallbacks_json="[]"
    if [[ -n "$ssh_fallback_port" ]] &&        [[ "$transport" == "xhttp" || "$transport" == "httpupgrade" ]]; then
        fallbacks_json=$(jq -n --argjson dest "$ssh_fallback_port" '[{dest: $dest}]')
    fi

    # ── inbound VLESS ──────────────────────────────────────────
    local inbound_json
    inbound_json=$(jq -n         --argjson port      "$port"         --arg     uuid      "$uuid"         --argjson stream    "$stream_json"         --argjson fallbacks "$fallbacks_json"         '{ port: $port, protocol: "vless",
           settings: {
               clients: [{ id: $uuid, email: "cliente1", level: 0 }],
               decryption: "none",
               fallbacks: $fallbacks
           },
           sniffing: {
               enabled: true,
               destOverride: ["http","tls","quic","fakedns"],
               metadataOnly: false,
               routeOnly: false
           },
           streamSettings: $stream,
           tag: "inbound-xray" }')

    # ── config final ───────────────────────────────────────────
    local final_config
    final_config=$(jq -n         --argjson inbound "$inbound_json"         '{ log: { loglevel: "warning" },
           inbounds: [$inbound],
           outbounds: [
               { protocol: "freedom",   settings: {}, tag: "direct"  },
               { protocol: "blackhole", settings: {}, tag: "blocked" }
           ],
           routing: {
               domainStrategy: "AsIs",
               rules: [
                   { type: "field", ip: ["geoip:private"],      outboundTag: "blocked" },
                   { type: "field", protocol: ["bittorrent"],   outboundTag: "blocked" }
               ]
           } }')

    # valida antes de gravar
    echo "$final_config" | jq empty 2>/dev/null || {
        fail "JSON gerado é inválido — bug interno."; return 1
    }
    echo "$final_config" > "$XRAY_CONFIG"
}

#------------------------------------------------------------
# Sobe o Xray e checa se realmente ficou ativo (logs filtrados
# por horário, para não misturar erro de tentativa antiga)
#------------------------------------------------------------
xray_restart_and_check(){
    local port="$1"
    local restart_time; restart_time=$(date '+%Y-%m-%d %H:%M:%S')
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 2
    if ! systemctl is-active --quiet xray; then
        fail "O Xray não conseguiu iniciar. Detalhes (apenas desta tentativa):"
        journalctl -u xray --since "$restart_time" --no-pager 2>/dev/null
        return 1
    fi

    # Confirma se algo já ocupava a porta antes de declarar sucesso
    sleep 1
    if ! ss -tln 2>/dev/null | grep -q ":$port "; then
        fail "O Xray está ativo, mas não encontrei nada escutando na porta $port."
        journalctl -u xray --since "$restart_time" --no-pager 2>/dev/null
        return 1
    fi
    return 0
}

#------------------------------------------------------------
# Instalação principal — escolha de transporte + modo + porta
#------------------------------------------------------------
xray_install(){
    clear
    echo -e "${C_CYAN}== Instalar Xray (VLESS) ==${C_NC}"
    echo
    echo "Escolha o transporte:"
    echo "  1) XHTTP        (recomendado — path /)"
    echo "  2) HTTPUpgrade  (CDN compatível — path /)"
    echo "  3) gRPC         (serviceName /)"
    echo ""
    echo -e "  ${C_YELLOW}H2 foi removido do Xray 26.x (migrado para XHTTP).${C_NC}"
    echo -e "  ${C_YELLOW}HTTPUpgrade pode desconectar em idle — use XHTTP se tiver problemas.${C_NC}"
    read -p "Transporte [1-3]: " topt
    local transport
    case $topt in
        1) transport="xhttp" ;;
        2) transport="httpupgrade" ;;
        3) transport="grpc" ;;
        *) fail "Opção inválida."; pause; return ;;
    esac

    echo
    echo "Segurança:"
    echo "  1) Sem TLS  (Direct)"
    echo "  2) TLS (certificado autoassinado)"
    read -p "Modo [1-2]: " modeopt
    local mode
    case $modeopt in
        1) mode="none" ;;
        2) mode="tls" ;;
        *) fail "Opção inválida."; pause; return ;;
    esac

    read -p "Porta (ex: 443): " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && { fail "Porta inválida."; pause; return; }

    msg "Detectando IP público..."
    local detected_ip; detected_ip=$(get_ip)
    read -p "IP/domínio [${detected_ip:-desconhecido}] (Enter = usar detectado): " hostaddr
    hostaddr=${hostaddr:-$detected_ip}
    [[ -z "$hostaddr" ]] && { fail "IP não detectado e não informado."; pause; return; }

    echo
    # fallback SSH — apenas em transportes que suportam (xhttp e httpupgrade)
    local ssh_fallback_port=""
    if [[ "$transport" == "xhttp" || "$transport" == "httpupgrade" ]]; then
        echo -e "${C_YELLOW}Compartilhar esta porta com SSH? (fallback VLESS)${C_NC}"
        echo " Conexões SSH normais nessa porta são encaminhadas ao sshd."
        read -p "Ativar? [s/N]: " ssh_fallback
        if [[ "$ssh_fallback" =~ ^[sS]$ ]]; then
            local sshd_port
            sshd_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
            ssh_fallback_port="${sshd_port:-22}"
            msg "Fallback → sshd porta $ssh_fallback_port"
        fi
    else
        echo -e "${C_YELLOW}Nota: fallback SSH não disponível para $transport.${C_NC}"
    fi

    # verifica conflito de porta
    local port_pid port_service
    port_pid=$(ss -tlnp 2>/dev/null | awk -v p=":$port " '$4==p{print $NF}'         | grep -oP 'pid=\K[0-9]+' | head -1)
    if [[ -n "$port_pid" ]]; then
        port_service=$(ps -p "$port_pid" -o comm= 2>/dev/null)
        if [[ "$port_service" == "xray" ]]; then
            systemctl stop xray 2>/dev/null; sleep 1
        else
            fail "Porta $port em uso por '$port_service'. Pare ou escolha outra."
            pause; return
        fi
    fi

    install_xray_core || { pause; return; }

    if [[ "$mode" == "tls" ]]; then
        generate_selfsigned_cert "$hostaddr" || { pause; return; }
    fi

    local uuid; uuid=$(gen_uuid)
    write_xray_config "$port" "$mode" "$uuid" "$ssh_fallback_port" "$transport"

    if ! xray_restart_and_check "$port"; then
        pause; return
    fi

    ufw allow "$port"/tcp >/dev/null 2>&1

    conf_set "XRAY_PORT"      "$port"
    conf_set "XRAY_HOST"      "$hostaddr"
    conf_set "XRAY_MODE"      "$mode"
    conf_set "XRAY_TRANSPORT" "$transport"

    xray_save_credentials "$port" "$mode" "$hostaddr" "$uuid" "$transport"

    ok "Xray instalado com sucesso!"
    echo
    cat "$CRED_FILE"
    pause
}

#------------------------------------------------------------
# Credenciais — gera link vless:// por transporte
#------------------------------------------------------------
xray_save_credentials(){
    local port="$1" mode="$2" hostaddr="$3" uuid="$4" transport="${5:-xhttp}"
    local sec_param="none"; [[ "$mode" == "tls" ]] && sec_param="tls"

    # parâmetros do link vless:// por transporte
    local type_param path_param extra_params
    case "$transport" in
        xhttp)
            type_param="xhttp"
            path_param="%2F"
            extra_params="&mode=auto"
            ;;
        httpupgrade)
            type_param="httpupgrade"
            path_param="%2F"
            extra_params=""
            ;;
        grpc)
            type_param="grpc"
            path_param="%2F"
            extra_params="&serviceName=%2F&mode=gun"
            ;;
        *)
            type_param="xhttp"
            path_param="%2F"
            extra_params="&mode=auto"
            ;;
    esac

    local vless_link="vless://${uuid}@${hostaddr}:${port}?security=${sec_param}&encryption=none&type=${type_param}&path=${path_param}&host=${hostaddr}${extra_params}#VPNManager-Xray"

    cat > "$CRED_FILE" <<CRED
============================================
 XRAY (VLESS) - Credenciais de Conexão
============================================
Transporte:       $transport
Modo:             $([[ "$mode" == "tls" ]] && echo "TLS (certificado autoassinado)" || echo "Direct (sem TLS)")
Endereço:         $hostaddr
Porta:            $port
UUID:             $uuid
Path:             /
--------------------------------------------
Link de importação (cole no app, ex: v2rayNG):
$vless_link
============================================
$( [[ "$mode" == "tls" ]] && echo "Nota: certificado autoassinado — o app cliente pode pedir" )
$( [[ "$mode" == "tls" ]] && echo "para confirmar/ignorar o aviso de certificado não confiável." )
CRED
}

xray_show_credentials(){
    clear
    echo -e "${C_CYAN}== Credenciais do Xray ==${C_NC}"
    echo
    if [[ -f "$CRED_FILE" ]]; then
        cat "$CRED_FILE"
    else
        echo -e "${C_YELLOW}Nenhuma credencial salva ainda.${C_NC}"
        echo " Para regenerar: reinstale o Xray pelo menu."
    fi
    pause
}

xray_show_uuids(){
    clear
    echo -e "${C_CYAN}== UUIDs cadastrados no Xray ==${C_NC}"
    echo
    if [[ -f "$XRAY_CONFIG" ]]; then
        python3 -c "
import json
try:
    d = json.load(open('$XRAY_CONFIG'))
    clients = d['inbounds'][0]['settings']['clients']
    if not clients:
        print('Nenhum cliente cadastrado.')
    for c in clients:
        print(f\"  {c.get('email','(sem nome)'):20s} {c.get('id','')}\")
except Exception as e:
    print(f'Erro ao ler config: {e}')
"
    else
        echo -e "${C_YELLOW}Xray não está configurado.${C_NC}"
    fi
    pause
}

xray_restart(){
    clear
    echo -e "${C_CYAN}== Reiniciar Xray ==${C_NC}"
    local port; port=$(conf_get XRAY_PORT)
    if xray_restart_and_check "${port:-443}"; then
        ok "Xray reiniciado com sucesso."
    fi
    pause
}

xray_uninstall(){
    clear
    echo -e "${C_RED}== Desinstalar Xray ==${C_NC}"
    read -p "Isso remove o Xray por completo (binário, config, certificados). Confirma? [s/N]: " conf
    [[ "$conf" != "s" && "$conf" != "S" ]] && return
    xray_full_uninstall
    ok "Xray removido por completo."
    pause
}

#------------------------------------------------------------
# Menu — muda de cara dependendo se já está instalado ou não
#------------------------------------------------------------
xray_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}                          XRAY                             ${C_CYAN}║${C_NC}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo

        if xray_is_installed; then
            local status_badge
            systemctl is-active --quiet xray && status_badge="${C_GREEN}● ATIVO${C_NC}" || status_badge="${C_RED}● PARADO${C_NC}"
            echo -e " Status: $status_badge"
            echo -e " Porta: ${C_GREEN}$(conf_get XRAY_PORT)${C_NC}  Transporte: ${C_GREEN}$(conf_get XRAY_TRANSPORT 2>/dev/null || echo xhttp)${C_NC}  TLS: ${C_GREEN}$(conf_get XRAY_MODE)${C_NC}"
            echo
            echo "  1) Ver credenciais (link de importação)"
            echo "  2) Ver UUIDs cadastrados"
            echo "  3) Reiniciar Xray"
            echo "  4) Desinstalar Xray"
            echo "  5) Reinstalar do zero (remove tudo e instala de novo)"
            echo "  0) Voltar"
            echo
            read -p " Escolha: " op
            case $op in
                1) xray_show_credentials ;;
                2) xray_show_uuids ;;
                3) xray_restart ;;
                4) xray_uninstall ;;
                5)
                    read -p "Confirma reinstalação completa? [s/N]: " c
                    if [[ "$c" == "s" || "$c" == "S" ]]; then
                        xray_full_uninstall
                        xray_install
                    fi
                    ;;
                0) break ;;
                *) fail "Opção inválida"; sleep 1 ;;
            esac
        else
            echo -e " ${C_YELLOW}Xray não está instalado.${C_NC}"
            echo
            echo "  1) Instalar Xray"
            echo "  0) Voltar"
            echo
            read -p " Escolha: " op
            case $op in
                1) xray_install ;;
                0) break ;;
                *) fail "Opção inválida"; sleep 1 ;;
            esac
        fi
    done
}
