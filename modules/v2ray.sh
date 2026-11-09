#!/bin/bash
#============================================================
# v2ray.sh - V2Ray VMess: instalação, gerenciamento
#
# Transportes: tcp, ws, kcp
# gRPC, HTTPUpgrade, H2: exclusivos do Xray-core (menu principal opção 2)
# TLS: via Nginx reverse proxy (path: /)
# Sem TLS: V2Ray escuta direto na porta pública
# Compatível com pmaster_agent / dragonmodule
#============================================================
source "$INSTALL_DIR/modules/common.sh"

V2RAY_DIR="/usr/local/etc/v2ray"
V2RAY_CONFIG="$V2RAY_DIR/config.json"
V2RAY_SSL_DIR="$V2RAY_DIR/ssl"
V2RAY_CRED_FILE="$INSTALL_DIR/conf/v2ray_credentials.txt"
V2RAY_NGINX_CONF="/etc/nginx/conf.d/v2ray.conf"

# ── Helpers ──────────────────────────────────────────────────

gen_uuid_v2(){ cat /proc/sys/kernel/random/uuid; }

v2ray_is_installed(){
    command -v v2ray &>/dev/null && [[ -f /etc/systemd/system/v2ray.service ]]
}

_v2ray_inbound_index(){
    local proto="${1:-vmess}"
    jq -r ".inbounds | to_entries[] \
        | select(.value.protocol==\"$proto\") | .key" \
        "$V2RAY_CONFIG" 2>/dev/null | head -1
}

# ── Desinstalação ─────────────────────────────────────────────

v2ray_full_uninstall(){
    systemctl disable --now v2ray 2>/dev/null || true
    rm -f /usr/local/bin/v2ray /usr/bin/v2ray
    rm -f /etc/systemd/system/v2ray.service
    rm -rf /etc/systemd/system/v2ray.service.d
    rm -rf "$V2RAY_DIR" /etc/v2ray
    rm -f "$V2RAY_CRED_FILE" "$V2RAY_NGINX_CONF"
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    systemctl daemon-reload
}

# ── Instalação do binário ─────────────────────────────────────

_install_v2ray_core(){
    msg "Baixando e instalando V2Ray (script oficial v2fly)..."
    systemctl stop v2ray 2>/dev/null || true

    bash <(curl -fsSL \
        https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) \
        > /tmp/v2ray_install.log 2>&1

    if ! command -v v2ray &>/dev/null; then
        fail "Falha ao instalar o binário do V2Ray:"
        tail -20 /tmp/v2ray_install.log
        return 1
    fi

    # CRÍTICO: fhs-install sobrescreve o service com User=nobody por último.
    # Reescrevemos com User=root APÓS o instalador terminar.
    # Com User=nobody o processo não consegue ler certs e não abre porta.
    cat > /etc/systemd/system/v2ray.service << 'SVC'
[Unit]
Description=V2Ray Service
Documentation=https://www.v2fly.org/
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/v2ray run -config /etc/v2ray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SVC

    systemctl daemon-reload
    ok "Binário instalado: $(v2ray version 2>/dev/null | head -1)"
    return 0
}

# ── Certificado autoassinado ──────────────────────────────────

_generate_v2ray_cert(){
    local ip="$1"
    mkdir -p "$V2RAY_SSL_DIR"
    if [[ -s "$V2RAY_SSL_DIR/cert.pem" && -s "$V2RAY_SSL_DIR/priv.key" ]]; then
        ok "Certificado existente reaproveitado."
        return 0
    fi
    msg "Gerando certificado autoassinado (10 anos)..."
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$V2RAY_SSL_DIR/priv.key" \
        -out    "$V2RAY_SSL_DIR/cert.pem" \
        -days 3650 -subj "/CN=$ip" \
        > /tmp/v2ray_cert.log 2>&1 || {
        fail "Erro ao gerar certificado:"; cat /tmp/v2ray_cert.log; return 1
    }
    chmod 644 "$V2RAY_SSL_DIR/cert.pem"
    chmod 600 "$V2RAY_SSL_DIR/priv.key"
}

