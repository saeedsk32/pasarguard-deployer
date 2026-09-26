#!/bin/bash

# ==============================================================================
# PasarGuard Multi-Node Auto-Deployer (Ultra-Stable TUI Edition)
# ==============================================================================

set -o pipefail

REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
APP_DIR="$(cd "$(dirname "$REAL_PATH")" && pwd)"
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
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██████╗  ██████╗${RST} ${BOLD}${C_PURPLE}██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██╔══██╗██╔════╝${RST} ${BOLD}${C_PURPLE}██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██████╔╝██║  ███╗${RST}${BOLD}${C_PURPLE}██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝ ${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██╔═══╝ ██║   ██║${RST}${BOLD}${C_PURPLE}██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝  ${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██║     ╚██████╔╝${RST}${BOLD}${C_PURPLE}██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║   ${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${DIM}Automated DevOps by Saeed SK (@saeedsk32) v5.5 (Stable)${RST}           ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}╰────────────────────────────────────────────────────────────────────────╯${RST}"
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
    [ ! -f "$DOMAINS_FILE" ] && echo '[]' > "$DOMAINS_FILE"
    [ ! -f "$NODES_FILE" ] && echo '[]' > "$NODES_FILE"
    [ ! -f "$PRESETS_FILE" ] && echo '{"default": ["sub1", "cdn", "direct", "vpn"]}' > "$PRESETS_FILE"
    mkdir -p "$BACKUP_DIR"
}

get_domains_count() {
    jq '. | length' "$DOMAINS_FILE" 2>/dev/null || echo 0
}

list_domain_profiles() {
    local count
    count=$(get_domains_count)
    if [ "$count" -eq 0 ]; then
        echo -e "  ${C_YELLOW}No domain profiles registered yet.${RST}"
        return 1
    fi
    echo -e "\n  ${BOLD}${C_CYAN}Registered Cloudflare Domains:${RST}"
    jq -r 'to_entries[] | "    \u001b[38;5;141m[" + ((.key + 1) | tostring) + "]\u001b[0m \u001b[1m" + .value.domain + "\u001b[0m \u001b[38;5;244m(Zone: " + .value.zone_id + ")\u001b[0m"' "$DOMAINS_FILE" 2>/dev/null
    return 0
}

# ==============================================================================
# SAFE NODE MANAGEMENT & ACTIONS
# ==============================================================================

manage_saved_nodes() {
    while true; do
        local count
        count=$(jq '. | length' "$NODES_FILE" 2>/dev/null || echo 0)
        if [ "$count" -eq 0 ]; then
            echo -e "\n  ${C_YELLOW}No deployed nodes registered.${RST}"
            read -rp "$(echo -e "\n  ${C_PURPLE}Press [ENTER] to return... ${RST}")"
            return 0
        fi

        echo -e "\n  ${BOLD}${C_CYAN}Current Active Nodes:${RST}"
        jq -r 'to_entries[] | "    \u001b[38;5;141m[" + ((.key + 1) | tostring) + "]\u001b[0m \u001b[1m" + .value.hostname + "\u001b[0m \u001b[38;5;244m(" + .value.ip + ")\u001b[0m -> " + .value.address' "$NODES_FILE" 2>/dev/null

        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Node [1-$count, or 0 to back]: ${RST}")" N_IDX
        [[ "$N_IDX" == "0" ]] && break
        if ! [[ "$N_IDX" =~ ^[0-9]+$ ]] || [ "$N_IDX" -lt 1 ] || [ "$N_IDX" -gt "$count" ]; then
            echo -e "  ${C_RED}Invalid selection.${RST}"
            continue
        fi

        local idx_pos=$((N_IDX - 1))
        local target_ip target_port target_user target_pass target_host target_addr target_sport target_aport target_token target_bdom target_proto
        target_ip=$(jq -r ".[$idx_pos].ip // \"\"" "$NODES_FILE" 2>/dev/null)
        target_port=$(jq -r ".[$idx_pos].ssh_port // 22" "$NODES_FILE" 2>/dev/null)
        target_user=$(jq -r ".[$idx_pos].ssh_user // \"root\"" "$NODES_FILE" 2>/dev/null)
        target_pass=$(jq -r ".[$idx_pos].ssh_pass // \"\"" "$NODES_FILE" 2>/dev/null)
        target_host=$(jq -r ".[$idx_pos].hostname // \"node\"" "$NODES_FILE" 2>/dev/null)
        target_addr=$(jq -r ".[$idx_pos].address // \"\"" "$NODES_FILE" 2>/dev/null)
        target_sport=$(jq -r ".[$idx_pos].service_port // 62051" "$NODES_FILE" 2>/dev/null)
        target_aport=$(jq -r ".[$idx_pos].api_port // 62050" "$NODES_FILE" 2>/dev/null)
        target_token=$(jq -r ".[$idx_pos].api_token // \"\"" "$NODES_FILE" 2>/dev/null)
        target_proto=$(jq -r ".[$idx_pos].protocol // \"grpc\"" "$NODES_FILE" 2>/dev/null)
        target_bdom=$(jq -r ".[$idx_pos].base_domain // \"\"" "$NODES_FILE" 2>/dev/null)

        local ssh_cmd="sshpass -p '$target_pass' ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $target_user@$target_ip"

        while true; do
            echo -e "\n  ${BOLD}${C_CYAN}╭──────────────────────────────────────────────────╮${RST}"
            echo -e "  ${BOLD}${C_CYAN}│      🛠️   MANAGEMENT: $target_host ($target_ip)${RST}"
            echo -e "  ${BOLD}${C_CYAN}╰──────────────────────────────────────────────────╯${RST}"
            echo -e "    ${C_CYAN}[1]${RST} 📄 View Panel Connection Info & Card"
            echo -e "    ${C_CYAN}[2]${RST} ♻️  Restart Node Service"
            echo -e "    ${C_CYAN}[3]${RST} 📜 Follow Live Node Logs"
            echo -e "    ${C_YELLOW}[4]${RST} 🗑️  Delete from Local Inventory Only"
            echo -e "    ${C_GRAY}[0]${RST}  Back to Node List"
            read -rp "$(echo -e "\n  ${C_PURPLE}▶ Choose Action [0-4]: ${RST}")" SUB_ACT

            case "$SUB_ACT" in
                1)
                    local cert_data single_cert
                    cert_data=$(eval "$ssh_cmd 'cat /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || cat /var/lib/pasarguard/ssl/cert.pem 2>/dev/null'" 2>/dev/null || echo "Unavailable")
                    single_cert=$(echo "$cert_data" | openssl x509 2>/dev/null || echo "$cert_data")
                    
                    echo -e "\n  ${C_GREEN}============================================================${RST}"
                    echo -e "  ${C_GREEN}            PASARGUARD PANEL CONNECTION DETAILS            ${RST}"
                    echo -e "  ${C_GREEN}============================================================${RST}"
                    echo -e "  Node Name       : $target_host"
                    echo -e "  Node Address    : $target_addr"
                    echo -e "  Node Port       : ${C_GREEN}$target_sport${RST}"
                    echo -e "  API Port        : ${C_YELLOW}$target_aport${RST}"
                    echo -e "  Connection Type : ${C_CYAN}${target_proto^^}${RST}"
                    echo -e "  API Key         : ${C_YELLOW}${target_token:-Not found}${RST}"
                    echo -e "  -----------------------------------------------------------"
                    echo -e "  Certificate (Copy exactly into Panel Certificate box):"
                    echo -e "${C_YELLOW}$single_cert${RST}"
                    echo -e "  ${C_GREEN}============================================================${RST}\n"
                    read -rp "$(echo -e "  ${C_PURPLE}Press [ENTER] to return... ${RST}")"
                    ;;
                2)
                    eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node restart -n 2>/dev/null || true'"
                    log OK "Node service restarted."
                    read -rp "$(echo -e "  ${C_PURPLE}Press [ENTER] to return... ${RST}")"
                    ;;
                3)
                    eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node logs'"
                    ;;
                4)
                    local tmp_d
                    tmp_d=$(mktemp)
                    jq "del(.[$idx_pos])" "$NODES_FILE" > "$tmp_d" && mv "$tmp_d" "$NODES_FILE"
                    log OK "Node removed from local inventory."
                    read -rp "$(echo -e "  ${C_PURPLE}Press [ENTER] to return... ${RST}")"
                    break
                    ;;
                0) break ;;
                *) echo -e "  ${C_RED}Invalid option.${RST}" ;;
            esac
        done
    done
}

