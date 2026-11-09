#!/bin/bash
#============================================================
# system_info.sh - informações do sistema (SO, CPU, RAM, portas)
#============================================================
source "$INSTALL_DIR/modules/common.sh"

# ── Sistema Operacional ────────────────────────────────────

_sys_os_pretty(){
    local pretty="" codename=""
    if [[ -f /etc/os-release ]]; then
        pretty=$(grep -m1 "^PRETTY_NAME=" /etc/os-release | cut -d= -f2- | tr -d '"')
        codename=$(grep -m1 "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2- | tr -d '"')
    fi
    [[ -z "$pretty" ]] && pretty="${L_SI_OS_UNKNOWN}"
    if [[ -n "$codename" ]]; then
        echo "$pretty - $codename"
    else
        echo "$pretty"
    fi
}

_sys_kernel(){ uname -r; }

_sys_virt(){
    if command -v systemd-detect-virt &>/dev/null; then
        local v; v=$(systemd-detect-virt 2>/dev/null)
        if [[ -z "$v" || "$v" == "none" ]]; then
            echo "${L_SI_OS_VIRT_NONE}"
        else
            echo "${v^^}"
        fi
    else
        echo "${L_SI_OS_VIRT_UNKNOWN}"
    fi
}

_sys_arch(){ uname -m; }

_sys_uptime(){
    local secs; secs=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    [[ -z "$secs" ]] && { echo "${L_SI_OS_NA}"; return; }
    eval "echo \"${L_SI_OS_UPTIME_FMT}\""
}

# ── Processador ─────────────────────────────────────────────

_sys_cpu_model(){
    local m; m=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')
    [[ -z "$m" ]] && m="${L_SI_CPU_UNKNOWN}"
    echo "$m"
}

_sys_cpu_cores(){ nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo; }

_sys_cpu_cache(){
    local c; c=$(grep -m1 "cache size" /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')
    [[ -z "$c" ]] && c="${L_SI_OS_NA}"
    echo "$c"
}

# uso de CPU em % (amostragem curta de /proc/stat, sem depender do "top")
_sys_cpu_usage(){
    local a b i
    read -r -a a < <(grep '^cpu ' /proc/stat)
    sleep 0.35
    read -r -a b < <(grep '^cpu ' /proc/stat)

    local prev_idle=$(( ${a[4]:-0} + ${a[5]:-0} ))
    local idle=$(( ${b[4]:-0} + ${b[5]:-0} ))
    local prev_total=0 total=0
    for i in 1 2 3 4 5 6 7 8; do
        prev_total=$(( prev_total + ${a[$i]:-0} ))
        total=$(( total + ${b[$i]:-0} ))
    done
    local diff_total=$(( total - prev_total ))
    local diff_idle=$(( idle - prev_idle ))
    if [[ "$diff_total" -le 0 ]]; then
        echo "0.0"
    else
        awk -v dt="$diff_total" -v di="$diff_idle" 'BEGIN{printf "%.1f", (dt-di)*100/dt}'
    fi
}

# ── Memória ─────────────────────────────────────────────────
# saída: total_gb|livre_gb|cache_gb|percentual_uso

_sys_mem_info(){
    local total avail cached used pct tg fg cg
    total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    cached=$(awk '/^Cached:/{print $2; exit}' /proc/meminfo)
    total=${total:-1}; avail=${avail:-0}; cached=${cached:-0}
    used=$(( total - avail ))
    pct=$(awk -v u="$used" -v t="$total" 'BEGIN{ if (t>0) printf "%.0f", (u*100/t); else print 0 }')
    tg=$(awk -v v="$total"  'BEGIN{printf "%.1f", v/1024/1024}')
    fg=$(awk -v v="$avail"  'BEGIN{printf "%.1f", v/1024/1024}')
    cg=$(awk -v v="$cached" 'BEGIN{printf "%.1f", v/1024/1024}')
    echo "${tg}|${fg}|${cg}|${pct}"
}

# ── Serviços em execução (portas abertas) ──────────────────
# saída: uma linha por serviço, "processo|porta", ordenada por porta

_sys_services(){
    if ! command -v ss &>/dev/null; then
        echo ""
        return
    fi
    { ss -tlnp 2>/dev/null; ss -ulnp 2>/dev/null; } | while IFS= read -r line; do
        [[ "$line" =~ ^(Netid|State) ]] && continue
        local addr port proc
        # "Local Address:Port" é sempre o 3º campo a partir do fim,
        # e "Process" o último — isso funciona com ou sem coluna Netid.
        addr=$(awk '{print $(NF-2)}' <<< "$line")
        [[ "$addr" != *:* ]] && continue
        port="${addr##*:}"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        proc=$(grep -oP 'users:\(\("\K[^"]+' <<< "$line" | head -1)
        [[ -z "$proc" ]] && proc="${L_SI_CPU_UNKNOWN,,}"
        echo "${proc}|${port}"
    done | sort -t'|' -k2 -n -u
}

# ── Tela principal ──────────────────────────────────────────

system_info_menu(){
    clear
    echo -e "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_NC}"
    echo -e "${C_CYAN}║${C_WHITE}                  ${L_SI_TITLE}                   ${C_CYAN}║${C_NC}"
    echo -e "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_NC}"
    echo

    echo -e "${C_WHITE}• ${L_SI_OS_SECTION} •${C_NC}"
    echo "${L_SI_OS_NAME}: $(_sys_os_pretty)"
    echo "${L_SI_OS_KERNEL}: $(_sys_kernel)"
    echo "${L_SI_OS_VIRT}: $(_sys_virt)"
    echo "${L_SI_OS_ARCH}: $(_sys_arch)"
    echo "${L_SI_OS_UPTIME}: $(_sys_uptime)"
    echo

    echo -e "${C_WHITE}• ${L_SI_CPU_SECTION} •${C_NC}"
    echo "${L_SI_CPU_MODEL}: $(_sys_cpu_model)"
    echo "${L_SI_CPU_CORES}: $(_sys_cpu_cores)"
    echo "${L_SI_CPU_CACHE}: $(_sys_cpu_cache)"
    echo "${L_SI_CPU_USAGE}: $(_sys_cpu_usage)%"
    echo

    local mem_data tg fg cg pct
    mem_data=$(_sys_mem_info)
    IFS='|' read -r tg fg cg pct <<< "$mem_data"
    echo -e "${C_WHITE}• ${L_SI_RAM_SECTION} •${C_NC}"
    echo "${L_SI_RAM_TOTAL}: ${tg} GB"
    echo "${L_SI_RAM_FREE}: ${fg} GB"
    echo "${L_SI_RAM_CACHE}: ${cg} GB"
    echo "${L_SI_RAM_USAGE}: ${pct}%"
    echo

    echo -e "${C_WHITE}• ${L_SI_SVC_SECTION} •${C_NC}"
    local svc_data; svc_data=$(_sys_services)
    if [[ -z "$svc_data" ]]; then
        echo -e "${C_YELLOW}${L_SI_SVC_NO_SS}${C_NC}"
    else
        while IFS='|' read -r proc port; do
            [[ -z "$proc" ]] && continue
            printf "${L_SI_SVC_NAME}: %-13s ${L_SI_SVC_PORT}: %s\n" "$proc" "$port"
        done <<< "$svc_data"
    fi

    echo
    read -n 1 -s -r -p "${L_SI_BACK}"
    echo
}