# ── Nginx como proxy (TLS ou HTTP) ───────────────────────────
# V2Ray 5.x não suporta TLS nativo com cert autoassinado.
# Nginx faz TLS na porta pública e repassa sem TLS para o V2Ray
# na porta interna. Variáveis nginx ($host, $http_upgrade) são
# protegidas com single-quote dentro do heredoc.

_install_nginx_if_needed(){
    if ! command -v nginx &>/dev/null; then
        msg "Instalando Nginx..."
        apt-get install -y nginx > /tmp/nginx_install.log 2>&1 || {
            fail "Falha ao instalar Nginx:"; tail -5 /tmp/nginx_install.log; return 1
        }
    fi
    systemctl enable nginx 2>/dev/null
    systemctl start nginx 2>/dev/null
    return 0
}

_write_nginx_config(){
    local public_port="$1"
    local internal_port="$2"
    local transport="$3"
    local ip="$4"
    local use_tls="$5"   # "tls" ou "none"

    local proxy_target="127.0.0.1:${internal_port}"

    # remove default nginx se ocupar a porta 80
    [[ "$public_port" == "80" ]] && \
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null

    # H2 e gRPC precisam de HTTP/2 no Nginx — verificar suporte
    if [[ "$transport" == "h2" || "$transport" == "grpc" ]]; then
        if ! nginx -V 2>&1 | grep -q "http_v2_module"; then
            fail "Nginx sem suporte a HTTP/2 (ngx_http_v2_module)."
            echo " H2 e gRPC requerem Nginx com HTTP/2."
            echo " Instale: apt-get install -y nginx"
            echo " Ou use transporte WS/HTTPUpgrade que funcionam sem HTTP/2."
            return 1
        fi
    fi

    # bloco listen — H2/gRPC precisam de http2
    local listen_line
    if [[ "$use_tls" == "tls" ]]; then
        if [[ "$transport" == "h2" || "$transport" == "grpc" ]]; then
            listen_line="listen ${public_port} ssl http2;
    listen [::]:${public_port} ssl http2;"
        else
            listen_line="listen ${public_port} ssl;
    listen [::]:${public_port} ssl;"
        fi
    else
        listen_line="listen ${public_port};
    listen [::]:${public_port};"
    fi

    # bloco ssl
    local ssl_block=""
    if [[ "$use_tls" == "tls" ]]; then
        ssl_block="ssl_certificate     ${V2RAY_SSL_DIR}/cert.pem;
    ssl_certificate_key ${V2RAY_SSL_DIR}/priv.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;"
    fi

    # location por transporte
    # Variáveis do Nginx ($host, $http_upgrade etc) ficam em single-quote
    local location_block
    case "$transport" in
        tcp|ws|httpupgrade)
            # TCP, WS e HTTPUpgrade: proxy HTTP com suporte a upgrade
            location_block='    location / {
        proxy_pass http://'"${proxy_target}"';
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }'
            ;;
        h2)
            # HTTP/2: grpc_pass (V2Ray h2 é compatível com grpc_pass do Nginx)
            location_block='    location / {
        grpc_pass grpc://'"${proxy_target}"';
        grpc_set_header Host $host;
        grpc_set_header X-Real-IP $remote_addr;
        grpc_read_timeout 300s;
        grpc_send_timeout 300s;
    }'
            ;;
        grpc)
            # gRPC: grpc_pass nativo
            location_block='    location / {
        grpc_pass grpc://'"${proxy_target}"';
        grpc_set_header Host $host;
        grpc_set_header X-Real-IP $remote_addr;
        grpc_read_timeout 300s;
        grpc_send_timeout 300s;
        # Necessário para gRPC sem TLS no backend
        grpc_set_header Content-Type application/grpc;
    }'
            ;;
        *)
            location_block='    location / {
        proxy_pass http://'"${proxy_target}"';
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }'
            ;;
    esac

    # escreve config
    printf '# VPNManager — V2Ray via Nginx (%s)
