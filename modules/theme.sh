#!/bin/bash
#============================================================
# theme.sh - tema unificado do VPNManager
# Fundo padrão do terminal; cor apenas nos elementos do menu.
#============================================================

# Fundo/base: fundo do terminal permanece o padrão.
# As cores são aplicadas apenas aos elementos do menu.
C_BG=''
C_BG_SOFT='\033[48;5;24m'     # disponível para destaque pontual
C_TEXT=''
C_RESET='\033[0m'

# C_NC apenas volta ao padrão do terminal, sem pintar o fundo.
C_NC="$C_RESET"

# Acentos
C_ORANGE='\033[38;5;208m'
C_AMBER='\033[38;5;214m'
C_BORDER='\033[1;34m'         # azul das bordas, estilo SSHPlus
C_BLUE="$C_BORDER"
C_CYAN='\033[1;36m'
C_WHITE='\033[1;38;5;255m'
C_GRAY='\033[38;5;245m'
C_DIM='\033[38;5;244m'

# Barra de titulo cheia, como no menu SSHPlus.
C_BAR='\033[44m'

# Status
C_GREEN='\033[38;5;120m'
C_YELLOW='\033[38;5;214m'
C_RED='\033[38;5;209m'

# Compatibilidade com os nomes usados no menu principal
C_BOLD='\033[1m'
C_LIGHTGREEN="$C_GREEN"
C_LIGHTRED="$C_RED"
C_LIGHTCYAN="$C_CYAN"

# Limpa a tela já aplicando o tema.
ui_clear(){
    printf '\033[H\033[2J\033[0m'
}

# Substitui o clear padrão em todos os módulos que carregam common.sh.
clear(){ ui_clear; }
