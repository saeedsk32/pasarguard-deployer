#!/bin/bash

# ==============================================================================
# PasarGuard Multi-Node Auto-Deployer (v6.5 - Master Infrastructure Edition)
# Developed by Saeed SK (@saeedsk32)
# ==============================================================================

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
    echo -e "${C_CYAN}│${RST}  ${DIM}Automated DevOps by Saeed SK (@saeedsk32) v6.5 (Production)${RST}           ${C_CYAN}│${RST}"
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

if [ -f "$PRESETS_FILE" ]; then
    if jq -e 'has("main") and has("pool_main")' "$PRESETS_FILE" >/dev/null 2>&1; then
        tmp_clean=$(mktemp)
        jq 'del(.main)' "$PRESETS_FILE" > "$tmp_clean" && mv "$tmp_clean" "$PRESETS_FILE"
    fi
fi

    [ ! -f "$DOMAINS_FILE" ] && echo '[]' > "$DOMAINS_FILE"
    [ ! -f "$NODES_FILE" ] && echo '[]' > "$NODES_FILE"
    if [ ! -f "$PRESETS_FILE" ] || [ "$(cat "$PRESETS_FILE")" == "{}" ]; then
        echo '{"pool_main": ["pool1-1"]}' > "$PRESETS_FILE"
    fi
    mkdir -p "$BACKUP_DIR"
    touch "$LOG_FILE"
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

upsert_cloudflare_dns() {
    local zid="$1" tok="$2" name="$3" ip="$4" comment="$5"
    local type="A"
    [[ "$ip" == *:* ]] && type="AAAA"

    local rec_id
    rec_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zid/dns_records?name=$name&type=$type&content=$ip" \
         -H "Authorization: Bearer $tok" -H "Content-Type: application/json" | jq -r '.result[0].id // empty' 2>/dev/null)

    if [ -n "$rec_id" ]; then
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zid/dns_records/$rec_id" \
             -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
             --data "{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$ip\",\"ttl\":1,\"proxied\":false,\"comment\":\"$comment\"}" >/dev/null
        log OK "DNS Record Verified: $name -> $ip"
    else
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zid/dns_records" \
             -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
             --data "{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$ip\",\"ttl\":1,\"proxied\":false,\"comment\":\"$comment\"}" >/dev/null
        log OK "Created DNS Record: $name -> $ip [$comment]"
    fi
}