server {
    %s
    server_name %s;
    %s
%s
}
' \
        "$transport" "$listen_line" "$ip" "$ssl_block" "$location_block" \
        > "$V2RAY_NGINX_CONF"

    if ! nginx -t 2>/tmp/nginx_test.log; then
        fail "Config Nginx inválida:"
        cat /tmp/nginx_test.log
        echo "Config gerada:"
        cat "$V2RAY_NGINX_CONF"
        return 1
    fi

    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi
    sleep 1
    return 0
}

# ── Config do V2Ray (sempre sem TLS) ─────────────────────────
# Não usa geoip/geosite (causam falha silenciosa no V2Ray 5.x).
# Não usa sniffing (conflito interno com WS no V2Ray 5.x).
# Não usa log em arquivo (diretório pode não existir no momento do bind).

write_v2ray_config(){
    local port="$1" transport="$2" uuid="$3" ssh_fb_port="$4"
    mkdir -p "$V2RAY_DIR"

    # streamSettings — mínimo absoluto, sem campos extras desnecessários
    # V2Ray 5.x descarta inbound silenciosamente com qualquer campo inválido
    local stream_json
    # Transportes suportados no V2Ray 5.x com VMess: tcp, ws, kcp
    # gRPC, HTTPUpgrade, H2: use Xray (menu principal opção 2)
    stream_json=$(jq -n --arg net "$transport" \
        '{ network: $net } |
         if   $net == "ws"  then . + { wsSettings:  { path: "/" } }
         elif $net == "kcp" then . + { kcpSettings: {
               mtu: 1350, tti: 50, uplinkCapacity: 12, downlinkCapacity: 100,
               congestion: false, readBufferSize: 2, writeBufferSize: 2,
               header: { type: "none" } } }
         else . end')

    # inbound mínimo: sem tag, sem email, sem routing desnecessário
    # (campos extras causam falha silenciosa no V2Ray 5.49)
    local inbound_json
    inbound_json=$(jq -n \
        --argjson port   "$port" \
        --arg     uuid   "$uuid" \
        --argjson stream "$stream_json" \
        '{ port: $port, protocol: "vmess",
           settings: { clients: [{ id: $uuid, alterId: 0 }] },
           streamSettings: $stream }')

    # dokodemo apenas se fallback SSH ativo
    local inbounds_json
    inbounds_json=$(jq -n --argjson ib "$inbound_json" '[$ib]')

    if [[ -n "$ssh_fb_port" ]]; then
        local dok_port=$(( port + 10000 ))
        local dok_json
        dok_json=$(jq -n \
            --argjson dp "$dok_port" \
            --argjson sp "$ssh_fb_port" \
            '{ port: $dp, protocol: "dokodemo-door",
               settings: { address: "127.0.0.1", port: $sp, network: "tcp" } }')
        inbounds_json=$(jq -n \
            --argjson a "$inbounds_json" \
            --argjson d "$dok_json" '$a + [$d]')
        conf_set "V2RAY_DOK_PORT" "$dok_port"
    fi

    # config final: log + inbounds + outbound freedom — sem routing
    local final_config
    final_config=$(jq -n \
        --argjson inbounds "$inbounds_json" \
        '{ log: { loglevel: "warning" },
           inbounds: $inbounds,
           outbounds: [{ protocol: "freedom" }] }')

    echo "$final_config" | jq empty 2>/dev/null || {
        fail "JSON gerado é inválido."; return 1
    }
    echo "$final_config" > "$V2RAY_CONFIG"

    conf_set "V2RAY_PORT"      "$port"
    conf_set "V2RAY_TRANSPORT" "$transport"
    conf_set "V2RAY_FB_PORT"   "${ssh_fb_port:-}"
}

# ── Subir e verificar ─────────────────────────────────────────

v2ray_restart_and_check(){
    local port="$1"

    msg "Validando config.json..."
    jq empty "$V2RAY_CONFIG" 2>/dev/null || { fail "config.json inválido."; return 1; }
    local proto; proto=$(jq -r '.inbounds[0].protocol // empty' "$V2RAY_CONFIG" 2>/dev/null)
    local pcfg;  pcfg=$(jq -r  '.inbounds[0].port // empty'     "$V2RAY_CONFIG" 2>/dev/null)
    [[ -z "$proto" || -z "$pcfg" ]] && { fail "Inbound inválido no config."; return 1; }
    ok "Config válido (proto=$proto porta=$pcfg)."

    # para processo anterior e aguarda porta liberar
    systemctl stop v2ray 2>/dev/null
    local w=0
    while ss -tln 2>/dev/null | grep -qE ":${port}( |$)"; do
        sleep 1; (( w++ ))
        [[ $w -ge 8 ]] && { fail "Porta $port não liberou após ${w}s."; return 1; }
    done

    # verifica conflito com outro processo
    local cx; cx=$(fuser "${port}/tcp" 2>/dev/null | tr -d ' ')
    if [[ -n "$cx" ]]; then
        local csvc; csvc=$(ps -p "$cx" -o comm= 2>/dev/null || echo "pid=$cx")
        fail "Porta $port ocupada por '$csvc'. Escolha outra porta."
        return 1
    fi

    local t; t=$(date '+%Y-%m-%d %H:%M:%S')
    systemctl enable v2ray >/dev/null 2>&1
    systemctl start v2ray

    # aguarda processo ativo (15s)
    local i=0
    while ! systemctl is-active --quiet v2ray; do
        (( i++ )); [[ $i -ge 15 ]] && {
            fail "V2Ray não ficou ativo após ${i}s."
            journalctl -u v2ray --since "$t" -n 20 --no-pager 2>/dev/null
            return 1
        }
        sleep 1
    done

    # aguarda porta abrir (15s)
    i=0; local found=0
    while [[ $i -lt 15 ]]; do
        ss -tln 2>/dev/null | grep -qE ":${port}( |$)" && { found=1; break; }
        ss -uln 2>/dev/null | grep -qE ":${port}( |$)" && { found=1; break; }
        sleep 1; (( i++ ))
    done

    if [[ $found -eq 0 ]]; then
        fail "V2Ray ativo mas porta $port não abriu após ${i}s."
        journalctl -u v2ray --since "$t" -n 20 --no-pager 2>/dev/null
        return 1
    fi
    return 0
}

# ── Instalação principal ──────────────────────────────────────

v2ray_install(){
    clear
    echo -e "${C_CYAN}== Instalar V2Ray (VMess) ==${C_NC}"
    echo

    echo "Escolha o transporte:"
    echo "  1) TCP"
    echo "  2) WebSocket (WS)  — path /"
    echo "  3) mKCP (UDP)"
    echo ""
    echo -e "  ${C_YELLOW}HTTPUpgrade, H2 e gRPC: use o menu Xray (mais completo).${C_NC}"
    read -p "Transporte [1-3]: " topt
    case $topt in
        1) transport="tcp" ;;
        2) transport="ws" ;;
        3) transport="kcp" ;;
        *) fail "Opção inválida."; pause; return ;;
    esac

    local tls="none"
    if [[ "$transport" != "kcp" ]]; then
        echo
        echo "Segurança:"
        echo "  1) Sem TLS  (V2Ray escuta direto na porta pública)"
        echo "  2) TLS      (Nginx → TLS na porta pública, V2Ray em porta interna)"
        read -p "Modo [1-2]: " tlsopt
        case $tlsopt in
            1) tls="none" ;;
            2) tls="nginx" ;;
            *) fail "Opção inválida."; pause; return ;;
        esac
    fi

    # porta pública (onde o app conecta)
    read -p "Porta pública (onde o app vai conectar, ex: 8082): " public_port
    [[ ! "$public_port" =~ ^[0-9]+$ ]] && { fail "Porta inválida."; pause; return; }

    # porta interna (onde V2Ray escuta — apenas com Nginx)
    local internal_port="$public_port"
    if [[ "$tls" == "nginx" ]]; then
        echo
        echo "Portas em uso agora:"
        ss -tlnp 2>/dev/null | awk 'NR>1{print "  "$4}' | sort -t: -k2 -n
        echo
        local def_internal=$(( public_port + 10000 ))
        read -p "Porta interna do V2Ray [padrão: ${def_internal}]: " internal_port
        internal_port="${internal_port:-$def_internal}"
        [[ ! "$internal_port" =~ ^[0-9]+$ ]] && { fail "Porta inválida."; pause; return; }
        [[ "$internal_port" == "$public_port" ]] && {
            fail "Porta interna deve ser diferente da pública."; pause; return; }
        msg "Fluxo: App → :${public_port} (TLS/Nginx) → :${internal_port} (V2Ray)"
    fi

    msg "Detectando IP público..."
    local detected_ip; detected_ip=$(get_ip)
    read -p "IP/domínio [${detected_ip:-?}] (Enter = usar detectado): " hostaddr
    hostaddr="${hostaddr:-$detected_ip}"
    [[ -z "$hostaddr" ]] && { fail "IP não detectado."; pause; return; }

    echo
    read -p "Fallback SSH? Tráfego não-VMess → sshd [s/N]: " fb_opt
    local ssh_fb_port=""
    if [[ "$fb_opt" =~ ^[sS]$ ]]; then
        local sshd_p; sshd_p=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null \
            | awk '{print $2}' | head -1)
        ssh_fb_port="${sshd_p:-22}"
        msg "Fallback → sshd porta $ssh_fb_port"
    fi

    # verifica conflito na porta interna
    systemctl stop v2ray 2>/dev/null; sleep 1
    local cx; cx=$(fuser "${internal_port}/tcp" 2>/dev/null | tr -d ' ')
    if [[ -n "$cx" ]]; then
        local csvc; csvc=$(ps -p "$cx" -o comm= 2>/dev/null || echo "pid=$cx")
        fail "Porta interna $internal_port ocupada por '$csvc'."
        pause; return
    fi

    _install_v2ray_core || { pause; return; }

    if [[ "$tls" == "nginx" ]]; then
        _install_nginx_if_needed || { pause; return; }
        _generate_v2ray_cert "$hostaddr" || { pause; return; }
    fi

    local uuid; uuid=$(gen_uuid_v2)
    write_v2ray_config "$internal_port" "$transport" "$uuid" "$ssh_fb_port" \
        || { pause; return; }

    conf_set "V2RAY_TLS"         "$tls"
    conf_set "V2RAY_PUBLIC_PORT" "$public_port"
    conf_set "V2RAY_INT_PORT"    "$internal_port"
    conf_set "V2RAY_HOST"        "$hostaddr"

    # salva credenciais antes de subir
    v2ray_save_credentials "$public_port" "$transport" "$tls" "$hostaddr" "$uuid"

    ufw allow "$public_port"/tcp >/dev/null 2>&1
    [[ "$transport" == "kcp" ]] && ufw allow "$public_port"/udp >/dev/null 2>&1

    if ! v2ray_restart_and_check "$internal_port"; then
        fail "V2Ray não subiu. Verifique acima."
        pause; return
    fi
    ok "V2Ray rodando na porta $internal_port."

    if [[ "$tls" == "nginx" ]]; then
        msg "Configurando Nginx: :${public_port} (TLS) → :${internal_port}..."
        _write_nginx_config "$public_port" "$internal_port" \
            "$transport" "$hostaddr" "tls" || { pause; return; }
        sleep 2
        if ss -tln 2>/dev/null | grep -qE ":${public_port}( |$)"; then
            ok "Nginx ativo na porta pública $public_port."
        else
            fail "Nginx configurado mas porta $public_port não abriu."
            echo "  nginx -t → $(nginx -t 2>&1 | head -3)"
        fi
    fi

    ok "Instalação concluída!"
    echo
    echo "── Credenciais ──────────────────────────────────────────"
    cat "$V2RAY_CRED_FILE"
    pause
}

