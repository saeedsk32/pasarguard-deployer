#!/bin/bash
APP_DIR="/root/pasarguard-deployer"
cd "$APP_DIR" || exit 1
# ==============================================================================
# PasarGuard Multi-Node Auto-Deployer (Modular Production v1.0)
# Developed by Saeed SK (@saeedsk32)
# ==============================================================================

# Load all modules dynamically
for mod in modules/*.sh; do
    [ -f "$mod" ] && source "$mod"
done

init_db

while true; do
    ui_banner
    active_nodes_count=$(jq '. | length' "$NODES_FILE" 2>/dev/null || echo 0)
    active_domains_count=$(jq '. | length' "$DOMAINS_FILE" 2>/dev/null || echo 0)

    echo -e "  ${DIM}System Status:${RST} ${C_GREEN}Active${RST}   │  ${DIM}Nodes Registered:${RST} ${BOLD}$active_nodes_count${RST}   │  ${DIM}Domains Loaded:${RST} ${BOLD}$active_domains_count${RST}\n"
    echo -e "  ${BOLD}${C_CYAN}[1] 🚀 Node Management Center${RST}"
    echo -e "  ${BOLD}${C_CYAN}[2] 🌐 Domains & SSL Manager${RST}"
    echo -e "  ${BOLD}${C_CYAN}[3] ⚡ Cloudflare DNS Center${RST}"
    echo -e "  ${BOLD}${C_CYAN}[4] 💾 Backup & Restore Center${RST}"
    echo -e "  ${BOLD}${C_CYAN}[5] 📋 Diagnostics & Log Trace${RST}"
    echo -e "  ${BOLD}${C_GREEN}[6] 🌐 Web Dashboard Manager${RST}"
    echo -e "  ${BOLD}${C_GRAY}[0] 🚪 Exit${RST}"
    echo -e "\n${C_CYAN}────────────────────────────────────────────────────────────────────────${RST}"
    read -rp "$(echo -e "  ${C_PURPLE}▶ Select Module [0-6]: ${RST}")" MAIN_CHOICE < /dev/tty

    case "$MAIN_CHOICE" in
        1) echo -e "\n${C_YELLOW}Node management module loading...${RST}"; read -rp "Press [ENTER]..." < /dev/tty ;;
        2) domains_ssl_menu ;;
        3) cloudflare_dns_center ;;
        4) backup_restore_center ;;
        5) view_logs ;;
        6) web_panel_menu ;;
        0) echo -e "\n  ${C_GREEN}Goodbye!${RST}\n"; exit 0 ;;
        *) ;;
    esac
done