toggle_node_bbr() {
    local ip="$1" port="$2" user="$3" pass="$4" host="$5"
    local ssh_c="sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$NODE_SSH_USER@$NODE_IP"         "curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh -o /tmp/pg-node.sh && chmod +x /tmp/pg-node.sh && /tmp/pg-node.sh install $proto_flag --service-port $NODE_PORT --api-port $API_PORT --api-key $generated_api_key --cert-path /var/lib/pg-node/certs/ssl_cert.pem --key-path /var/lib/pg-node/certs/ssl_key.pem -y"

    sleep 2
    # اطمینان از استخراج قطعی توکن
    local token_extracted
    token_extracted=$(sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$NODE_SSH_USER@$NODE_IP" \
        "grep -oE '[0-9a-fA-F-]{36}' /opt/pg-node/.env 2>/dev/null || grep -oE '[0-9a-fA-F-]{36}' /etc/systemd/system/pg-node.service 2>/dev/null || echo '$generated_api_key'" | head -n 1)
    token_extracted=${token_extracted:-$generated_api_key}

    local node_json_entry
    node_json_entry=$(jq -n \
        --arg h "$NODE_HOST" \
        --arg ip "$NODE_IP" \
        --arg addr "$fqdn" \
        --arg sport "$NODE_PORT" \
        --arg aport "$API_PORT" \
        --arg proto "$proto_str" \
        --arg tok "$token_extracted" \
        --arg bdom "$base_domain" \
        --arg upass "$NODE_SSH_PASS" \
        --arg uport "$NODE_SSH_PORT" \
        --arg uusr "$NODE_SSH_USER" \
        '{hostname: $h, ip: $ip, address: $addr, service_port: ($sport|tonumber), api_port: ($aport|tonumber), protocol: $proto, api_token: $tok, base_domain: $bdom, ssh_pass: $upass, ssh_port: ($uport|tonumber), ssh_user: $uusr, dns_records: [], ssl_domains: [$bdom]}')

    for r in "${dns_recs_array[@]}"; do
        node_json_entry=$(echo "$node_json_entry" | jq --arg rec "$r" '.dns_records += [$rec]')
    done

    local tmp_n; tmp_n=$(mktemp)
    jq --argjson newnode "$node_json_entry" '. += [$newnode]' "$NODES_FILE" > "$tmp_n" && mv "$tmp_n" "$NODES_FILE"

    log OK "Node successfully deployed and registered!"
    read -rp "  Press [ENTER] to return to dashboard..." < /dev/tty
}

manage_saved_nodes() {
    while true; do
        ui_sub_banner
        local count; count=$(jq '. | length' "$NODES_FILE" 2>/dev/null || echo 0)
        if [ "$count" -eq 0 ]; then
            echo -e "\n  ${C_YELLOW}No deployed nodes registered.${RST}"
            read -rp "  Press [ENTER] to return..." < /dev/tty
            return 0
        fi

        echo -e "\n  ${BOLD}${C_CYAN}Current Active Nodes:${RST}"
        jq -r 'to_entries[] | "    \u001b[38;5;141m[" + ((.key + 1) | tostring) + "]\u001b[0m \u001b[1m" + .value.hostname + "\u001b[0m \u001b[38;5;244m(" + .value.ip + ")\u001b[0m -> " + .value.address' "$NODES_FILE" 2>/dev/null

        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Node [1-$count, or 0 to back]: ${RST}")" N_IDX < /dev/tty
        [[ "$N_IDX" == "0" ]] && break
        if ! [[ "$N_IDX" =~ ^[0-9]+$ ]] || [ "$N_IDX" -lt 1 ] || [ "$N_IDX" -gt "$count" ]; then
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
        target_sport=$(jq -r ".[$idx_pos].service_port // 62050" "$NODES_FILE" 2>/dev/null)
        target_aport=$(jq -r ".[$idx_pos].api_port // 62051" "$NODES_FILE" 2>/dev/null)
        target_token=$(jq -r ".[$idx_pos].api_token // \"\"" "$NODES_FILE" 2>/dev/null)
        target_proto=$(jq -r ".[$idx_pos].protocol // \"grpc\"" "$NODES_FILE" 2>/dev/null)
        target_bdom=$(jq -r ".[$idx_pos].base_domain // \"\"" "$NODES_FILE" 2>/dev/null)

        local ssh_cmd="sshpass -p '$target_pass' ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $target_user@$target_ip"

        while true; do
            ui_sub_banner
            
            # بررسی وضعیت BBR
            local bbr_status="${C_GRAY}Unknown${RST}"
            local active_cc
            active_cc=$(sshpass -p "$target_pass" ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 "$target_user@$target_ip" "sysctl -n net.ipv4.tcp_congestion_control" 2>/dev/null)
            if [[ "$active_cc" == *"bbr"* ]]; then
                bbr_status="${C_GREEN}● Active (BBR + FQ)${RST}"
            elif [ -n "$active_cc" ]; then
                bbr_status="${C_YELLOW}○ Inactive ($active_cc)${RST}"
            else
                bbr_status="${C_RED}✖ Unreachable${RST}"
            fi

            # وضعیت پورت و لایو بودن سرویس
            local panel_status="${C_GREEN}● Online (API Listening)${RST}"
            local port_check
            port_check=$(sshpass -p "$target_pass" ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 "$target_user@$target_ip" "ss -tlpn | grep -q $target_aport && echo OK || echo FAIL" 2>/dev/null)
            if [ "$port_check" != "OK" ]; then
                panel_status="${C_YELLOW}○ Standby / Checking${RST}"
            fi

            # خواندن گواهی
            local _remote_cert _leaf_cert
            _remote_cert=$(sshpass -p "$target_pass" ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 "$target_user@$target_ip" "cat /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || cat /var/lib/pasarguard/ssl/cert.pem 2>/dev/null" 2>/dev/null || true)
            if [ -n "$_remote_cert" ]; then
                _leaf_cert=$(echo "$_remote_cert" | openssl x509 2>/dev/null || echo "$_remote_cert")
            else
                _leaf_cert="(Certificate not found on remote node)"
            fi

            # نمایش مستقیم کارت نود
            echo -e "  ${C_GREEN}╭────────────────────────────────────────────────────────────────────────╮${RST}"
            echo -e "  ${C_GREEN}│         PASARGUARD PANEL CONNECTION DETAILS                            │${RST}"
            echo -e "  ${C_GREEN}├────────────────────────────────────────────────────────────────────────┤${RST}"
            printf "  ${C_GREEN}│${RST}  Node Name            : %-46s ${C_GREEN}│${RST}\n" "$target_host"
            printf "  ${C_GREEN}│${RST}  Node Address         : %-46s ${C_GREEN}│${RST}\n" "$target_addr"
            printf "  ${C_GREEN}│${RST}  Node Port            : %-46s ${C_GREEN}│${RST}\n" "$target_sport"
            printf "  ${C_GREEN}│${RST}  API Port             : %-46s ${C_GREEN}│${RST}\n" "$target_aport"
            printf "  ${C_GREEN}│${RST}  Connection Type      : %-46s ${C_GREEN}│${RST}\n" "${target_proto^^}"
            printf "  ${C_GREEN}│${RST}  Panel Service Link   : %-55b ${C_GREEN}│${RST}\n" "$panel_status"
            printf "  ${C_GREEN}│${RST}  TCP BBR Engine       : %-55b ${C_GREEN}│${RST}\n" "$bbr_status"
            printf "  ${C_GREEN}│${RST}  API Key              : %-46s ${C_GREEN}│${RST}\n" "${target_token:-Not detected}"
            echo -e "  ${C_GREEN}├────────────────────────────────────────────────────────────────────────┤${RST}"
            echo -e "  ${C_GREEN}│  Cloudflare DNS Records:                                               │${RST}"
            while IFS= read -r drec; do
                if [ -n "$drec" ]; then
                    printf "  ${C_GREEN}│${RST}   • %-66s ${C_GREEN}│${RST}\n" "$drec"
                fi
            done < <(jq -r ".[$idx_pos].dns_records[]? // empty" "$NODES_FILE" 2>/dev/null)
            echo -e "  ${C_GREEN}├────────────────────────────────────────────────────────────────────────┤${RST}"
            echo -e "  ${C_GREEN}│  SSL Certificate (Leaf / <2048 chars for Panel):                       │${RST}"
            echo -e "  ${C_GREEN}╰────────────────────────────────────────────────────────────────────────╯${RST}"
            echo -e "${C_YELLOW}$_leaf_cert${RST}\n"

            echo -e "  ${BOLD}${C_BLUE}⚡ ORCHESTRATOR & INFRASTRUCTURE ACTIONS:${RST}"
            echo -e "    ${C_PURPLE}[1]${RST}  🔁 1-Click Server IP Migration (Auto CF DNS)"
            echo -e "    ${C_PURPLE}[2]${RST}  🌐 Cloudflare DNS Center (Add / Edit / Delete Records)"
            echo -e "    ${C_PURPLE}[3]${RST}  🔐 Inject / Sync Multi-Domain Wildcard SSLs"
            echo -e "    ${C_PURPLE}[4]${RST}  🚀 Toggle / Tune TCP BBR Congestion Control"

            echo -e "\n  ${BOLD}${C_GREEN}🔧 PG-NODE CORE ACTIONS (Remote Binary Hooks):${RST}"
            echo -e "    ${C_GREEN}[5]${RST}  ♻️  Restart Node Service"
            echo -e "    ${C_GREEN}[6]${RST}  📜 Follow Live Node Logs (Ctrl+C to exit)"
            echo -e "    ${C_GREEN}[7]${RST}  ⚡ Switch Protocol (gRPC <-> REST)"
            echo -e "    ${C_GREEN}[8]${RST}  ⚙️  Manage Systemd Service"
            echo -e "    ${C_GREEN}[9]${RST}  📦 Update / Change Xray-core"
            echo -e "    ${C_GREEN}[10]${RST} 🔄 Update PasarGuard Node Software"
            echo -e "    ${C_GREEN}[11]${RST} 🗺️  Update GeoFiles (GeoIP & GeoSite)"
            echo -e "    ${C_GREEN}[14]${RST} 🔑 Set / Regenerate Node API Key"
            echo -e "    ${C_GREEN}[15]${RST} 🔌 Reconfigure Ports (Service & API)"

            echo -e "\n  ${BOLD}${C_RED}🗑️  DELETION & CLEANUP:${RST}"
            echo -e "    ${C_GRAY}[12]${RST} 🗑️  Delete from Local Inventory Only"
            echo -e "    ${C_RED}[13]${RST} 💣 Completely Uninstall Node & Clean DNS"
            echo -e "    ${C_GRAY}[0]${RST}   🔙 Back to Node List"

            read -rp "$(echo -e "\n  ${C_PURPLE}▶ Choose Action [0-15]: ${RST}")" N_ACT < /dev/tty

            case "$N_ACT" in
                1)
                    read -rp "  ▶ Enter NEW Server IPv4: " NEW_NODE_IP < /dev/tty
                    if [ -n "$NEW_NODE_IP" ]; then
                        local c_tok c_zid
                        c_tok=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .token' "$DOMAINS_FILE")
                        c_zid=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .zone_id' "$DOMAINS_FILE")
                        upsert_cloudflare_dns "$c_zid" "$c_tok" "$target_addr" "$NEW_NODE_IP" "PG-Node: $target_host | Migrated"
                        local tmp_m; tmp_m=$(mktemp)
                        jq --arg n "$idx_pos" --arg nip "$NEW_NODE_IP" '.[($n|tonumber)].ip = $nip' "$NODES_FILE" > "$tmp_m" && mv "$tmp_m" "$NODES_FILE"
                        target_ip="$NEW_NODE_IP"
                        log OK "Node IP updated to $NEW_NODE_IP"
                    fi
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                2)
                    manage_node_dns_center "$idx_pos"
                    ;;
                3)
                    list_domain_profiles
                    local dc; dc=$(get_domains_count)
                    read -rp "  ▶ Select Domain profile to inject SSL [1-$dc]: " INJ_D < /dev/tty
                    if [[ "$INJ_D" =~ ^[0-9]+$ ]] && [ "$INJ_D" -ge 1 ] && [ "$INJ_D" -le "$dc" ]; then
                        local inj_dom; inj_dom=$(jq -r ".[$((INJ_D - 1))].domain" "$DOMAINS_FILE")
                        if [ -f "/etc/letsencrypt/live/$inj_dom/fullchain.pem" ]; then
                            sshpass -p "$target_pass" ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$target_user@$target_ip" "mkdir -p /var/lib/pg-node/certs/$inj_dom"
                            sshpass -p "$target_pass" scp -P $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "/etc/letsencrypt/live/$inj_dom/fullchain.pem" "$target_user@$target_ip:/var/lib/pg-node/certs/$inj_dom/" >/dev/null
                            sshpass -p "$target_pass" scp -P $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "/etc/letsencrypt/live/$inj_dom/privkey.pem" "$target_user@$target_ip:/var/lib/pg-node/certs/$inj_dom/" >/dev/null
                            log OK "Injected $inj_dom SSL into remote node."
                        fi
                    fi
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                4)
                    toggle_node_bbr "$target_ip" "$target_port" "$target_user" "$target_pass" "$target_host"
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                5)
                    eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node restart -y 2>/dev/null || true'"
                    log OK "Node service restarted."
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                6)
                    eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node logs'"
                    ;;
                7)
                    local new_proto="rest"
                    [ "$target_proto" == "rest" ] && new_proto="grpc"
                    read -rp "  Switch protocol from $target_proto to $new_proto? [y/N]: " CONF_SW < /dev/tty
                    if [[ "$CONF_SW" =~ ^[yY]$ ]]; then
                        local sw_flag="--use-grpc"
                        [ "$new_proto" == "rest" ] && sw_flag="--use-rest"
                        eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node protocol $sw_flag 2>/dev/null || true'"
                        local tmp_p; tmp_p=$(mktemp)
                        jq --arg n "$idx_pos" --arg pr "$new_proto" '.[($n|tonumber)].protocol = $pr' "$NODES_FILE" > "$tmp_p" && mv "$tmp_p" "$NODES_FILE"
                        target_proto="$new_proto"
                        log OK "Protocol switched to $new_proto."
                    fi
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                8)
                    eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node service'"
                    ;;
                9)
                    eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node xray'"
                    ;;
                10)
                    eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node update -y 2>/dev/null || true'"
                    log OK "PasarGuard node software update triggered."
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                11)
                    eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node geo -y 2>/dev/null || true'"
                    log OK "GeoFiles updated on remote node."
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                14)
                    read -rp "  ▶ Enter New API Key (Leave empty to auto-generate UUID): " NEW_MANUAL_KEY < /dev/tty
                    if [ -z "$NEW_MANUAL_KEY" ]; then
                        NEW_MANUAL_KEY=$(python3 -c "import uuid; print(uuid.uuid4())")
                    fi
                    eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; sed -i \"s/^API_KEY=.*/API_KEY=$NEW_MANUAL_KEY/\" /opt/pg-node/.env 2>/dev/null || true; pg-node restart -y 2>/dev/null || true'"
                    local tmp_k; tmp_k=$(mktemp)
                    jq --arg n "$idx_pos" --arg k "$NEW_MANUAL_KEY" '.[($n|tonumber)].api_token = $k' "$NODES_FILE" > "$tmp_k" && mv "$tmp_k" "$NODES_FILE"
                    target_token="$NEW_MANUAL_KEY"
                    log OK "API Key successfully updated to $NEW_MANUAL_KEY"
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                15)
                    read -rp "  ▶ New Service Port (Node Port) [$target_sport]: " NEW_SPORT < /dev/tty
                    NEW_SPORT=${NEW_SPORT:-$target_sport}
                    read -rp "  ▶ New API Port [$target_aport]: " NEW_APORT < /dev/tty
                    NEW_APORT=${NEW_APORT:-$target_aport}
                    
                    eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; sed -i \"s/^SERVICE_PORT=.*/SERVICE_PORT=$NEW_SPORT/\" /opt/pg-node/.env 2>/dev/null || true; sed -i \"s/^API_PORT=.*/API_PORT=$NEW_APORT/\" /opt/pg-node/.env 2>/dev/null || true; ufw allow $NEW_SPORT/tcp >/dev/null 2>&1; ufw allow $NEW_APORT/tcp >/dev/null 2>&1; pg-node restart -y 2>/dev/null || true'"
                    local tmp_po; tmp_po=$(mktemp)
                    jq --arg n "$idx_pos" --arg sp "$NEW_SPORT" --arg ap "$NEW_APORT" '.[($n|tonumber)].service_port = ($sp|tonumber) | .[($n|tonumber)].api_port = ($ap|tonumber)' "$NODES_FILE" > "$tmp_po" && mv "$tmp_po" "$NODES_FILE"
                    target_sport="$NEW_SPORT"
                    target_aport="$NEW_APORT"
                    log OK "Ports updated: Service Port = $NEW_SPORT | API Port = $NEW_APORT"
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                12)
                    local tmp_d; tmp_d=$(mktemp)
                    jq "del(.[$idx_pos])" "$NODES_FILE" > "$tmp_d" && mv "$tmp_d" "$NODES_FILE"
                    log OK "Node removed from local inventory."
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    break
                    ;;
                13)
                    read -rp "  Type 'yes' to completely uninstall node and clean DNS: " PURGE_C < /dev/tty
                    if [ "$PURGE_C" == "yes" ]; then
                        eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; echo -e \"y\\ny\" | pg-node uninstall 2>/dev/null || true; rm -rf /opt/pg-node /var/lib/pg-node; ufw delete allow $target_sport/tcp 2>/dev/null || true'"
                        local c_tok c_zid
                        c_tok=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .token' "$DOMAINS_FILE")
                        c_zid=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .zone_id' "$DOMAINS_FILE")
                        if [ -n "$c_tok" ] && [ -n "$c_zid" ]; then
                            jq -r ".[$idx_pos].dns_records[]? // empty" "$NODES_FILE" | while read -r r_to_del; do
                                local clean_name clean_dip rtype="A"
                                clean_name=$(echo "$r_to_del" | awk '{print $1}')
                                clean_dip=$(echo "$r_to_del" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|[0-9a-fA-F:]+')
                                [[ "$clean_dip" == *:* ]] && rtype="AAAA"
                                local rec_id
                                rec_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$cf_zid/dns_records?name=$clean_name&type=$rtype&content=$clean_dip" \
                                     -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" | jq -r '.result[0].id // empty' 2>/dev/null)
                                [ -n "$rec_id" ] && curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$cf_zid/dns_records/$rec_id" -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" >/dev/null
                            done
                        fi
                        local tmp_del; tmp_del=$(mktemp)
                        jq "del(.[$idx_pos])" "$NODES_FILE" > "$tmp_del" && mv "$tmp_del" "$NODES_FILE"
                        log OK "Node uninstalled and DNS cleaned."
                    fi
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    break
                    ;;
                0) break ;;
                *) ;;
            esac
        done
    done
}