# ── Credenciais / link vmess:// ───────────────────────────────

v2ray_save_credentials(){
    local public_port="$1" transport="$2" tls="$3" hostaddr="$4" uuid="$5"
    mkdir -p "$(dirname "$V2RAY_CRED_FILE")"

    local net="$transport"
    local path_val="/"; [[ "$net" == "tcp" || "$net" == "kcp" ]] && path_val=""
    local sn_val="";    [[ "$net" == "grpc" ]] && sn_val="/"
    local host_val="";  [[ "$net" == "ws"   ]] && host_val="$hostaddr"
    local tls_val="";   [[ "$tls" == "nginx" ]] && tls_val="tls"
    local sni_val="";   [[ "$tls" == "nginx" ]] && sni_val="$hostaddr"

    local vmess_json
    vmess_json=$(printf \
        '{"v":"2","ps":"VPNManager","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"%s","type":"none","host":"%s","path":"%s","tls":"%s","sni":"%s","alpn":""}' \
        "$hostaddr" "$public_port" "$uuid" "$net" \
        "$host_val" "${path_val:-$sn_val}" "$tls_val" "$sni_val")

    local vmess_link="vmess://$(echo -n "$vmess_json" | base64 -w0)"

    local tls_label
    case "$tls" in
        nginx) tls_label="TLS via Nginx (autoassinado — ative Allow Insecure no app)" ;;
        none)  tls_label="Sem TLS" ;;
        *)     tls_label="$tls" ;;
    esac

    cat > "$V2RAY_CRED_FILE" << CRED
