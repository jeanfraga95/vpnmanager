#!/bin/bash
#============================================================
# swap.sh - Gerenciamento de memoria Swap
#============================================================
source "$INSTALL_DIR/modules/common.sh"

SWAP_FILE="/swapfile"

swap_get_info(){
    local total used
    total=$(free -m | awk '/^Swap:/{print $2}')
    used=$(free -m | awk '/^Swap:/{print $3}')
    echo "${total:-0} ${used:-0}"
}

swap_is_active(){
    local info; info=$(swap_get_info)
    local total; total=$(echo "$info" | awk '{print $1}')
    [[ "$total" -gt 0 ]]
}

swap_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}== ${L_SWAP_TITLE} ==${C_NC}"
        echo
        local info; info=$(swap_get_info)
        local total; total=$(echo "$info" | awk '{print $1}')
        local used; used=$(echo "$info" | awk '{print $2}')

        if [[ "$total" -gt 0 ]]; then
            echo -e " ${L_SWAP_CURRENT} ${C_GREEN}${L_SWAP_ACTIVE}${C_NC}  (${used}MB / ${total}MB)"
        else
            echo -e " ${L_SWAP_CURRENT} ${C_RED}${L_SWAP_NONE}${C_NC}"
        fi
        echo
        echo "  1) ${L_SWAP_CREATE}"
        echo "  2) ${L_SWAP_REMOVE}"
        echo
        echo "  0) ${L_BACK}"
        echo
        echo -e "${C_CYAN}──────────────────────────────────────────────────────────${C_NC}"
        read -p " ${L_CHOICE}" op
        case $op in
            1) _swap_create ;;
            2) _swap_remove ;;
            0) break ;;
            *) fail "${L_INVALID}"; sleep 1 ;;
        esac
    done
}

_swap_create(){
    clear
    echo -e "${C_CYAN}== ${L_SWAP_CREATE} ==${C_NC}"
    echo
    if swap_is_active; then
        local info; info=$(swap_get_info)
        local total; total=$(echo "$info" | awk '{print $1}')
        echo -e " ${L_SWAP_CURRENT} ${C_GREEN}${L_SWAP_ACTIVE}${C_NC}  (${total}MB)"
        echo " ${L_SWAP_REMOVE} primeiro antes de criar um novo."
        pause
        return
    fi

    # Sugerir 512MB ou RAM/2 (o que for menor)
    local ram_mb; ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local suggested=$((ram_mb / 2))
    [[ "$suggested" -gt 1024 ]] && suggested=1024
    [[ "$suggested" -lt 128 ]] && suggested=128

    echo " ${L_SWAP_SIZE} (${suggested}MB ${L_BACK} padrao)"
    read -p " > " input_size
    local size="${input_size:-$suggested}"

    # Validar numero
    if ! [[ "$size" =~ ^[0-9]+$ ]] || [[ "$size" -lt 1 ]]; then
        fail "${L_INVALID}"
        sleep 1
        return
    fi

    echo
    echo -e " ${L_SWAP_CONFIRM_CREATE} ${C_YELLOW}${size}MB${C_NC} ${L_SWAP_MB}"
    read -p " > " confirm
    if [[ ! "$confirm" =~ ^[sSyY]$ ]]; then
        fail "Cancelado."
        sleep 1
        return
    fi

    echo
    msg "Criando swap file de ${size}MB..."

    # Desabilitar swap se ativo
    swapoff "$SWAP_FILE" 2>/dev/null

    # Criar arquivo
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size" status=progress 2>/dev/null
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" 2>/dev/null
    swapon "$SWAP_FILE" 2>/dev/null

    # Garantir que inicia no boot
    if ! grep -qF "$SWAP_FILE" /etc/fstab 2>/dev/null; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi

    # Ajustar swappiness baixo para não priorizar swap sobre RAM
    sysctl vm.swappiness=10 2>/dev/null
    if ! grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi

    echo
    ok "${L_SWAP_CREATED}"
    local new_info; new_info=$(swap_get_info)
    local new_total; new_total=$(echo "$new_info" | awk '{print $1}')
    echo " ${L_SWAP_CURRENT} ${C_GREEN}${new_total}MB${C_NC}"
    pause
}

_swap_remove(){
    clear
    echo -e "${C_CYAN}== ${L_SWAP_REMOVE} ==${C_NC}"
    echo
    if ! swap_is_active; then
        echo -e " ${L_SWAP_CURRENT} ${C_RED}${L_SWAP_NONE}${C_NC}"
        pause
        return
    fi

    local info; info=$(swap_get_info)
    local total; total=$(echo "$info" | awk '{print $1}')
    echo -e " ${L_SWAP_CURRENT} ${C_GREEN}${L_SWAP_ACTIVE}${C_NC}  (${total}MB)"
    echo
    echo -e " ${L_SWAP_CONFIRM_REMOVE}"
    read -p " > " confirm
    if [[ ! "$confirm" =~ ^[sSyY]$ ]]; then
        fail "Cancelado."
        sleep 1
        return
    fi

    msg "Removendo swap..."
    swapoff "$SWAP_FILE" 2>/dev/null
    rm -f "$SWAP_FILE"
    sed -i "\|$SWAP_FILE|d" /etc/fstab 2>/dev/null

    echo
    ok "${L_SWAP_REMOVED}"
    pause
}
