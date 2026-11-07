#!/bin/bash
APP_DIR="/root/pasarguard-deployer"
DOMAINS_FILE="$APP_DIR/domains.json"
NODES_FILE="$APP_DIR/nodes.json"
PRESETS_FILE="$APP_DIR/dns_presets.json"
BACKUP_DIR="$APP_DIR/backups"
LOG_FILE="$APP_DIR/deployer.log"

RST="\e[0m"
BOLD="\e[1m"
DIM="\e[2m"
C_RED="\e[38;5;196m"
C_GREEN="\e[38;5;48m"
C_YELLOW="\e[38;5;220m"
C_BLUE="\e[38;5;39m"
C_PURPLE="\e[38;5;141m"
C_CYAN="\e[38;5;51m"
C_WHITE="\e[38;5;255m"
C_GRAY="\e[38;5;244m"

ui_banner() {
    clear 2>/dev/null || true
    echo -e "${C_CYAN}╭────────────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██████╗  ██████╗${RST} ${BOLD}${C_PURPLE}██████╗ ███████╗██████╗ ██╗     ██████╗ ██╗    ██╗${RST}    ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██╔══██╗██╔════╝${RST} ${BOLD}${C_PURPLE}██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝${RST}    ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██████╔╝██║  ███╗${RST}${BOLD}${C_PURPLE}██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝ ${RST}    ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██╔═══╝ ██║   ██║${RST}${BOLD}${C_PURPLE}██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝  ${RST}    ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██║     ╚██████╔╝${RST}${BOLD}${C_PURPLE}██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║    ${RST}    ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${DIM}Automated DevOps by Saeed SK (@saeedsk32) v1.0 (Production)${RST}            ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}╰────────────────────────────────────────────────────────────────────────╯${RST}"
}

ui_sub_banner() {
    clear 2>/dev/null || true
    echo -e "${C_CYAN}┌────────────────────────────────────────────────────────────────────────┐${RST}"
    echo -e "${C_CYAN}│${RST} ${BOLD}${C_BLUE}PasarGuard Deployer${RST} ${C_GRAY}│ By Saeed SK (@saeedsk32) │${RST} ${C_GREEN}Active${RST}                     ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}└────────────────────────────────────────────────────────────────────────┘${RST}"
}

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "[$timestamp] [$level] $message" >> "$LOG_FILE"
    case "$level" in
        INFO)  echo -e "  ${C_BLUE}ℹ${RST} ${C_WHITE}$message${RST}" ;;
        OK)    echo -e "  ${C_GREEN}✔${RST} ${BOLD}${C_WHITE}$message${RST}" ;;
        WARN)  echo -e "  ${C_YELLOW}⚠${RST} ${C_YELLOW}$message${RST}" ;;
        ERROR) echo -e "  ${C_RED}✖${RST} ${BOLD}${C_RED}$message${RST}" ;;
    esac
}

init_db() {
    mkdir -p "$APP_DIR" "$BACKUP_DIR"
    [ ! -f "$DOMAINS_FILE" ] && echo '[]' > "$DOMAINS_FILE"
    [ ! -f "$NODES_FILE" ] && echo '[]' > "$NODES_FILE"
    if [ ! -f "$PRESETS_FILE" ] || [ "$(cat "$PRESETS_FILE" 2>/dev/null)" == "{}" ]; then
        echo '{"pool_main": ["pool1-1"]}' > "$PRESETS_FILE"
    fi
    touch "$LOG_FILE"
}

get_domains_count() {
    jq '. | length' "$DOMAINS_FILE" 2>/dev/null || echo 0
}