============================================
 V2RAY (VMess) - Credenciais
============================================
Transporte : $transport
Segurança  : $tls_label
Endereço   : $hostaddr
Porta      : $public_port
UUID       : $uuid
Path       : $([ -n "$path_val" ] && echo "/" || echo "(N/A)")
--------------------------------------------
vmess:// (v2rayNG / NekoBox / Hiddify):
$vmess_link
============================================
CRED
}

v2ray_show_credentials(){
    clear
    echo -e "${C_CYAN}== Credenciais do V2Ray ==${C_NC}"
    echo
    [[ -f "$V2RAY_CRED_FILE" ]] && cat "$V2RAY_CRED_FILE" \
        || echo -e "${C_YELLOW}Nenhuma credencial salva ainda.${C_NC}"
    pause
}

# ── Gerenciamento de usuários (API pmaster_agent) ─────────────

v2ray_add_user(){
    local uuid="$1" ssh_user="$2" senha="$3" dias="$4" limite="$5"
    [[ -f "$V2RAY_CONFIG" ]] || { echo "Config V2Ray nao encontrada"; return 1; }
    local idx; idx=$(_v2ray_inbound_index "vmess")
    [[ -z "$idx" ]] && { echo "Sem inbound VMess"; return 1; }
    if jq -e --arg id "$uuid" \
            ".inbounds[$idx].settings.clients[]? | select(.id==\$id)" \
            "$V2RAY_CONFIG" > /dev/null 2>&1; then
        echo "UUID ja existe"
    else
        jq --arg id "$uuid" --arg email "$ssh_user" \
            ".inbounds[$idx].settings.clients += \
             [{\"id\":\$id,\"alterId\":0,\"email\":\$email}]" \
            "$V2RAY_CONFIG" > "${V2RAY_CONFIG}.tmp" \
        && jq empty "${V2RAY_CONFIG}.tmp" 2>/dev/null \
        && mv "${V2RAY_CONFIG}.tmp" "$V2RAY_CONFIG" \
        || rm -f "${V2RAY_CONFIG}.tmp"
        systemctl restart v2ray 2>/dev/null || true
    fi
    echo "1"
    ssh_create_api "$ssh_user" "$senha" "$dias" "$limite"
}

