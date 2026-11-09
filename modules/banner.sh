#!/bin/bash
#============================================================
# banner.sh - Banner de conexão SSH
#
# Gera o texto exibido para o cliente antes do login SSH,
# grava em /etc/bannerssh e aponta o sshd_config para ele
# via a diretiva "Banner /etc/bannerssh".
#
# Texto simples, sem cor e sem ASCII art: apps de VPN (HTTP
# Injector, NPV Tunnel etc.) mostram o banner numa caixa de
# texto simples e não interpretam códigos ANSI nem fontes
# grandes — só aparecem como caracteres quebrados/defasados.
#============================================================
source "$INSTALL_DIR/modules/common.sh"

BANNER_FILE="/etc/bannerssh"
BANNER_SSHD_CONF="/etc/ssh/sshd_config"

# ── Helpers ──────────────────────────────────────────────────

banner_is_configured(){ [[ -s "$BANNER_FILE" ]]; }

_banner_is_active_in_sshd(){
    grep -qE "^Banner[[:space:]]+${BANNER_FILE//\//\\/}[[:space:]]*$" "$BANNER_SSHD_CONF" 2>/dev/null
}

_banner_set_sshd_directive(){
    # $1 = valor ("/etc/bannerssh" ou "none")
    local value="$1"
    if grep -qE "^[#[:space:]]*Banner[[:space:]]" "$BANNER_SSHD_CONF" 2>/dev/null; then
        sed -i -E "s|^[#[:space:]]*Banner[[:space:]].*|Banner ${value}|" "$BANNER_SSHD_CONF"
    else
        echo "Banner ${value}" >> "$BANNER_SSHD_CONF"
    fi
}

_banner_restart_ssh(){
    sshd -t 2>/dev/null
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
}

# ── Criar / editar banner ─────────────────────────────────────

banner_create(){
    clear
    echo -e "${C_CYAN}== ${L_BN_CREATE_TITLE} ==${C_NC}"
    echo
    echo " ${L_BN_CREATE_DESC1}"
    echo " ${L_BN_CREATE_DESC2}"
    echo

    local lines=()
    while true; do
        read -p "> " line
        [[ "$line" == "." ]] && break
        lines+=("$line")
    done

    if [[ ${#lines[@]} -eq 0 ]]; then
        fail "${L_BN_CREATE_EMPTY}"
        pause; return
    fi

    printf '%s\n' "${lines[@]}" > "$BANNER_FILE"

    _banner_set_sshd_directive "$BANNER_FILE"
    _banner_restart_ssh

    echo
    ok "${L_BN_CREATE_SAVED}$BANNER_FILE${L_BN_CREATE_SAVED_SUFFIX}"
    echo
    echo -e "${C_CYAN}${L_BN_PREVIEW_TITLE}:${C_NC}"
    cat "$BANNER_FILE"
    echo
    pause
}

# ── Visualizar ────────────────────────────────────────────────

banner_preview(){
    clear
    echo -e "${C_CYAN}== ${L_BN_PREVIEW_TITLE} ==${C_NC}"
    echo
    if banner_is_configured; then
        cat "$BANNER_FILE"
    else
        echo -e "${C_YELLOW}${L_BN_PREVIEW_NONE}${C_NC}"
    fi
    echo
    pause
}

# ── Remover ───────────────────────────────────────────────────

banner_remove(){
    clear
    echo -e "${C_RED}== ${L_BN_REMOVE_TITLE} ==${C_NC}"
    if ! banner_is_configured; then
        echo -e "${C_YELLOW}${L_BN_PREVIEW_NONE}${C_NC}"
        pause; return
    fi
    read -p "${L_BN_REMOVE_CONFIRM} " conf
    [[ "$conf" =~ ^[sS]$ ]] || return

    rm -f "$BANNER_FILE"
    _banner_set_sshd_directive "none"
    _banner_restart_ssh

    ok "${L_BN_REMOVE_DONE}"
    pause
}

# ── Menu ──────────────────────────────────────────────────────

banner_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}                     ${L_BN_TITLE}                            ${C_CYAN}║${C_NC}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo

        if banner_is_configured && _banner_is_active_in_sshd; then
            echo -e " Status: ${C_GREEN}${L_BN_ACTIVE}${C_NC} ($BANNER_FILE)"
        elif banner_is_configured; then
            echo -e " Status: ${C_YELLOW}${L_BN_SAVED_NOT_ACTIVE}${C_NC}"
        else
            echo -e " Status: ${C_RED}${L_BN_NOT_CONFIGURED}${C_NC}"
        fi
        echo
        echo "  1) ${L_BN_OPT_CREATE}"
        echo "  2) ${L_BN_OPT_PREVIEW}"
        echo "  3) ${L_BN_OPT_REMOVE}"
        echo "  0) ${L_BN_OPT_BACK}"
        echo
        read -p " ${L_CHOICE}" op
        case $op in
            1) banner_create  ;;
            2) banner_preview ;;
            3) banner_remove  ;;
            0) break ;;
            *) fail "${L_INVALID}"; sleep 1 ;;
        esac
    done
}