node_management_menu() {
    while true; do
        ui_sub_banner
        echo -e "  ${BOLD}${C_CYAN}MODULE 1: NODE MANAGEMENT${RST}"
        echo -e "  ${C_GRAY}Deploy and orchestrate PasarGuard remote nodes${RST}\n"
        echo -e "  ${C_CYAN}[1]${RST} 🚀 Deploy New Node (Multi-IP, DNS Presets & Round-Robin)"
        echo -e "  ${C_CYAN}[2]${RST} 📋 Manage Saved Nodes (IP Migration, Live BBR & DNS)"
        echo -e "  ${C_GRAY}[0]  Back to Main Dashboard${RST}"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" NM_OPT < /dev/tty
        case "$NM_OPT" in
            1) deploy_new_node ;;
            2) manage_saved_nodes ;;
            0) break ;;
            *) ;;
        esac
    done
}

domains_ssl_menu() {
    while true; do
        ui_sub_banner
        echo -e "  ${BOLD}${C_CYAN}MODULE 2: DOMAINS & SSL MANAGER${RST}"
        echo -e "  ${C_GRAY}Manage Cloudflare domains and Let's Encrypt Wildcard certificates${RST}\n"
        echo -e "  ${C_CYAN}[1]${RST} 🌐 List & Add Cloudflare Domains"
        echo -e "  ${C_CYAN}[2]${RST} 🔐 Issue / Renew Wildcard SSL (Certbot Cloudflare)"
        echo -e "  ${C_GRAY}[0]  Back to Main Dashboard${RST}"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" DM_OPT < /dev/tty
        case "$DM_OPT" in
            1)
                list_domain_profiles
                read -rp "$(echo -e "\n  ${C_PURPLE}Do you want to add a new domain? [y/N]: ${RST}")" ADD_D < /dev/tty
                if [[ "$ADD_D" =~ ^[yY]$ ]]; then
                    read -rp "Enter Base Domain: " NEW_DOM < /dev/tty
                    read -rp "Enter Cloudflare API Token: " NEW_TOK < /dev/tty
                    read -rp "Enter Cloudflare Zone ID: " NEW_ZID < /dev/tty
                    if [ -n "$NEW_DOM" ] && [ -n "$NEW_TOK" ] && [ -n "$NEW_ZID" ]; then
                        local tmp_d; tmp_d=$(mktemp)
                        jq --arg d "$NEW_DOM" --arg t "$NEW_TOK" --arg z "$NEW_ZID" '. += [{"domain": $d, "token": $t, "zone_id": $z}]' "$DOMAINS_FILE" > "$tmp_d" && mv "$tmp_d" "$DOMAINS_FILE"
                        log OK "Domain $NEW_DOM added successfully."
                    fi
                fi
                read -rp "Press [ENTER] to return..." < /dev/tty
                ;;
            2)
                list_domain_profiles
                local dc; dc=$(get_domains_count)
                [ "$dc" -eq 0 ] && { read -rp "Press [ENTER] to return..." < /dev/tty; continue; }
                read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Domain to Issue Wildcard SSL [1-$dc]: ${RST}")" SSL_D_IDX < /dev/tty
                if [[ "$SSL_D_IDX" =~ ^[0-9]+$ ]] && [ "$SSL_D_IDX" -ge 1 ] && [ "$SSL_D_IDX" -le "$dc" ]; then
                    local target_ssl_dom target_tok
                    target_ssl_dom=$(jq -r ".[$((SSL_D_IDX - 1))].domain" "$DOMAINS_FILE")
                    target_tok=$(jq -r ".[$((SSL_D_IDX - 1))].token" "$DOMAINS_FILE")
                    
                    mkdir -p /root/.secrets/certbot
                    echo "dns_cloudflare_api_token = $target_tok" > /root/.secrets/certbot/cloudflare.ini
                    chmod 600 /root/.secrets/certbot/cloudflare.ini
                    
                    certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
                        -d "$target_ssl_dom" -d "*.$target_ssl_dom" --agree-tos --register-unsafely-without-email --non-interactive
                    log OK "Wildcard SSL issued/renewed for $target_ssl_dom"
                fi
                read -rp "Press [ENTER] to return..." < /dev/tty
                ;;
            0) break ;;
            *) ;;
        esac
    done
}