v2ray_add_teste(){
    local uuid="$1" ssh_user="$2" senha="$3" minutos="$4" limite="$5"
    [[ -f "$V2RAY_CONFIG" ]] || { echo "Config V2Ray nao encontrada"; return 1; }
    local idx; idx=$(_v2ray_inbound_index "vmess")
    [[ -z "$idx" ]] && { echo "Sem inbound VMess"; return 1; }
    if jq -e --arg id "$uuid" \
            ".inbounds[$idx].settings.clients[]? | select(.id==\$id)" \
            "$V2RAY_CONFIG" > /dev/null 2>&1; then
        echo "2"; return
    fi
    jq --arg id "$uuid" --arg email "$ssh_user" \
        ".inbounds[$idx].settings.clients += \
         [{\"id\":\$id,\"alterId\":0,\"email\":\$email}]" \
        "$V2RAY_CONFIG" > "${V2RAY_CONFIG}.tmp" \
    && jq empty "${V2RAY_CONFIG}.tmp" 2>/dev/null \
    && mv "${V2RAY_CONFIG}.tmp" "$V2RAY_CONFIG" \
    || rm -f "${V2RAY_CONFIG}.tmp"
    systemctl restart v2ray 2>/dev/null || true

    local folder_path="/etc/PanelMaster"
    local rnd; rnd=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 10)
    local script_path="$folder_path/${rnd}_${ssh_user}.sh"
    mkdir -p "$folder_path"
    cat > "$script_path" << SCRIPT
