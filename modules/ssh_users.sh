#!/bin/bash
#============================================================
# ssh_users.sh - criação/exclusão/relatório de usuários SSH
#
# Compatível com pmaster_agent / dragonmodule:
#   - usa grupo pmg_vpn
#   - salva senha em /etc/SSHPlus/senha/<user>
#   - registra limite em /root/pm_users.db
#   - expira via chage -E (mesma convenção do pmaster_agent)
#   - shell fixo /bin/false
#============================================================
source "$INSTALL_DIR/modules/common.sh"

# ── Constantes de integração com o painel master ─────────────
PM_DB="/root/pm_users.db"
PM_SENHA_DIR="/etc/SSHPlus/senha"
PM_GROUP="pmg_vpn"

# ── Helpers internos ─────────────────────────────────────────

_pm_ensure_dirs(){
    mkdir -p "$PM_SENHA_DIR"
    groupadd "$PM_GROUP" 2>/dev/null || true
}

# Remove usuário do sistema e de todos os arquivos do painel
_pm_purge_user(){
    local u="$1"
    # invalida a senha antes de matar sessões (mesmo comportamento do pmaster_agent)
    usermod -p "$(openssl passwd -1 'pmaster_expired_2024')" "$u" 2>/dev/null || true
    pkill -KILL -u "$u" 2>/dev/null || true
    userdel "$u" 2>/dev/null || true
    # limpa db e arquivos de senha
    grep -v "^$u " "$PM_DB" > /tmp/pm_ph 2>/dev/null
    cat /tmp/pm_ph > "$PM_DB" 2>/dev/null
    rm -f "$PM_SENHA_DIR/$u" "/etc/usuarios/$u" 2>/dev/null
}

# Retorna 0 se o usuário existe no sistema
_user_exists(){ getent passwd "$1" > /dev/null 2>&1; }

# Conta sessões ativas do usuário (ps, não who — captura túneis SSH também)
_user_online(){ ps -u "$1" -o pid= 2>/dev/null | wc -l | tr -d ' '; }

# ── Criação de usuário SSH (interativa) ──────────────────────

ssh_create_user(){
    clear
    echo -e "${C_CYAN}== ${L_SU_TITLE} ==${C_NC}"

    # ── nome ──
    read -p "$L_SU_USERNAME" user
    valid_username "$user" || { fail "$L_SU_INVALID_USER"; pause; return; }
    _user_exists "$user" && { fail "$(echo "$L_SU_EXISTS" | sed "s/\$user/$user/g")"; pause; return; }

    # ── senha ──
    read -s -p "$L_SU_PASSWORD" pass; echo
    [[ -z "$pass" ]] && { fail "$L_SU_EMPTY_PASS"; pause; return; }

    # ── validade ──
    read -p "$L_SU_DAYS" days
    if [[ -n "$days" ]]; then
        [[ ! "$days" =~ ^[0-9]+$ ]] && { fail "$L_SU_INVALID_DAYS"; pause; return; }
    fi

    # ── limite de conexões simultâneas ──
    read -p "$L_SU_LIMIT" limit
    if [[ -n "$limit" ]]; then
        [[ ! "$limit" =~ ^[0-9]+$ ]] && { fail "$L_SU_INVALID_LIMIT"; pause; return; }
    fi
    limit="${limit:-0}"    # 0 = ilimitado (convenção do painel master)

    _pm_ensure_dirs

    # calcula data de expiração (pmaster_agent soma +1 dia; mantemos a mesma lógica)
    local expdate=""
    if [[ -n "$days" ]]; then
        local real_days=$(( days + 1 ))
        expdate=$(date "+%Y-%m-%d" -d "+${real_days} days")
    fi

    # cria o usuário — shell /bin/false, sem home, no grupo pmg_vpn
    if [[ -n "$expdate" ]]; then
        useradd -e "$expdate" -M -s /bin/false -G "$PM_GROUP" "$user" 2>/dev/null
    else
        useradd -M -s /bin/false -G "$PM_GROUP" "$user" 2>/dev/null
    fi

    # força shell e grupo mesmo se useradd já tinha o user (migração)
    usermod -s /bin/false -aG "$PM_GROUP" "$user" 2>/dev/null || true

    # define senha via chpasswd (mais seguro que perl crypt com salt fixo)
    echo "$user:$pass" | chpasswd

    # salva senha em texto plano — exigido pelo pmaster_agent e painéis legados
    echo "$pass" > "$PM_SENHA_DIR/$user"

    # registra no db do painel master (remove entrada antiga, insere nova)
    grep -v "^$user " "$PM_DB" > /tmp/pm_ph 2>/dev/null
    echo "$user $limit" >> /tmp/pm_ph
    cat /tmp/pm_ph > "$PM_DB"

    ok "$L_SU_CREATED"
    echo
    echo -e "  ${L_SU_FIELD_USER} : ${C_GREEN}$user${C_NC}"
    echo -e "  ${L_SU_FIELD_PASS}   : ${C_GREEN}$pass${C_NC}"
    echo -e "  ${L_SU_FIELD_LIMIT}  : ${C_GREEN}$( [[ "$limit" -eq 0 ]] && echo "$L_SU_UNLIMITED" || echo "$limit conexões" )${C_NC}"
    echo -e "  ${L_SU_FIELD_EXPIRES}  : ${C_GREEN}$( [[ -n "$expdate" ]] && echo "$expdate" || echo "$L_SU_NEVER" )${C_NC}"
    echo -e "  ${L_SU_FIELD_IP}  : ${C_GREEN}$(get_ip)${C_NC}"
    echo
    pause
}

