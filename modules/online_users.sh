#!/bin/bash
#============================================================
# online_users.sh - usuários SSH online em tempo real
#============================================================
source "$INSTALL_DIR/modules/common.sh"

PM_DB="/root/pm_users.db"

# API local do Xray (ativa em /usr/local/etc/xray/config.json).
XRAY_API="127.0.0.1:8099"

_xray_api(){
    command -v xray >/dev/null 2>&1 || return 1
    xray api "$@" --server="$XRAY_API" 2>/dev/null
}

# Quantidade de usuários Xray/VLESS online (uma única chamada à API).
_xray_online_count(){
    local n
    n=$(_xray_api statsgetallonlineusers \
        | jq -r '.users | length // 0' 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# Usuários Xray/VLESS online: nome|IPs|sessões.
_xray_online_list(){
    local names u sess ips
    names=$(_xray_api statsgetallonlineusers \
        | jq -r '.users[]? | sub("^user>>>"; "") | sub(">>>online$"; "")' 2>/dev/null) || return 0
    [[ -z "$names" ]] && return 0

    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        sess=$(_xray_api statsonline -email "$u" | jq -r '.stat.value // 0' 2>/dev/null)
        ips=$(_xray_api statsonlineiplist -email "$u" | jq -r '.ips | keys | join(",")' 2>/dev/null)
        [[ -z "$sess" ]] && sess=0
        [[ -z "$ips" ]] && ips="-"
        printf '%s|%s|%s\n' "$u" "$ips" "$sess"
    done <<< "$names"
}

_short_ips(){
    local ips="$1" max="${2:-26}"
    if (( ${#ips} > max )); then
        printf '%s...' "${ips:0:max-3}"
    else
        printf '%s' "$ips"
    fi
}

# conta processos sshd do usuário (o mesmo que aparece filtrando "sshd" no htop)
_count_procs(){ pgrep -u "$1" -x sshd 2>/dev/null | wc -l | tr -d ' '; }

# tenta extrair IPs das conexões do usuário via ss
_get_ips(){
    local u="$1"
    ss -tnp 2>/dev/null \
        | awk -v u="$u" '$0 ~ "\"" u "\"" {print $5}' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -u | tr '\n' ',' | sed 's/,$//'
}

online_list(){
    local results=() total_on=0

    while IFS=: read -r uname _ uid _ _ _ shell; do
        [[ "$uid" -lt 1000 || "$shell" != "/bin/false" ]] && continue
        local procs; procs=$(_count_procs "$uname")
        [[ "$procs" -eq 0 ]] && continue
        (( total_on++ ))
        local limit exp ips
        limit=$(grep "^$uname " "$PM_DB" 2>/dev/null | awk '{print $2}')
        [[ -z "$limit" || "$limit" == "0" ]] && limit="∞"
        exp=$(chage -l "$uname" 2>/dev/null \
            | grep "Account expires" | cut -d: -f2 | xargs)
        [[ -z "$exp" || "$exp" == "never" ]] && exp="${L_SU_NEVER}"
        ips=$(_get_ips "$uname")
        [[ -z "$ips" ]] && ips="-"
        results+=("$uname|$procs|$limit|$exp|$ips")
    done < /etc/passwd

    echo "$total_on"
    printf '%s\n' "${results[@]}"
}

online_users_menu(){
    while true; do
        clear
        echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
        echo -e "${C_CYAN}║${C_WHITE}                   ${L_OL_TITLE}                   ${C_CYAN}║${C_NC}"
        echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
        echo

        local data; mapfile -t data < <(online_list)
        local total="${data[0]:-0}"

        if [[ "$total" -eq 0 ]]; then
            echo -e "  ${C_YELLOW}${L_OL_NONE}${C_NC}"
        else
            echo -e "  ${L_OL_CONNECTED} ${C_GREEN}$total${C_NC}"
            echo
            printf "  %-18s %5s %6s %-12s %s\n" \
                "${L_OL_HEADER_USER}" "${L_OL_HEADER_CONN}" "${L_OL_HEADER_LIMIT}" "${L_OL_HEADER_EXP}" "${L_OL_HEADER_IP}"
            echo "  ────────────────────────────────────────────────────────"
            for row in "${data[@]:1}"; do
                IFS='|' read -r u procs limit exp ips <<< "$row"
                printf "  ${C_GREEN}%-18s${C_NC} %5s %6s %-12s %s\n" \
                    "$u" "$procs" "$limit" "$exp" "$ips"
            done
        fi

        # Usuários online no Xray (VLESS). O V2Ray, quando instalado, usa a mesma API.
        echo
        if command -v xray >/dev/null 2>&1 && systemctl is-active --quiet xray; then
            local xdata; mapfile -t xdata < <(_xray_online_list)
            local xtotal=${#xdata[@]}
            echo -e "  ${C_CYAN}Xray/VLESS${C_NC} - ${L_OL_CONNECTED} ${C_GREEN}$xtotal${C_NC}"
            if (( xtotal > 0 )); then
                echo
                printf "  %-20s %-26s %5s\n" \
                    "${L_OL_HEADER_USER}" "${L_OL_HEADER_IP}" "SESS"
                echo "  ────────────────────────────────────────────────────────"
                for row in "${xdata[@]}"; do
                    IFS='|' read -r u ips sess <<< "$row"
                    printf "  ${C_GREEN}%-20s${C_NC} %-26s %5s\n" "$u" "$(_short_ips "$ips" 26)" "$sess"
                done
            else
                echo -e "  ${C_YELLOW}${L_OL_NONE}${C_NC}"
            fi
        fi

        echo
        echo "  1) ${L_OL_OPT_REFRESH}"
        echo "  2) ${L_OL_OPT_KICK}"
        echo "  0) ${L_OL_OPT_BACK}"
        echo
        read -p " ${L_CHOICE}" op
        case $op in
            1) continue ;;
            2)
                read -p " ${L_OL_KICK_PROMPT}" uname
                if getent passwd "$uname" > /dev/null 2>&1; then
                    pkill -KILL -u "$uname" 2>/dev/null && \
                        ok "${L_OL_KICK_OK}" || \
                        echo -e "${C_YELLOW}${L_OL_KICK_NONE}${C_NC}"
                else
                    fail "${L_OL_KICK_NOT_EXISTS}"
                fi
                sleep 2
                ;;
            0) break ;;
            *) fail "${L_OL_INVALID}"; sleep 1 ;;
        esac
    done
}