#!/bin/bash
/etc/VPNManager/modules/v2ray.sh api_del $uuid
usermod -p \$(openssl passwd -1 'pmaster_expired_2024') $ssh_user
pkill -u "$ssh_user" 2>/dev/null; userdel --force "$ssh_user" 2>/dev/null
grep -v "^$ssh_user " /root/pm_users.db > /tmp/pm_ph 2>/dev/null
cat /tmp/pm_ph > /root/pm_users.db
rm -f /etc/SSHPlus/senha/$ssh_user "$script_path"
SCRIPT
    chmod +x "$script_path"
    nohup bash -c "sleep $(( minutos * 60 )) && $script_path" >/dev/null 2>&1 &
    echo "1"
    ssh_create_api "$ssh_user" "$senha" "1" "$limite"
}

v2ray_del_user(){
    local uuid="$1" login="$2"
    if [[ -f "$V2RAY_CONFIG" ]]; then
        if jq -e --arg id "$uuid" \
                '.inbounds[]? | select(.protocol=="vmess")
                 | .settings.clients[]? | select(.id==$id)' \
                "$V2RAY_CONFIG" > /dev/null 2>&1; then
            jq --arg id "$uuid" '
                .inbounds = (.inbounds | map(
                    if .protocol == "vmess" then
                        .settings.clients = (
                            (.settings.clients // []) | map(select(.id != $id)))
                    else . end))' \
                "$V2RAY_CONFIG" > "${V2RAY_CONFIG}.tmp" \
            && jq empty "${V2RAY_CONFIG}.tmp" 2>/dev/null \
            && mv "${V2RAY_CONFIG}.tmp" "$V2RAY_CONFIG" \
            || rm -f "${V2RAY_CONFIG}.tmp"
            systemctl restart v2ray 2>/dev/null || true
        fi
    fi
    [[ -n "$login" ]] && ssh_remove_api "$login"
    echo "REMOVIDOCOMSUCESSO"
}

# ── Listagem ──────────────────────────────────────────────────

v2ray_show_uuids(){
    clear
    echo -e "${C_CYAN}== UUIDs cadastrados no V2Ray ==${C_NC}"
    echo
    if [[ -f "$V2RAY_CONFIG" ]]; then
        jq -r '.inbounds[] | select(.protocol=="vmess")
               | .settings.clients[]
               | "  \(.email // "(sem nome)")  \(.id)"' \
            "$V2RAY_CONFIG" 2>/dev/null \
            || echo -e "${C_YELLOW}Erro ao ler config.${C_NC}"
    else
        echo -e "${C_YELLOW}V2Ray não configurado.${C_NC}"
    fi
    pause
}

# ── Reiniciar ─────────────────────────────────────────────────

v2ray_restart(){
    clear
    echo -e "${C_CYAN}== Reiniciar V2Ray ==${C_NC}"
    echo
    [[ ! -f "$V2RAY_CONFIG" ]] && {
        fail "Nenhum config.json. Instale o V2Ray primeiro."
        pause; return
    }
    local port; port=$(conf_get V2RAY_PORT 2>/dev/null)
    [[ -z "$port" || "$port" == "null" ]] && \
        port=$(jq -r '.inbounds[0].port // empty' "$V2RAY_CONFIG" 2>/dev/null)
    [[ -z "$port" ]] && { fail "Porta não encontrada no config."; pause; return; }

    msg "Reiniciando V2Ray na porta $port..."
    if v2ray_restart_and_check "$port"; then
        ok "V2Ray reiniciado (porta $port)."
        local tls; tls=$(conf_get V2RAY_TLS 2>/dev/null)
        if [[ "$tls" == "nginx" ]]; then
            systemctl reload nginx 2>/dev/null && ok "Nginx recarregado."
        fi
    fi
    pause
}

# ── Desinstalar ───────────────────────────────────────────────

v2ray_uninstall(){
    clear
    echo -e "${C_RED}== Desinstalar V2Ray ==${C_NC}"
    read -p "Confirma remoção completa (V2Ray + config Nginx)? [s/N]: " conf
    [[ "$conf" =~ ^[sS]$ ]] || return
    v2ray_full_uninstall
    ok "V2Ray removido."
    pause
}

# ── Ponto de entrada para scripts externos ────────────────────

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    INSTALL_DIR="${INSTALL_DIR:-/etc/VPNManager}"
    source "$INSTALL_DIR/modules/common.sh"
    source "$INSTALL_DIR/modules/ssh_users.sh"
    case "$1" in
        api_add)  shift; v2ray_add_user  "$@" ;;
        api_del)  shift; v2ray_del_user  "$@" ;;
        api_test) shift; v2ray_add_teste "$@" ;;
        *) echo "Uso: $0 {api_add|api_del|api_test} [args]" ;;
    esac
    exit $?