# ── Criação via script externo (pmaster_agent / dragonmodule) ─
# Assinatura compatível:
#   ssh_create_api <username> <password> <dias> <limite>
# Retorna "CRIADOCOMSUCESSO" em caso de sucesso (string esperada pelos painéis).

ssh_create_api(){
    local username="$1" password="$2" dias="$3" sshlimiter="$4"

    [[ -z "$username" || -z "$password" || -z "$dias" ]] && { echo "$L_SU_API_PARAMS"; return 1; }

    # remove usuário anterior se existir (idempotente, igual ao pmaster_agent)
    if _user_exists "$username"; then
        _pm_purge_user "$username"
    fi

    _pm_ensure_dirs

    local real_days=$(( dias + 1 ))
    local expdate; expdate=$(date "+%Y-%m-%d" -d "+${real_days} days")
    local limit="${sshlimiter:-0}"

    useradd -e "$expdate" -M -s /bin/false -G "$PM_GROUP" "$username" 2>/dev/null
    usermod -s /bin/false -aG "$PM_GROUP" "$username" 2>/dev/null || true

    echo "$username:$password" | chpasswd

    echo "$password" > "$PM_SENHA_DIR/$username"

    grep -v "^$username " "$PM_DB" > /tmp/pm_ph 2>/dev/null
    echo "$username $limit" >> /tmp/pm_ph
    cat /tmp/pm_ph > "$PM_DB"

    echo "CRIADOCOMSUCESSO"
}

# ── Remoção via script externo ────────────────────────────────
# Assinatura compatível com pmaster_agent:
#   ssh_remove_api <username>
# Retorna "REMOVIDOCOMSUCESSO".

ssh_remove_api(){
    local USR="$1"
    [[ -z "$USR" ]]    && { echo "$L_SU_API_SPECIFY"; return 1; }
    [[ "$USR" == "root" ]] && { echo "$L_SU_API_NOT_ALLOWED"; return 1; }

    _user_exists "$USR" && _pm_purge_user "$USR"

    # mesmo quando o usuário não existia, limpa entradas residuais
    grep -v "^$USR " "$PM_DB" > /tmp/pm_ph 2>/dev/null
    cat /tmp/pm_ph > "$PM_DB" 2>/dev/null
    rm -f "$PM_SENHA_DIR/$USR" "/etc/usuarios/$USR" 2>/dev/null

    echo "REMOVIDOCOMSUCESSO"
}

# ── Renovação de validade via script externo ──────────────────
# Assinatura: ssh_renew_api <username> <dias>
# Retorna "RENOVADOCOMSUCESSO".

ssh_renew_api(){
    local usuario="$1" dias="$2"
    local finaldate; finaldate=$(date "+%Y-%m-%d" -d "+$dias days")
    chage -E "$finaldate" "$usuario"
    echo "RENOVADOCOMSUCESSO"
}

# ── Relatório de usuários (interativo) ───────────────────────