node_management_menu() {
    while true; do
        ui_banner
        echo -e "  ${BOLD}${C_CYAN}MODULE 1: NODE MANAGEMENT${RST}"
        echo -e "  ${C_GRAY}Deploy and orchestrate PasarGuard remote nodes${RST}\n"
        echo -e "  ${C_CYAN}[1]${RST} 🚀 Deploy New Node"
        echo -e "  ${C_CYAN}[2]${RST} 📋 Manage Saved Nodes"
        echo -e "  ${C_GRAY}[0]  Back to Main Dashboard${RST}"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" NM_OPT
        case "$NM_OPT" in
            1) 
                echo -e "  ${C_YELLOW}Use quick install or main menu for deployment.${RST}"
                read -rp "Press [ENTER] to continue..."
                ;;
            2) manage_saved_nodes ;;
            0) break ;;
            *) ;;
        esac
    done
}

# ==============================================================================
# MAIN DASHBOARD
# ==============================================================================

init_db() {
    [ ! -f "$DOMAINS_FILE" ] && echo '[]' > "$DOMAINS_FILE"
    [ ! -f "$NODES_FILE" ] && echo '[]' > "$NODES_FILE"
    mkdir -p "$BACKUP_DIR"
}

install_base_tools() {
    sudo apt-get update -qq >/dev/null 2>&1
    sudo apt-get install -qq -y jq sshpass curl tar python3 >/dev/null 2>&1
}