cloudflare_dns_center() {
    while true; do
        ui_sub_banner
        echo -e "  ${BOLD}${C_CYAN}MODULE 3: CLOUDFLARE DNS & CLEAN IPS CENTER${RST}"
        echo -e "  ${C_GRAY}Manage Cloudflare DNS records, Round-Robin clean IPs and templates${RST}\n"
        echo -e "  ${C_CYAN}[1]${RST} ⚡ Attach Round-Robin Clean IPs to Subdomain"
        echo -e "  ${C_CYAN}[2]${RST} 📋 Manage DNS Presets Templates"
        echo -e "  ${C_GRAY}[0]  Back to Main Dashboard${RST}"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" CF_OPT < /dev/tty
        case "$CF_OPT" in
            1)
                list_domain_profiles
                local dc; dc=$(get_domains_count)
                [ "$dc" -eq 0 ] && { read -rp "Press [ENTER] to return..." < /dev/tty; continue; }
                read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Domain Profile [1-$dc]: ${RST}")" CF_D_IDX < /dev/tty
                if [[ "$CF_D_IDX" =~ ^[0-9]+$ ]] && [ "$CF_D_IDX" -ge 1 ] && [ "$CF_D_IDX" -le "$dc" ]; then
                    local c_dom c_tok c_zid
                    c_dom=$(jq -r ".[$((CF_D_IDX - 1))].domain" "$DOMAINS_FILE")
                    c_tok=$(jq -r ".[$((CF_D_IDX - 1))].token" "$DOMAINS_FILE")
                    c_zid=$(jq -r ".[$((CF_D_IDX - 1))].zone_id" "$DOMAINS_FILE")

                    read -rp "  ▶ Target Subdomain prefix (ex: cdn): " CF_SUB < /dev/tty
                    read -rp "  ▶ Clean IPs (comma-separated): " CF_IPS < /dev/tty
                    if [ -n "$CF_SUB" ] && [ -n "$CF_IPS" ]; then
                        local full_sub="$CF_SUB.$c_dom"
                        IFS=',' read -ra IP_LIST <<< "$CF_IPS"
                        for raw_ip in "${IP_LIST[@]}"; do
                            local clean_ip; clean_ip=$(echo "$raw_ip" | tr -d ' ')
                            [ -n "$clean_ip" ] && upsert_cloudflare_dns "$c_zid" "$c_tok" "$full_sub" "$clean_ip" "CleanIP-RoundRobin"
                        done
                        log OK "Clean IPs attached to $full_sub successfully."
                    fi
                fi
                read -rp "Press [ENTER] to return..." < /dev/tty
                ;;
            2)
                while true; do
                    ui_sub_banner
                    echo -e "  ${BOLD}${C_CYAN}📋 DNS PRESETS TEMPLATES MANAGEMENT${RST}