ssh_report(){
    clear
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
    echo -e "${C_CYAN}║${C_WHITE}                 ${L_SU_REPORT_TITLE}                 ${C_CYAN}║${C_NC}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
    echo
    printf " %-18s %-12s %-8s %-6s\n" "$L_SU_REPORT_HEADER_USER" "$L_SU_REPORT_HEADER_EXP" "$L_SU_REPORT_HEADER_ONLINE" "$L_SU_REPORT_HEADER_LIMIT"
    echo "────────────────────────────────────────────────────────"

    local found=0
    while IFS=: read -r uname _ uid _ _ _ shell; do
        [[ "$uid" -ge 1000 && "$shell" == "/bin/false" ]] || continue
        found=1

        local exp limit online
        exp=$(chage -l "$uname" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
        [[ -z "$exp" || "$exp" == "never" ]] && exp="$L_SU_NEVER"

        limit=$(grep "^$uname " "$PM_DB" 2>/dev/null | awk '{print $2}')
        [[ -z "$limit" || "$limit" == "0" ]] && limit="∞" || limit="$limit"

        online=$(_user_online "$uname")

        printf " %-18s %-12s %-8s %-6s\n" "$uname" "$exp" "$online" "$limit"
    done < <(sort -t: -k1,1 /etc/passwd)

    echo
    [[ "$found" -eq 0 ]] && echo -e "${C_YELLOW}${L_SU_REPORT_NONE}${C_NC}"
    pause
}

# ── Usuários online (interativo) ─────────────────────────────

ssh_online_users(){
    clear
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
    echo -e "${C_CYAN}║${C_WHITE}                    ${L_SU_ONLINE_TITLE}                        ${C_CYAN}║${C_NC}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
    echo

    # agrupa por usuário: nome, IPs distintos, contagem de processos
    local found=0
    while IFS=: read -r uname _ uid _ _ _ shell; do
        [[ "$uid" -ge 1000 && "$shell" == "/bin/false" ]] || continue
        local procs; procs=$(_user_online "$uname")
        [[ "$procs" -eq 0 ]] && continue
        found=1
        local ips; ips=$(ss -tnp 2>/dev/null | awk -v u="$uname" '$0 ~ u {print $5}' | cut -d: -f1 | sort -u | tr '\n' ',' | sed 's/,$//')
        printf " %-18s %s processo(s)  %s\n" "$uname" "$procs" "${ips:-(local)}"
    done < <(sort -t: -k1,1 /etc/passwd)
    [[ "$found" -eq 0 ]] && echo -e "${C_YELLOW}${L_SU_ONLINE_NONE}${C_NC}"
    echo
    pause
}

# ── Exclusão interativa ───────────────────────────────────────

ssh_delete_user(){
    clear
    echo -e "${C_CYAN}== ${L_SU_DELETE_TITLE} ==${C_NC}"
    echo
    echo "$L_SU_DELETE_AVAILABLE"
    awk -F: '$3>=1000 && $7=="/bin/false" {print "  - "$1}' /etc/passwd | sort
    echo
    read -p "$L_SU_DELETE_PROMPT" user
    _user_exists "$user" || { fail "$(echo "$L_SU_DELETE_NOT_EXISTS" | sed "s/\$user/$user/g")"; pause; return; }
    read -p "$(echo "$L_SU_DELETE_CONFIRM" | sed "s/\$user/$user/g")" conf
    [[ "$conf" != "s" && "$conf" != "S" ]] && return

    ssh_remove_api "$user"
    ok "$(echo "$L_SU_DELETE_REMOVED" | sed "s/\$user/$user/g")"
    pause
}

# ── Exclusão em massa ──────────────────────────────────────────

ssh_delete_all_users(){
    clear
    echo -e "${C_RED}== ${L_SU_DELETE_ALL_TITLE} ==${C_NC}"
    echo

    local users=()
    while IFS=: read -r uname _ uid _ _ _ shell; do
        [[ "$uid" -ge 1000 && "$shell" == "/bin/false" ]] || continue
        users+=("$uname")
    done < <(sort -t: -k1,1 /etc/passwd)

    local total=${#users[@]}
    if (( total == 0 )); then
        echo -e "${C_YELLOW}${L_SU_DELETE_ALL_NONE}${C_NC}"
        pause; return
    fi

    echo -e "${C_YELLOW}$(echo "$L_SU_DELETE_ALL_WARN" | sed "s/\\\$total/$total/g")${C_NC}"
    printf '  - %s\n' "${users[@]}"
    echo
    echo -e "${C_RED}${L_SU_DELETE_ALL_IRREVERSIBLE}${C_NC}"
    read -p "$L_SU_DELETE_ALL_CONFIRM" conf
    if [[ "$conf" != "EXCLUIR" ]]; then
        fail "$L_SU_DELETE_ALL_WRONG"
        pause; return
    fi

    local count=0
    for u in "${users[@]}"; do
        ssh_remove_api "$u" > /dev/null 2>&1
        (( count++ ))
    done

    ok "$(echo "$L_SU_DELETE_ALL_DONE" | sed "s/\\\$count/$count/g")"
    pause
}

# ── Exclusão de usuários vencidos ──────────────────────────────

ssh_delete_expired_users(){
    clear
    echo -e "${C_RED}== ${L_SU_EXPIRED_TITLE} ==${C_NC}"
    echo

    local today_days=$(( $(date +%s) / 86400 ))
    local expired=()

    while IFS=: read -r uname _ uid _ _ _ shell; do
        [[ "$uid" -ge 1000 && "$shell" == "/bin/false" ]] || continue
        local exp_days
        exp_days=$(getent shadow "$uname" 2>/dev/null | cut -d: -f8)
        [[ -z "$exp_days" || ! "$exp_days" =~ ^[0-9]+$ ]] && continue
        (( exp_days < today_days )) && expired+=("$uname")
    done < <(sort -t: -k1,1 /etc/passwd)

    local total=${#expired[@]}
    if (( total == 0 )); then
        echo -e "${C_GREEN}${L_SU_EXPIRED_NONE}${C_NC}"
        pause; return
    fi

    echo -e "${C_YELLOW}${L_SU_EXPIRED_FOUND}${C_NC}"
    printf '  - %s\n' "${expired[@]}"
    echo
    read -p "$(echo "$L_SU_EXPIRED_CONFIRM" | sed "s/\\\$total/$total/g")" conf
    if ! [[ "$conf" =~ ^[sS]$ ]]; then
        fail "$L_SU_EXPIRED_NONE_REMOVED"
        pause; return
    fi

    local count=0
    for u in "${expired[@]}"; do
        ssh_remove_api "$u" > /dev/null 2>&1
        (( count++ ))
    done

    ok "$(echo "$L_SU_EXPIRED_DONE" | sed "s/\\\$count/$count/g")"
    pause
}

# ── Renovação interativa ──────────────────────────────────────

ssh_renew_user(){
    clear
    echo -e "${C_CYAN}== ${L_SU_RENEW_TITLE} ==${C_NC}"
    echo
    awk -F: '$3>=1000 && $7=="/bin/false" {print "  - "$1}' /etc/passwd | sort
    echo
    read -p "$L_SU_RENEW_USERNAME" user
    _user_exists "$user" || { fail "$(echo "$L_SU_DELETE_NOT_EXISTS" | sed "s/\$user/$user/g")"; pause; return; }
    read -p "$L_SU_RENEW_DAYS" days
    [[ ! "$days" =~ ^[0-9]+$ ]] && { fail "$L_SU_INVALID_DAYS"; pause; return; }

    ssh_renew_api "$user" "$days"
    local new_exp; new_exp=$(chage -l "$user" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
    ok "$L_SU_RENEW_DONE → $new_exp"
    pause
}

# ── Menu principal do módulo ──────────────────────────────────

ssh_users_menu(){
    while true; do
        clear
        local total online
        total=$(awk -F: '$3>=1000 && $7=="/bin/false"' /etc/passwd | wc -l)
        # conta processos de usuários com shell /bin/false (túneis SSH)
        online=0
        while IFS=: read -r uname _ uid _ _ _ shell; do
            [[ "$uid" -ge 1000 && "$shell" == "/bin/false" ]] || continue
            local p; p=$(_user_online "$uname")
            [[ "$p" -gt 0 ]] && (( online++ ))
        done < /etc/passwd

        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}                    ${L_SU_MENU_HEADER}                           ${C_CYAN}║${C_NC}"
        printf "${C_CYAN}║${C_NC}  ${L_SU_MENU_REGISTERED} ${C_GREEN}%-5s${C_NC}  ${L_SU_MENU_ONLINE} ${C_GREEN}%-5s${C_NC}                  ${C_CYAN}║${C_NC}\n" "$total" "$online"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo
        echo "  1) ${L_SU_MENU_OPT1}"
        echo "  2) ${L_SU_MENU_OPT2}"
        echo "  3) ${L_SU_MENU_OPT3}"
        echo "  4) ${L_SU_MENU_OPT4}"
        echo "  5) ${L_SU_MENU_OPT5}"
        echo -e "  6) ${C_YELLOW}${L_SU_MENU_OPT6}${C_NC}"
        echo -e "  7) ${C_RED}${L_SU_MENU_OPT7}${C_NC}"
        echo "  0) ${L_SU_MENU_OPT0}"
        echo
        read -p " $L_CHOICE" op
        case $op in
            1) ssh_create_user  ;;
            2) ssh_report       ;;
            3) ssh_online_users ;;
            4) ssh_delete_user  ;;
            5) ssh_renew_user   ;;
            6) ssh_delete_expired_users ;;
            7) ssh_delete_all_users ;;
            0) break ;;
            *) fail "$L_INVALID"; sleep 1 ;;
        esac
    done
}