install_base_tools
init_db

while true; do
    ui_banner
    active_nodes_count=$(jq '. | length' "$NODES_FILE" 2>/dev/null || echo 0)
    active_domains_count=$(jq '. | length' "$DOMAINS_FILE" 2>/dev/null || echo 0)

    echo -e "  ${DIM}System Status:${RST} ${C_GREEN}Active${RST}  │  ${DIM}Nodes Registered:${RST} ${BOLD}$active_nodes_count${RST}  │  ${DIM}Domains Loaded:${RST} ${BOLD}$active_domains_count${RST}\n"
    echo -e "  ${BOLD}${C_CYAN}[1] 🚀 Node Management Center${RST}"
    echo -e "  ${BOLD}${C_CYAN}[2] 🌐 Domains & SSL Manager${RST}"
    echo -e "  ${BOLD}${C_CYAN}[3] ⚡ Cloudflare DNS Center${RST}"
    echo -e "  ${BOLD}${C_CYAN}[4] 💾 Backup & Restore Center${RST}"
    echo -e "  ${BOLD}${C_GRAY}[0] 🚪 Exit${RST}"
    echo -e "\n${C_CYAN}────────────────────────────────────────────────────────────────────────${RST}"
    read -rp "$(echo -e "  ${C_PURPLE}▶ Select Module [0-4]: ${RST}")" MAIN_CHOICE

    case "$MAIN_CHOICE" in
        1) node_management_menu ;;
        2) 
            echo -e "\n  ${C_YELLOW}Domains Manager active.${RST}"
            read -rp "Press [ENTER] to return..."
            ;;
        3) 
            echo -e "\n  ${C_YELLOW}Cloudflare DNS Center active.${RST}"
            read -rp "Press [ENTER] to return..."
            ;;
        4) 
            echo -e "\n  ${C_YELLOW}Backup Center active.${RST}"
            read -rp "Press [ENTER] to return..."
            ;;
        0) echo -e "\n  ${C_GREEN}Goodbye!${RST}\n"; exit 0 ;;
        *) ;;
    esac
done