"
                    local p_keys=()
                    while IFS= read -r k; do [ -n "$k" ] && p_keys+=("$k"); done < <(jq -r 'keys[]' "$PRESETS_FILE" 2>/dev/null)

                    if [ ${#p_keys[@]} -eq 0 ]; then
                        echo -e "  ${C_YELLOW}No presets defined yet.${RST}
"
                    else
                        echo -e "  ${C_PURPLE}Saved Templates:${RST}"
                        for i in "${!p_keys[@]}"; do
                            local pk="${p_keys[$i]}"
                            local sub_list
                            sub_list=$(jq -r --arg k "$pk" '.[$k] | join(", ")' "$PRESETS_FILE" 2>/dev/null)
                            echo -e "    ${C_CYAN}[$((i + 1))]${RST} ${BOLD}$pk${RST} -> [${C_GREEN}$sub_list${RST}]"
                        done
                        echo ""
                    fi

                    echo -e "    ${C_GREEN}[1]${RST} ➕ Add / Update a Preset Template"
                    echo -e "    ${C_RED}[2]${RST} 🗑️  Delete a Preset Template"
                    echo -e "    ${C_GRAY}[0]${RST} 🔙 Back"
                    read -rp "$(echo -e "
  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" P_SUB_OPT < /dev/tty

                    case "$P_SUB_OPT" in
                        1)
                            read -rp "  ▶ Preset Name (ex: pool_main): " NEW_P_NAME < /dev/tty
                            read -rp "  ▶ Subdomain prefixes (comma-separated, ex: pool1-1, direct): " NEW_P_SUBS < /dev/tty
                            if [ -n "$NEW_P_NAME" ] && [ -n "$NEW_P_SUBS" ]; then
                                IFS=',' read -ra SL <<< "$NEW_P_SUBS"
                                local json_arr="["
                                for item in "${SL[@]}"; do
                                    local c_item; c_item=$(echo "$item" | tr -d ' ')
                                    [ -n "$c_item" ] && json_arr+="\"$c_item\","
                                done
                                json_arr="${json_arr%,}]"
                                local tmp_pr; tmp_pr=$(mktemp)
                                jq --arg k "$NEW_P_NAME" --argjson arr "$json_arr" '.[$k] = $arr' "$PRESETS_FILE" > "$tmp_pr" && mv "$tmp_pr" "$PRESETS_FILE"
                                log OK "Preset '$NEW_P_NAME' saved successfully."
                            fi
                            read -rp "  Press [ENTER] to continue..." < /dev/tty
                            ;;
                        2)
                            if [ ${#p_keys[@]} -gt 0 ]; then
                                read -rp "  ▶ Select preset number to delete [1-${#p_keys[@]}]: " DEL_P_IDX < /dev/tty
                                if [[ "$DEL_P_IDX" =~ ^[0-9]+$ ]] && [ "$DEL_P_IDX" -ge 1 ] && [ "$DEL_P_IDX" -le "${#p_keys[@]}" ]; then
                                    local chosen_pk="${p_keys[$((DEL_P_IDX - 1))]}"
                                    local tmp_del; tmp_del=$(mktemp)
                                    jq --arg k "$chosen_pk" 'del(.[$k])' "$PRESETS_FILE" > "$tmp_del" && mv "$tmp_del" "$PRESETS_FILE"
                                    log OK "Preset '$chosen_pk' deleted."
                                fi
                            fi
                            read -rp "  Press [ENTER] to continue..." < /dev/tty
                            ;;
                        0) break ;;
                        *) ;;
                    esac
                done
                ;;
            0) break ;;
            *) ;;
        esac
    done
}