fi

# ── Menu ──────────────────────────────────────────────────────

v2ray_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}                         V2RAY                             ${C_CYAN}║${C_NC}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo

        if v2ray_is_installed; then
            local badge vtransport vtls vpubport vintport
            systemctl is-active --quiet v2ray \
                && badge="${C_GREEN}● ATIVO${C_NC}" \
                || badge="${C_RED}● PARADO${C_NC}"
            vtransport=$(conf_get V2RAY_TRANSPORT 2>/dev/null)
            vtls=$(conf_get V2RAY_TLS 2>/dev/null)
            vpubport=$(conf_get V2RAY_PUBLIC_PORT 2>/dev/null)
            vintport=$(conf_get V2RAY_PORT 2>/dev/null)
            echo -e " Status      : $badge"
            echo -e " Porta app   : ${C_GREEN}${vpubport:-$vintport}${C_NC}"
            echo -e " Transporte  : ${C_GREEN}${vtransport:-?}${C_NC}  TLS: ${C_GREEN}${vtls:-none}${C_NC}"
            echo
            echo "  1) Ver credenciais (vmess://)"
            echo "  2) Ver UUIDs cadastrados"
            echo "  3) Reiniciar V2Ray"
            echo "  4) Desinstalar V2Ray"
            echo "  5) Reinstalar do zero"
            echo "  0) Voltar"
            echo
            read -p " Escolha: " op
            case $op in
                1) v2ray_show_credentials ;;
                2) v2ray_show_uuids ;;
                3) v2ray_restart ;;
                4) v2ray_uninstall ;;
                5) read -p "Confirma reinstalação? [s/N]: " c
                   [[ "$c" =~ ^[sS]$ ]] && { v2ray_full_uninstall; v2ray_install; } ;;
                0) break ;;
                *) fail "Opção inválida."; sleep 1 ;;
            esac
        else
            echo -e " ${C_YELLOW}V2Ray não instalado.${C_NC}"
            echo
            echo "  1) Instalar V2Ray"
            echo "  0) Voltar"
            echo
            read -p " Escolha: " op
            case $op in
                1) v2ray_install ;;
                0) break ;;
                *) fail "Opção inválida."; sleep 1 ;;
            esac
        fi
    done
}