backup_restore_center() {
    while true; do
        ui_sub_banner
        echo -e "  ${BOLD}${C_CYAN}MODULE 4: BACKUP & RESTORE CENTER${RST}"
        echo -e "  ${C_GRAY}Create encrypted backups and recovery archives${RST}\n"
        echo -e "  ${C_CYAN}[1]${RST} 💾 Create Full Backup Archive (Databases & Configs)"
        echo -e "  ${C_CYAN}[2]${RST} ♻️  Restore from Backup Archive"
        echo -e "  ${C_GRAY}[0]  Back to Main Dashboard${RST}"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" BC_OPT < /dev/tty
        case "$BC_OPT" in
            1)
                local b_name="pg_deploy_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
                local b_path="$BACKUP_DIR/$b_name"
                tar -czf "$b_path" -C "$APP_DIR" domains.json nodes.json dns_presets.json 2>/dev/null
                log OK "Backup created at: $b_path"
                read -rp "Press [ENTER] to return..." < /dev/tty
                ;;
            2)
                echo -e "\n  ${BOLD}${C_CYAN}Available Backups in $BACKUP_DIR:${RST}"
                ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "No backups found."
                read -rp "  ▶ Enter full path of backup file: " R_PATH < /dev/tty
                if [ -f "$R_PATH" ]; then
                    tar -xzf "$R_PATH" -C "$APP_DIR" 2>/dev/null
                    log OK "Restore completed successfully."
                fi
                read -rp "Press [ENTER] to return..." < /dev/tty
                ;;
            0) break ;;
            *) ;;
        esac
    done
}

view_logs() {
    ui_sub_banner
    echo -e "  ${BOLD}${C_CYAN}MODULE 5: DIAGNOSTICS & OPERATION LOG TRACE${RST}"
    echo -e "  ${C_GRAY}Showing recent deployment and operation history${RST}\n"
    if [ -f "$LOG_FILE" ]; then
        tail -n 25 "$LOG_FILE"
    else
        echo -e "  ${C_YELLOW}No logs found yet.${RST}"
    fi
    read -rp "  Press [ENTER] to return..." < /dev/tty
}

init_db
sudo apt-get install -qq -y jq sshpass curl tar certbot python3 >/dev/null 2>&1

while true; do
    ui_banner
    active_nodes_count=$(jq '. | length' "$NODES_FILE" 2>/dev/null || echo 0)
    active_domains_count=$(jq '. | length' "$DOMAINS_FILE" 2>/dev/null || echo 0)

    echo -e "  ${DIM}System Status:${RST} ${C_GREEN}Active${RST}  │  ${DIM}Nodes Registered:${RST} ${BOLD}$active_nodes_count${RST}  │  ${DIM}Domains Loaded:${RST} ${BOLD}$active_domains_count${RST}\n"
    echo -e "  ${BOLD}${C_CYAN}[1] 🚀 Node Management Center${RST}      Deploy, 1-Click Migrate, Inbounds, Xray"
    echo -e "  ${BOLD}${C_CYAN}[2] 🌐 Domains & SSL Manager${RST}       Certbot, Wildcards, Multi-SSL Sync"
    echo -e "  ${BOLD}${C_CYAN}[3] ⚡ Cloudflare DNS Center${RST}       Clean IPs Table, Presets Templates"
    echo -e "  ${BOLD}${C_CYAN}[4] 💾 Backup & Restore Center${RST}     1-Click Download Link & Recovery"
    echo -e "  ${BOLD}${C_CYAN}[5] 📋 Diagnostics & Log Trace${RST}     View Live Operations History"
    echo -e "  ${BOLD}${C_GRAY}[0] 🚪 Exit${RST}"
    echo -e "\n${C_CYAN}────────────────────────────────────────────────────────────────────────${RST}"
    read -rp "$(echo -e "  ${C_PURPLE}▶ Select Module [0-5]: ${RST}")" MAIN_CHOICE < /dev/tty

    case "$MAIN_CHOICE" in
        1) node_management_menu ;;
        2) domains_ssl_menu ;;
        3) cloudflare_dns_center ;;
        4) backup_restore_center ;;
        5) view_logs ;;
        0) echo -e "\n  ${C_GREEN}Goodbye!${RST}\n"; exit 0 ;;
        *) ;;
    esac
done
