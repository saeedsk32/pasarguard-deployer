#!/bin/bash

# ==============================================================================
# PasarGuard Multi-Node Auto-Deployer (v8.5 - Universal Multi-SSL Sync Edition)
# Developed by Saeed SK (@saeedsk32)
# ==============================================================================

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
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██████╗  ██████╗${RST} ${BOLD}${C_PURPLE}██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██╔══██╗██╔════╝${RST} ${BOLD}${C_PURPLE}██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██████╔╝██║  ███╗${RST}${BOLD}${C_PURPLE}██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝ ${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██╔═══╝ ██║   ██║${RST}${BOLD}${C_PURPLE}██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝  ${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██║     ╚██████╔╝${RST}${BOLD}${C_PURPLE}██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║   ${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${DIM}Automated DevOps by Saeed SK (@saeedsk32) v8.5 (Production)${RST}           ${C_CYAN}│${RST}"
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

list_domain_profiles() {
    local count; count=$(get_domains_count)
    if [ "$count" -eq 0 ]; then
        echo -e "  ${C_YELLOW}No domain profiles registered yet.${RST}"
        return 1
    fi
    echo -e "\n  ${BOLD}${C_CYAN}Registered Cloudflare Domains:${RST}"
    local i=0
    while IFS= read -r row; do
        ((i++))
        local d z
        d=$(echo "$row" | jq -r '.domain')
        z=$(echo "$row" | jq -r '.zone_id')
        echo -e "    ${C_PURPLE}[$i]${RST} ${BOLD}$d${RST} ${C_GRAY}(Zone: $z)${RST}"
    done < <(jq -c '.[]' "$DOMAINS_FILE" 2>/dev/null)
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
    local ssh_c="sshpass -p '$pass' ssh -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $user@$ip"
    
    local curr_cc bbr_mod
    curr_cc=$(eval "$ssh_c 'sysctl -n net.ipv4.tcp_congestion_control'" 2>/dev/null || echo "unknown")
    bbr_mod=$(eval "$ssh_c 'lsmod | grep -q bbr && echo active || echo inactive'" 2>/dev/null)

    echo -e "\n  ${BOLD}${C_CYAN}--- TCP BBR Status for Node: $host ---${RST}"
    echo -e "  Active Congestion Control : ${C_GREEN}${curr_cc}${RST}"
    echo -e "  Kernel Module Status      : ${C_YELLOW}${bbr_mod}${RST}\n"
    echo -e "    ${C_CYAN}[1]${RST} Enable BBR (fq + bbr)"
    echo -e "    ${C_CYAN}[2]${RST} Disable BBR (Revert to cubic)"
    echo -e "    ${C_GRAY}[0]${RST} Back"
    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Choose Action [0-2]: ${RST}")" BBR_ACT < /dev/tty

    case "$BBR_ACT" in
        1)
            eval "$ssh_c 'modprobe tcp_bbr 2>/dev/null || true; echo \"net.core.default_qdisc=fq\" > /etc/sysctl.d/99-bbr.conf; echo \"net.ipv4.tcp_congestion_control=bbr\" >> /etc/sysctl.d/99-bbr.conf; sysctl --system >/dev/null 2>&1'"
            log OK "TCP BBR enabled successfully on $host."
            ;;
        2)
            eval "$ssh_c 'echo \"net.core.default_qdisc=pfifo_fast\" > /etc/sysctl.d/99-bbr.conf; echo \"net.ipv4.tcp_congestion_control=cubic\" >> /etc/sysctl.d/99-bbr.conf; sysctl --system >/dev/null 2>&1'"
            log OK "BBR disabled. Reverted to standard cubic algorithm."
            ;;
        *) ;;
    esac
}

generate_node_self_signed() {
    local target_ip="$1" target_port="$2" target_user="$3" target_pass="$4" target_host="$5"
    echo -e "\n  ${C_BLUE}ℹ Generating fresh SAN Self-Signed certificate for $target_ip...${RST}"
    local ssh_c="sshpass -p '$target_pass' ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $target_user@$target_ip"
    eval "$ssh_c 'mkdir -p /var/lib/pg-node/certs; openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 3650 -nodes -keyout /var/lib/pg-node/certs/self_key.pem -out /var/lib/pg-node/certs/self_cert.pem -subj \"/CN=$target_ip\" -addext \"subjectAltName=DNS:localhost,IP:127.0.0.1,IP=$target_ip\" 2>/dev/null'"
    read -rp "$(echo -e "  ▶ Make this newly generated Self-Signed cert ACTIVE right now? [y/N]: ${RST}")" ACT_SELF < /dev/tty
    if [[ "$ACT_SELF" =~ ^[yY]$ ]]; then
        eval "$ssh_c 'cp -f /var/lib/pg-node/certs/self_cert.pem /var/lib/pg-node/certs/ssl_cert.pem && cp -f /var/lib/pg-node/certs/self_key.pem /var/lib/pg-node/certs/ssl_key.pem && docker restart node 2>/dev/null || true; systemctl restart pg-node-service 2>/dev/null || true'"
        log OK "Node is now actively using the local Self-Signed certificate."
    else
        log OK "Self-Signed cert stored in /var/lib/pg-node/certs/self_cert.pem (Standby)."
    fi
}

deploy_new_node() {
    ui_banner
    echo -e "  ${BOLD}${C_CYAN}🚀 DEPLOY NEW PASARGUARD NODE${RST}\n"
    
    local d_count; d_count=$(get_domains_count)
    if [ "$d_count" -eq 0 ]; then
        log ERROR "No domain profile found. Please add a domain first."
        read -rp "Press [ENTER] to return..." < /dev/tty
        return 1
    fi

    list_domain_profiles
    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Main Domain Profile [1-$d_count]: ${RST}")" D_IDX < /dev/tty
    if ! [[ "$D_IDX" =~ ^[0-9]+$ ]] || [ "$D_IDX" -lt 1 ] || [ "$D_IDX" -gt "$d_count" ]; then
        log ERROR "Invalid domain selection."
        read -rp "Press [ENTER] to return..." < /dev/tty
        return 1
    fi

    local dom_idx=$((D_IDX - 1))
    local base_domain cf_token zone_id
    base_domain=$(jq -r ".[$dom_idx].domain" "$DOMAINS_FILE")
    cf_token=$(jq -r ".[$dom_idx].token" "$DOMAINS_FILE")
    zone_id=$(jq -r ".[$dom_idx].zone_id" "$DOMAINS_FILE")

    read -rp "$(echo -e "  ${C_PURPLE}▶ Node Name / Hostname (ex: node-DE1): ${RST}")" NODE_HOST < /dev/tty
    NODE_HOST=${NODE_HOST:-node1}
    read -rp "$(echo -e "  ${C_PURPLE}▶ Primary Server IPv4 (Main IP): ${RST}")" NODE_IP < /dev/tty
    read -rp "$(echo -e "  ${C_PURPLE}▶ Additional IPv4s (comma-separated - Optional): ${RST}")" EXTRA_IPS < /dev/tty
    read -rp "$(echo -e "  ${C_PURPLE}▶ Server IPv6 (Optional): ${RST}")" NODE_IPV6 < /dev/tty
    read -rp "$(echo -e "  ${C_PURPLE}▶ SSH Port [22]: ${RST}")" NODE_SSH_PORT < /dev/tty
    NODE_SSH_PORT=${NODE_SSH_PORT:-22}
    read -rp "$(echo -e "  ${C_PURPLE}▶ SSH User [root]: ${RST}")" NODE_SSH_USER < /dev/tty
    NODE_SSH_USER=${NODE_SSH_USER:-root}
    read -srp "$(echo -e "  ${C_PURPLE}▶ SSH Password: ${RST}")" NODE_SSH_PASS < /dev/tty
    echo ""

    echo -e "  ${C_GRAY}ℹ Note: This subdomain is strictly used for Master Panel <-> Node orchestration.${RST}"
    echo -e "  ${C_GRAY}  It will point ONLY to your Primary IPv4 to avoid hostname mismatch.${RST}"
    read -rp "$(echo -e "  ${C_PURPLE}▶ Node Subdomain for Master Panel (e.g. de1 -> de1.${base_domain}): ${RST}")" SUB_PREFIX < /dev/tty
    SUB_PREFIX=${SUB_PREFIX:-$NODE_HOST}
    local fqdn="$SUB_PREFIX.$base_domain"

    echo -e "\n  ${BOLD}${C_CYAN}DNS Presets Templates Available:${RST}"
    local preset_keys=()
    while IFS= read -r pkey; do [ -n "$pkey" ] && preset_keys+=("$pkey"); done < <(jq -r 'keys[]' "$PRESETS_FILE" 2>/dev/null)
    
    local SELECTED_PRESET_SUBS=()
    if [ ${#preset_keys[@]} -gt 0 ]; then
        for i in "${!preset_keys[@]}"; do
            local p_name="${preset_keys[$i]}"
            local p_items; p_items=$(jq -c --arg k "$p_name" '.[$k]' "$PRESETS_FILE" 2>/dev/null)
            echo -e "    ${C_PURPLE}[$((i + 1))]${RST} ${BOLD}$p_name${RST} -> $p_items"
        done
        read -rp "$(echo -e "  ${C_PURPLE}▶ Choose Preset Template [1-${#preset_keys[@]}, or 0 to skip]: ${RST}")" P_CHOICE < /dev/tty
        if [[ "$P_CHOICE" =~ ^[0-9]+$ ]] && [ "$P_CHOICE" -ge 1 ] && [ "$P_CHOICE" -le "${#preset_keys[@]}" ]; then
            local sel_key="${preset_keys[$((P_CHOICE - 1))]}"
            while IFS= read -r sub_item; do
                [ -n "$sub_item" ] && SELECTED_PRESET_SUBS+=("$sub_item")
            done < <(jq -r --arg k "$sel_key" '.[$k][]' "$PRESETS_FILE" 2>/dev/null)
            echo -e "  ${C_GREEN}✔ Preset '$sel_key' loaded: ${SELECTED_PRESET_SUBS[*]}${RST}"
        fi
    fi

    read -rp "$(echo -e "  ${C_PURPLE}▶ Extra Custom Subdomains for clients (comma-separated, ex: de1-1, cdn - Optional): ${RST}")" EXTRA_CUSTOM_SUBS < /dev/tty

    read -rp "$(echo -e "  ${C_PURPLE}▶ Node Port (Service Port) [62050]: ${RST}")" NODE_PORT < /dev/tty
    NODE_PORT=${NODE_PORT:-62050}
    read -rp "$(echo -e "  ${C_PURPLE}▶ Advanced API Port [62051]: ${RST}")" API_PORT < /dev/tty
    API_PORT=${API_PORT:-62051}
    read -rp "$(echo -e "  ${C_PURPLE}▶ Protocol: [1] gRPC (Default) or [2] REST [1]: ${RST}")" PROTO_CHOICE < /dev/tty
    local proto_flag="--use-grpc" proto_str="grpc"
    [ "$PROTO_CHOICE" == "2" ] && { proto_flag="--use-rest"; proto_str="rest"; }

    # MULTI-SSL PRE-SEEDING SELECTION
    echo -e "\n  ${BOLD}${C_CYAN}🔐 MULTI-SSL INBOUND VAULT PRE-SEEDING:${RST}"
    echo -e "  ${C_GRAY}Select which certificates you want to pre-load onto this node for client inbounds:${RST}"
    local all_domains=()
    while IFS= read -r drow; do
        all_domains+=("$(echo "$drow" | jq -r '.domain')")
    done < <(jq -c '.[]' "$DOMAINS_FILE" 2>/dev/null)

    for i in "${!all_domains[@]}"; do
        echo -e "    ${C_PURPLE}[$((i + 1))]${RST} Wildcard SSL: *.${all_domains[$i]}"
    done
    echo -e "    ${C_GREEN}[all]${RST} Deploy ALL available domain certificates automatically"

    read -rp "$(echo -e "  ${C_PURPLE}▶ Select Certificates to Pre-Seed [all, or numbers like 1,2]: ${RST}")" SEED_CHOICE < /dev/tty
    SEED_CHOICE=${SEED_CHOICE:-all}

    local DOMAINS_TO_SEED=()
    if [[ "$SEED_CHOICE" =~ ^[aA][lL][lL]$ ]]; then
        DOMAINS_TO_SEED=("${all_domains[@]}")
    else
        IFS=',' read -ra S_PARTS <<< "$SEED_CHOICE"
        for sp in "${S_PARTS[@]}"; do
            local clean_sp; clean_sp=$(echo "$sp" | tr -d ' ')
            if [[ "$clean_sp" =~ ^[0-9]+$ ]] && [ "$clean_sp" -ge 1 ] && [ "$clean_sp" -le "${#all_domains[@]}" ]; then
                DOMAINS_TO_SEED+=("${all_domains[$((clean_sp - 1))]}")
            fi
        done
    fi
    local found_base=0
    for d in "${DOMAINS_TO_SEED[@]}"; do [ "$d" == "$base_domain" ] && found_base=1; done
    [ "$found_base" -eq 0 ] && DOMAINS_TO_SEED+=("$base_domain")

    echo -e "  ${C_GREEN}✔ Will pre-seed certificates for: ${DOMAINS_TO_SEED[*]}${RST}\n"

    log INFO "Verifying SSH connection to $NODE_IP:$NODE_SSH_PORT..."
    local ssh_test
    ssh_test=$(sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$NODE_SSH_USER@$NODE_IP" "echo connected" 2>&1)
    if [[ $? -ne 0 ]]; then
        log ERROR "Cannot connect via SSH to $NODE_IP:$NODE_SSH_PORT"
        echo -e "  ${C_RED}Error details:${RST} $ssh_test"
        read -rp "  Press [ENTER] to return..." < /dev/tty
        return 1
    fi
    log OK "SSH connection established."

    log INFO "Tuning kernel TCP BBR and baseline firewall..."
    sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$NODE_SSH_USER@$NODE_IP" \
        "modprobe tcp_bbr 2>/dev/null || true; echo 'net.core.default_qdisc=fq' > /etc/sysctl.d/99-bbr.conf; echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.d/99-bbr.conf; sysctl --system >/dev/null 2>&1; ufw allow $NODE_PORT/tcp; ufw allow $API_PORT/tcp; ufw allow 22/tcp; ufw --force enable >/dev/null 2>&1 || true"

    local all_v4_ips=("$NODE_IP")
    if [ -n "$EXTRA_IPS" ]; then
        IFS=',' read -ra ADDRS <<< "$EXTRA_IPS"
        for aip in "${ADDRS[@]}"; do
            local clean_aip; clean_aip=$(echo "$aip" | tr -d ' ')
            [ -n "$clean_aip" ] && all_v4_ips+=("$clean_aip")
        done
    fi

    local dns_recs_array=()

    upsert_cloudflare_dns "$zone_id" "$cf_token" "$fqdn" "$NODE_IP" "PG-Node: $NODE_HOST | Master-Link"
    dns_recs_array+=("$fqdn ($NODE_IP)")

    local HAS_V6=0
    if [ -n "$NODE_IPV6" ]; then
        read -rp "$(echo -e "  ${C_PURPLE}▶ Create Cloudflare AAAA records for IPv6 on client pool/subdomains? [y/N]: ${RST}")" CONFIRM_V6 < /dev/tty
        if [[ "$CONFIRM_V6" =~ ^[yY]$ ]]; then
            HAS_V6=1
            upsert_cloudflare_dns "$zone_id" "$cf_token" "$fqdn" "$NODE_IPV6" "PG-Node: $NODE_HOST | Master-IPv6"
            dns_recs_array+=("$fqdn ($NODE_IPV6)")
        fi
    fi

    for ps in "${SELECTED_PRESET_SUBS[@]}"; do
        local pool_fqdn="${ps}.${base_domain}"
        for v4 in "${all_v4_ips[@]}"; do
            upsert_cloudflare_dns "$zone_id" "$cf_token" "$pool_fqdn" "$v4" "PG-Node: $NODE_HOST | Pool-RoundRobin"
            dns_recs_array+=("$pool_fqdn ($v4)")
        done
        if [ "$HAS_V6" -eq 1 ]; then
            upsert_cloudflare_dns "$zone_id" "$cf_token" "$pool_fqdn" "$NODE_IPV6" "PG-Node: $NODE_HOST | Pool-RoundRobin-v6"
            dns_recs_array+=("$pool_fqdn ($NODE_IPV6)")
        fi
    done

    if [ -n "$EXTRA_CUSTOM_SUBS" ]; then
        IFS=',' read -ra CSUBS <<< "$EXTRA_CUSTOM_SUBS"
        for cs in "${CSUBS[@]}"; do
            local clean_cs; clean_cs=$(echo "$cs" | tr -d ' ')
            if [ -n "$clean_cs" ]; then
                local c_fqdn="${clean_cs}.${base_domain}"
                for v4 in "${all_v4_ips[@]}"; do
                    upsert_cloudflare_dns "$zone_id" "$cf_token" "$c_fqdn" "$v4" "PG-Node: $NODE_HOST | Custom-RR"
                    dns_recs_array+=("$c_fqdn ($v4)")
                done
                if [ "$HAS_V6" -eq 1 ]; then
                    upsert_cloudflare_dns "$zone_id" "$cf_token" "$c_fqdn" "$NODE_IPV6" "PG-Node: $NODE_HOST | Custom-RR-v6"
                    dns_recs_array+=("$c_fqdn ($NODE_IPV6)")
                fi
            fi
        done
    fi

    log INFO "Purging old node states and provisioning core on remote server..."
    local generated_api_key
    generated_api_key=$(python3 -c "import uuid; print(uuid.uuid4())")

    sshpass -p "$NODE_SSH_PASS" ssh -t -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$NODE_SSH_USER@$NODE_IP" \
        "echo -e 'y\ny' | pg-node uninstall 2>/dev/null || true; docker rm -f node 2>/dev/null || true; systemctl stop pg-node pg-node-service 2>/dev/null || true; rm -rf /opt/pg-node /usr/local/bin/pg-node /usr/bin/pg-node /etc/systemd/system/pg-node*.service; systemctl daemon-reload 2>/dev/null || true; curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh -o /tmp/pg-node.sh && chmod +x /tmp/pg-node.sh && /tmp/pg-node.sh install $proto_flag --service-port $NODE_PORT --api-port $API_PORT --api-key $generated_api_key -y; mkdir -p /var/lib/pg-node/certs; cp -f /var/lib/pg-node/certs/ssl_cert.pem /var/lib/pg-node/certs/self_cert.pem 2>/dev/null || true; cp -f /var/lib/pg-node/certs/ssl_key.pem /var/lib/pg-node/certs/self_key.pem 2>/dev/null || true"

    sleep 2
    local token_extracted
    token_extracted=$(sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$NODE_SSH_USER@$NODE_IP" \
        "grep -oE '[0-9a-fA-F-]{36}' /opt/pg-node/.env 2>/dev/null || grep -oE '[0-9a-fA-F-]{36}' /etc/systemd/system/pg-node.service 2>/dev/null || echo '$generated_api_key'" | head -n 1)
    token_extracted=${token_extracted:-$generated_api_key}

    log INFO "Pre-seeding selected Wildcard SSL certificates to Multi-SSL Vault..."
    for s_dom in "${DOMAINS_TO_SEED[@]}"; do
        local l_cert="/etc/letsencrypt/live/$s_dom/fullchain.pem"
        local l_key="/etc/letsencrypt/live/$s_dom/privkey.pem"
        if [ -f "$l_cert" ] && [ -f "$l_key" ]; then
            sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$NODE_SSH_USER@$NODE_IP" "mkdir -p /var/lib/pg-node/certs/$s_dom"
            sshpass -p "$NODE_SSH_PASS" scp -P "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$l_cert" "$NODE_SSH_USER@$NODE_IP:/var/lib/pg-node/certs/$s_dom/fullchain.pem" >/dev/null
            sshpass -p "$NODE_SSH_PASS" scp -P "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$l_key" "$NODE_SSH_USER@$NODE_IP:/var/lib/pg-node/certs/$s_dom/privkey.pem" >/dev/null
            log OK "Pre-seeded certificate: $s_dom"
        fi
    done

    local main_c="/var/lib/pg-node/certs/${base_domain}/fullchain.pem"
    local main_k="/var/lib/pg-node/certs/${base_domain}/privkey.pem"
    sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$NODE_SSH_USER@$NODE_IP" \
        "cp -f $main_c /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || true; cp -f $main_k /var/lib/pg-node/certs/ssl_key.pem 2>/dev/null || true; docker restart node 2>/dev/null || true; systemctl restart pg-node-service 2>/dev/null || true"

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
        '{hostname: $h, ip: $ip, address: $addr, service_port: ($sport|tonumber), api_port: ($aport|tonumber), protocol: $proto, api_token: $tok, base_domain: $bdom, ssh_pass: $upass, ssh_port: ($uport|tonumber), ssh_user: $uusr, dns_records: [], ssl_domains: []}')

    for r in "${dns_recs_array[@]}"; do
        node_json_entry=$(echo "$node_json_entry" | jq --arg rec "$r" '.dns_records += [$rec]')
    done
    for sd in "${DOMAINS_TO_SEED[@]}"; do
        node_json_entry=$(echo "$node_json_entry" | jq --arg sdom "$sd" '.ssl_domains += [$sdom]')
    done

    local tmp_n; tmp_n=$(mktemp)
    jq --argjson newnode "$node_json_entry" '. += [$newnode]' "$NODES_FILE" > "$tmp_n" && mv "$tmp_n" "$NODES_FILE"

    log OK "Node successfully deployed with complete Multi-SSL Vault!"
    read -rp "  Press [ENTER] to return to dashboard..." < /dev/tty
}

add_existing_active_node() {
    ui_banner
    echo -e "  ${BOLD}${C_CYAN}🔗 ATTACH & AUTO-DISCOVER AN EXISTING ACTIVE NODE${RST}\n"
    list_domain_profiles
    local dc; dc=$(get_domains_count)
    if [ "$dc" -eq 0 ]; then
        read -rp "Press [ENTER] to return..." < /dev/tty
        return 1
    fi

    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Main Domain Profile [1-$dc]: ${RST}")" D_IDX < /dev/tty
    local bdom; bdom=$(jq -r ".[$((D_IDX - 1))].domain" "$DOMAINS_FILE")
    read -rp "  ▶ Node Hostname (e.g. node-DE1): " E_HOST < /dev/tty
    read -rp "  ▶ Primary Server IPv4: " E_IP < /dev/tty
    read -rp "  ▶ Remote SSH Port [22]: " E_PORT < /dev/tty
    E_PORT=${E_PORT:-22}
    read -rp "  ▶ Remote SSH User [root]: " E_USER < /dev/tty
    E_USER=${E_USER:-root}
    read -srp "  ▶ Remote SSH Password: " E_PASS < /dev/tty
    echo ""

    echo -e "\n  ${C_BLUE}ℹ Connecting to $E_IP:$E_PORT to auto-discover configuration...${RST}"
    local ssh_c="sshpass -p '$E_PASS' ssh -p $E_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $E_USER@$E_IP"

    local disc_data
    disc_data=$(eval "$ssh_c '
        echo \"===CONF===\"
        cat /opt/pg-node/.env 2>/dev/null
        echo \"===SERVICE===\"
        cat /etc/systemd/system/pg-node-service.service 2>/dev/null
        echo \"===PORTS===\"
        ss -tlpn 2>/dev/null
    '")

    local e_tok e_sport e_aport e_proto
    e_tok=$(echo "$disc_data" | grep -oE '[0-9a-fA-F-]{36}' | head -n1)
    e_sport=$(echo "$disc_data" | grep "^SERVICE_PORT=" | cut -d'=' -f2 | tr -d ' \r')
    e_aport=$(echo "$disc_data" | grep "^API_PORT=" | cut -d'=' -f2 | tr -d ' \r')
    e_proto=$(echo "$disc_data" | grep -iq "grpc" && echo "grpc" || echo "rest")

    e_sport=${e_sport:-62050}
    e_aport=${e_aport:-62051}

    echo -e "  ${C_GREEN}✔ Discovered Configuration:${RST}"
    echo -e "    • API Key Secret : ${C_YELLOW}${e_tok:-Manual Entry Required}${RST}"
    echo -e "    • Service Port   : ${C_YELLOW}${e_sport}${RST}"
    echo -e "    • API Port       : ${C_YELLOW}${e_aport}${RST}"
    echo -e "    • Protocol       : ${C_YELLOW}${e_proto^^}${RST}"

    if [ -z "$e_tok" ]; then
        read -rp "  ▶ Enter API Key manually: " e_tok < /dev/tty
    fi

    read -rp "  ▶ Master FQDN Address [e.g. $E_HOST.$bdom]: " E_ADDR < /dev/tty
    E_ADDR=${E_ADDR:-"$E_HOST.$bdom"}

    # =========================================================================
    # MULTI-SSL SYNC SELECTION FOR EXISTING NODE
    # =========================================================================
    echo -e "\n  ${BOLD}${C_CYAN}🔐 MULTI-SSL INBOUND VAULT SYNC FOR THIS NODE:${RST}"
    echo -e "  ${C_GRAY}Select which certificates you want to push to /var/lib/pg-node/certs/ on this node:${RST}"
    local all_domains=()
    while IFS= read -r drow; do
        all_domains+=("$(echo "$drow" | jq -r '.domain')")
    done < <(jq -c '.[]' "$DOMAINS_FILE" 2>/dev/null)

    for i in "${!all_domains[@]}"; do
        echo -e "    ${C_PURPLE}[$((i + 1))]${RST} Wildcard SSL: *.${all_domains[$i]}"
    done
    echo -e "    ${C_GREEN}[all]${RST} Push ALL available domain certificates automatically"
    echo -e "    ${C_GRAY}[none]${RST} Skip pushing certificates (Keep current node certs untouched)"

    read -rp "$(echo -e "  ${C_PURPLE}▶ Select Certificates to Sync [all, none, or 1,2]: ${RST}")" SEED_CHOICE < /dev/tty
    SEED_CHOICE=${SEED_CHOICE:-all}

    local DOMAINS_TO_SEED=()
    if [[ "$SEED_CHOICE" =~ ^[aA][lL][lL]$ ]]; then
        DOMAINS_TO_SEED=("${all_domains[@]}")
    elif [[ "$SEED_CHOICE" =~ ^[nN][oO][nN][eE]$ ]]; then
        DOMAINS_TO_SEED=()
    else
        IFS=',' read -ra S_PARTS <<< "$SEED_CHOICE"
        for sp in "${S_PARTS[@]}"; do
            local clean_sp; clean_sp=$(echo "$sp" | tr -d ' ')
            if [[ "$clean_sp" =~ ^[0-9]+$ ]] && [ "$clean_sp" -ge 1 ] && [ "$clean_sp" -le "${#all_domains[@]}" ]; then
                DOMAINS_TO_SEED+=("${all_domains[$((clean_sp - 1))]}")
            fi
        done
    fi

    if [ ${#DOMAINS_TO_SEED[@]} -gt 0 ]; then
        echo -e "  ${C_BLUE}ℹ Syncing selected Wildcard SSL certificates to remote node...${RST}"
        for s_dom in "${DOMAINS_TO_SEED[@]}"; do
            local l_cert="/etc/letsencrypt/live/$s_dom/fullchain.pem"
            local l_key="/etc/letsencrypt/live/$s_dom/privkey.pem"
            if [ -f "$l_cert" ] && [ -f "$l_key" ]; then
                eval "$ssh_c 'mkdir -p /var/lib/pg-node/certs/$s_dom'"
                sshpass -p "$E_PASS" scp -P "$E_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$l_cert" "$E_USER@$E_IP:/var/lib/pg-node/certs/$s_dom/fullchain.pem" >/dev/null
                sshpass -p "$E_PASS" scp -P "$E_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$l_key" "$E_USER@$E_IP:/var/lib/pg-node/certs/$s_dom/privkey.pem" >/dev/null
                log OK "Synchronized certificate: $s_dom"
            fi
        done
    fi

    local new_entry
    new_entry=$(jq -n \
        --arg h "$E_HOST" --arg ip "$E_IP" --arg addr "$E_ADDR" \
        --arg sport "$e_sport" --arg aport "$e_aport" --arg proto "$e_proto" \
        --arg tok "$e_tok" --arg bdom "$bdom" --arg upass "$E_PASS" \
        --arg uport "$E_PORT" --arg uusr "$E_USER" \
        '{hostname: $h, ip: $ip, address: $addr, service_port: ($sport|tonumber), api_port: ($aport|tonumber), protocol: $proto, api_token: $tok, base_domain: $bdom, ssh_pass: $upass, ssh_port: ($uport|tonumber), ssh_user: $uusr, dns_records: [$addr], ssl_domains: []}')

    for sd in "${DOMAINS_TO_SEED[@]}"; do
        new_entry=$(echo "$new_entry" | jq --arg sdom "$sd" '.ssl_domains += [$sdom]')
    done

    local tmp_n; tmp_n=$(mktemp)
    jq --argjson ne "$new_entry" '. += [$ne]' "$NODES_FILE" > "$tmp_n" && mv "$tmp_n" "$NODES_FILE"
    log OK "Existing node $E_HOST attached and synchronized."
    read -rp "  Press [ENTER] to return to dashboard..." < /dev/tty
}

inspect_node_ssl_details() {
    local target_ip="$1" target_port="$2" target_user="$3" target_pass="$4" target_host="$5" target_bdom="$6"
    ui_sub_banner
    echo -e "  ${BOLD}${C_CYAN}🔐 PASARGUARD MULTI-SSL VAULT & INBOUND KEYS EXPLORER${RST}"
    echo -e "  ${C_GRAY}Server: $target_host ($target_ip) │ Ready for Multiple Domains & Inbounds${RST}\n"

    local ssh_c="sshpass -p '$target_pass' ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $target_user@$target_ip"

    local remote_scan
    remote_scan=$(eval "$ssh_c 'find /var/lib/pg-node/certs -type f \( -name \"fullchain.pem\" -o -name \"self_cert.pem\" \) 2>/dev/null | sort'")

    local active_hash
    active_hash=$(eval "$ssh_c 'md5sum /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null'" | awk '{print $1}')

    local cert_files=()
    while IFS= read -r l; do
        [ -n "$l" ] && cert_files+=("$l")
    done <<< "$remote_scan"

    if [ ${#cert_files[@]} -eq 0 ]; then
        echo -e "  ${C_RED}✖ No domain certificates loaded in /var/lib/pg-node/certs${RST}"
        read -rp "  Press [ENTER] to return..." < /dev/tty
        return
    fi

    local c_idx=0
    for cf in "${cert_files[@]}"; do
        ((c_idx++))
        local kf="${cf%/*}/privkey.pem"
        [[ "$cf" == *"self_cert.pem"* ]] && kf="${cf%/*}/self_key.pem"

        local leaf_subj leaf_iss leaf_san chain_count current_hash
        leaf_subj=$(eval "$ssh_c 'openssl x509 -in \"$cf\" -noout -subject 2>/dev/null'" | sed 's/subject=//;s/^[ \t]*//')
        leaf_iss=$(eval "$ssh_c 'openssl x509 -in \"$cf\" -noout -issuer 2>/dev/null'" | sed 's/issuer=//;s/^[ \t]*//')
        leaf_san=$(eval "$ssh_c 'openssl x509 -in \"$cf\" -noout -ext subjectAltName 2>/dev/null'" | grep -v "X509v3" | tr -d ' ' || echo "N/A")
        [ -z "$leaf_san" ] && leaf_san="N/A"

        chain_count=$(eval "$ssh_c 'grep -c \"BEGIN CERTIFICATE\" \"$cf\" 2>/dev/null'")
        chain_count=${chain_count:-1}
        current_hash=$(eval "$ssh_c 'md5sum \"$cf\" 2>/dev/null'" | awk '{print $1}')

        local role_tag="${C_GRAY}○ Stored Inbound Vault (Available for Xray Inbounds)${RST}"
        if [ -n "$active_hash" ] && [ "$current_hash" == "$active_hash" ]; then
            role_tag="${C_GREEN}● ACTIVE PANEL SERVICE SSL (Used for Master Panel Orchestration)${RST}"
        fi

        echo -e "  ${BOLD}${C_GREEN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo -e "  ${BOLD}${C_GREEN}┃ [VAULT PROFILE $c_idx] $cf${RST}"
        echo -e "  ${BOLD}${C_GREEN}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo -e "  ${C_GREEN}┃${RST} ${BOLD}Live Role${RST}     : $role_tag"
        echo -e "  ${C_GREEN}┃${RST} ${BOLD}Subject CN${RST}    : ${C_WHITE}${leaf_subj}${RST}"
        echo -e "  ${C_GREEN}┃${RST} ${BOLD}Issuer CA${RST}     : ${C_GRAY}${leaf_iss}${RST}"
        echo -e "  ${C_GREEN}┃${RST} ${BOLD}SAN Domains${RST}   : ${C_CYAN}${leaf_san}${RST}"
        echo -e "  ${C_GREEN}┃${RST} ${BOLD}Chain Levels${RST}  : ${chain_count} [Leaf + Intermediate CA]"
        echo -e "  ${BOLD}${C_GREEN}┣━ Option A: File Paths for Inbound ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo -e "  ${C_GREEN}┃${RST}  • Cert path : ${C_CYAN}${cf}${RST}"
        echo -e "  ${C_GREEN}┃${RST}  • Key path  : ${C_CYAN}${kf}${RST}"
        echo -e "  ${BOLD}${C_GREEN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}\n"
    done

    echo -e "  ${BOLD}${C_CYAN}⚡ VAULT CONTROLS & DOSSIER:${RST}"
    echo -e "    ${C_CYAN}[1-${#cert_files[@]}]${RST} 📋 Open Dedicated Dossier (FullChain Levels & Key Box)"
    echo -e "    ${C_PURPLE}[S]${RST}   ⚡ Switch Master Panel Orchestration SSL to a Specific Profile"
    echo -e "    ${C_GRAY}[0]${RST}   🔙 Back to Node Dashboard"
    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Choice: ${RST}")" V_ACT < /dev/tty

    if [[ "$V_ACT" =~ ^[0-9]+$ ]] && [ "$V_ACT" -ge 1 ] && [ "$V_ACT" -le "${#cert_files[@]}" ]; then
        local chosen_cf="${cert_files[$((V_ACT - 1))]}"
        local chosen_kf="${chosen_cf%/*}/privkey.pem"
        [[ "$chosen_cf" == *"self_cert.pem"* ]] && chosen_kf="${chosen_cf%/*}/self_key.pem"

        local d_subj d_iss d_san d_count d_hash
        d_subj=$(eval "$ssh_c 'openssl x509 -in \"$chosen_cf\" -noout -subject 2>/dev/null'" | sed 's/subject=//;s/^[ \t]*//')
        d_iss=$(eval "$ssh_c 'openssl x509 -in \"$chosen_cf\" -noout -issuer 2>/dev/null'" | sed 's/issuer=//;s/^[ \t]*//')
        d_san=$(eval "$ssh_c 'openssl x509 -in \"$chosen_cf\" -noout -ext subjectAltName 2>/dev/null'" | grep -v "X509v3" | tr -d ' ' || echo "N/A")
        [ -z "$d_san" ] && d_san="N/A"
        d_count=$(eval "$ssh_c 'grep -c \"BEGIN CERTIFICATE\" \"$chosen_cf\" 2>/dev/null'")
        d_count=${d_count:-1}
        d_hash=$(eval "$ssh_c 'md5sum \"$chosen_cf\" 2>/dev/null'" | awk '{print $1}')

        local d_role="${C_GRAY}○ Stored Inbound Vault (Available for Xray Inbounds)${RST}"
        if [ -n "$active_hash" ] && [ "$d_hash" == "$active_hash" ]; then
            d_role="${C_GREEN}● ACTIVE PANEL SERVICE SSL (Used for Master Panel Orchestration)${RST}"
        fi

        ui_sub_banner
        echo -e "  ${BOLD}${C_CYAN}📜 DEDICATED VAULT PROFILE DOSSIER: $chosen_cf${RST}\n"

        echo -e "  ${BOLD}${C_GREEN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo -e "  ${BOLD}${C_GREEN}┃ PROFILE SPECIFICATIONS & METADATA${RST}"
        echo -e "  ${BOLD}${C_GREEN}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo -e "  ${C_GREEN}┃${RST} ${BOLD}Live Role${RST}       : $d_role"
        echo -e "  ${C_GREEN}┃${RST} ${BOLD}Subject CN${RST}      : ${C_WHITE}${d_subj}${RST}"
        echo -e "  ${C_GREEN}┃${RST} ${BOLD}Issuer CA${RST}       : ${C_GRAY}${d_iss}${RST}"
        echo -e "  ${C_GREEN}┃${RST} ${BOLD}SAN Domains${RST}     : ${C_CYAN}${d_san}${RST}"
        echo -e "  ${C_GREEN}┃${RST} ${BOLD}Total Chain${RST}     : ${d_count} Level(s) Detected"
        echo -e "  ${BOLD}${C_GREEN}┣━ Option A: File Paths for Inbound ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo -e "  ${C_GREEN}┃${RST}  • Cert file path : ${C_CYAN}${chosen_cf}${RST}"
        echo -e "  ${C_GREEN}┃${RST}  • Key file path  : ${C_CYAN}${chosen_kf}${RST}"
        echo -e "  ${BOLD}${C_GREEN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}\n"

        echo -e "  ${BOLD}${C_RED}┏━ KEY CONTENT BOX (Paste into Panel 'Key content') ━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo -e "  ${BOLD}${C_RED}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        eval "$ssh_c 'cat \"$chosen_kf\"'"
        echo -e "\n"

        echo -e "  ${BOLD}${C_GREEN}┏━ FULLCHAIN CERTIFICATE BREAKDOWN (Level-by-Level) ━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo -e "  ${BOLD}${C_GREEN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        eval "$ssh_c '
            mkdir -p /tmp/cert_parts && rm -f /tmp/cert_parts/*
            csplit -s -z -f /tmp/cert_parts/part_ \"$chosen_cf\" \"/-----BEGIN CERTIFICATE-----/\" \"{*}\" 2>/dev/null
            level=1
            for f in /tmp/cert_parts/part_*; do
                [ -s \"\$f\" ] || continue
                if [ \$level -eq 1 ]; then
                    echo -e \"\033[38;5;48m[LEVEL 1: SERVER LEAF CERTIFICATE (Paste into Panel Certificate content)]\033[0m\"
                else
                    echo -e \"\033[38;5;51m[LEVEL \$level: INTERMEDIATE CA CERTIFICATE]\033[0m\"
                fi
                echo \"subject=\$(openssl x509 -in \"\$f\" -noout -subject 2>/dev/null | sed \"s/subject=//;s/^[ \t]*//\")\"
                echo \"issuer=\$(openssl x509 -in \"\$f\" -noout -issuer 2>/dev/null | sed \"s/issuer=//;s/^[ \t]*//\")\"
                openssl x509 -in \"\$f\" -noout -dates 2>/dev/null
                cat \"\$f\"
                echo \"\"
                ((level++))
            done
            rm -rf /tmp/cert_parts
        '"

        read -rp "  Press [ENTER] to return to vault..." < /dev/tty
    elif [[ "$V_ACT" =~ ^[sS]$ ]]; then
        read -rp "  ▶ Select Profile number to bind to Master Panel [1-${#cert_files[@]}]: " S_NUM < /dev/tty
        if [[ "$S_NUM" =~ ^[0-9]+$ ]] && [ "$S_NUM" -ge 1 ] && [ "$S_NUM" -le "${#cert_files[@]}" ]; then
            local sw_cf="${cert_files[$((S_NUM - 1))]}"
            local sw_kf="${sw_cf%/*}/privkey.pem"
            [[ "$sw_cf" == *"self_cert.pem"* ]] && sw_kf="${sw_cf%/*}/self_key.pem"
            echo -e "\n  ${C_BLUE}ℹ Binding $sw_cf to /var/lib/pg-node/certs/ssl_cert.pem...${RST}"
            eval "$ssh_c 'cp -f \"$sw_cf\" /var/lib/pg-node/certs/ssl_cert.pem && cp -f \"$sw_kf\" /var/lib/pg-node/certs/ssl_key.pem && docker restart node 2>/dev/null || true; systemctl restart pg-node-service 2>/dev/null || true'"
            log OK "Master Panel SSL linked to $sw_cf"
            read -rp "  Press [ENTER] to continue..." < /dev/tty
        fi
    fi
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
        local n_i=0
        while IFS= read -r n_row; do
            ((n_i++))
            local nh ni na
            nh=$(echo "$n_row" | jq -r '.hostname')
            ni=$(echo "$n_row" | jq -r '.ip')
            na=$(echo "$n_row" | jq -r '.address')
            printf "    \033[38;5;141m[%s]\033[0m \033[1m%s\033[0m \033[38;5;244m(%s)\033[0m -> %s\n" "$n_i" "$nh" "$ni" "$na"
        done < <(jq -c '.[]' "$NODES_FILE" 2>/dev/null)

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
            
            local bbr_status="${C_GRAY}Unknown${RST}"
            local active_cc
            active_cc=$(sshpass -p "$target_pass" ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=2 "$target_user@$target_ip" "sysctl -n net.ipv4.tcp_congestion_control" 2>/dev/null)
            if [[ "$active_cc" == *"bbr"* ]]; then
                bbr_status="${C_GREEN}● Active (BBR + FQ)${RST}"
            elif [ -n "$active_cc" ]; then
                bbr_status="${C_YELLOW}○ Inactive ($active_cc)${RST}"
            else
                bbr_status="${C_RED}✖ Unreachable${RST}"
            fi

            local panel_status="${C_GREEN}● Online (API Listening)${RST}"
            local port_check
            port_check=$(sshpass -p "$target_pass" ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=2 "$target_user@$target_ip" "ss -tlpn | grep -q $target_aport && echo OK || echo FAIL" 2>/dev/null)
            if [ "$port_check" != "OK" ]; then
                panel_status="${C_YELLOW}○ Standby / Checking${RST}"
            fi

            local _remote_cert _leaf_cert
            _remote_cert=$(sshpass -p "$target_pass" ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=2 "$target_user@$target_ip" "cat /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || cat /var/lib/pg-node/certs/${target_bdom}/fullchain.pem 2>/dev/null" 2>/dev/null || true)
            if [ -n "$_remote_cert" ]; then
                _leaf_cert=$(echo "$_remote_cert" | openssl x509 2>/dev/null || echo "$_remote_cert")
            else
                _leaf_cert="(Certificate not found on remote node)"
            fi

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
            printf "  ${C_GREEN}│${RST}  API Key Secret       : %-46s ${C_GREEN}│${RST}\n" "${target_token:-Not detected}"
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

            echo -e "  ${BOLD}${C_BLUE}⚡ INFRASTRUCTURE & DOMAIN ACTIONS:${RST}"
            echo -e "    ${C_PURPLE}[1]${RST}  🔁 1-Click Server IP Migration (Auto CF DNS)"
            echo -e "    ${C_PURPLE}[2]${RST}  🌐 Cloudflare DNS Center (Add / Edit / Delete Records)"
            echo -e "    ${C_PURPLE}[3]${RST}  🔐 Multi-SSL Vault & Inbound Keys Explorer"
            echo -e "    ${C_PURPLE}[4]${RST}  📤 Inject / Overwrite Node SSL with Any Domain"
            echo -e "    ${C_PURPLE}[5]${RST}  🚀 Toggle / Tune TCP BBR Congestion Control"

            echo -e "\n  ${BOLD}${C_GREEN}🔧 PG-NODE CORE OPERATIONS:${RST}"
            echo -e "    ${C_GREEN}[6]${RST}  ♻️  Restart Node Service"
            echo -e "    ${C_GREEN}[7]${RST}  📜 Follow Live Node Logs (Ctrl+C to exit)"
            echo -e "    ${C_GREEN}[8]${RST}  ⚡ Switch Protocol (gRPC <-> REST)"
            echo -e "    ${C_GREEN}[9]${RST}  🛡️  Regenerate Node Self-Signed SSL (SAN Enabled)"
            echo -e "    ${C_GREEN}[10]${RST} ⚙️  Manage Systemd Service"
            echo -e "    ${C_GREEN}[11]${RST} 📦 Update / Change Xray-core"
            echo -e "    ${C_GREEN}[12]${RST} 🔄 Update PasarGuard Node Software"
            echo -e "    ${C_GREEN}[13]${RST} 🗺️  Update GeoFiles (GeoIP & GeoSite)"
            echo -e "    ${C_GREEN}[14]${RST} 🔑 Set / Regenerate Node API Key"
            echo -e "    ${C_GREEN}[15]${RST} 🔌 Reconfigure Ports (Service & API)"

            echo -e "\n  ${BOLD}${C_RED}🗑️  DANGER ZONE & CLEANUP:${RST}"
            echo -e "    ${C_GRAY}[16]${RST} 🗑️  Delete from Local Inventory Only"
            echo -e "    ${C_RED}[17]${RST} 💣 Completely Uninstall Node & Clean DNS"
            echo -e "    ${C_GRAY}[0]${RST}   🔙 Back to Node List"

            read -rp "$(echo -e "\n  ${C_PURPLE}▶ Choose Action [0-17]: ${RST}")" N_ACT < /dev/tty

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
                    inspect_node_ssl_details "$target_ip" "$target_port" "$target_user" "$target_pass" "$target_host" "$target_bdom"
                    ;;
                4)
                    ui_sub_banner
                    echo -e "  ${BOLD}${C_CYAN}📤 INJECT / OVERWRITE WILDCARD SSL ON NODE: $target_host${RST}\n"
                    list_domain_profiles
                    local dc; dc=$(get_domains_count)
                    if [ "$dc" -eq 0 ]; then
                        read -rp "  Press [ENTER] to return..." < /dev/tty
                    else
                        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Domain to Deploy onto this Node [1-$dc, or 0 to cancel]: ${RST}")" SEL_D < /dev/tty
                        if [[ "$SEL_D" =~ ^[0-9]+$ ]] && [ "$SEL_D" -ge 1 ] && [ "$SEL_D" -le "$dc" ]; then
                            local chosen_dom; chosen_dom=$(jq -r ".[$((SEL_D - 1))].domain" "$DOMAINS_FILE")
                            local local_cert="/etc/letsencrypt/live/$chosen_dom/fullchain.pem"
                            local local_key="/etc/letsencrypt/live/$chosen_dom/privkey.pem"

                            if [ -f "$local_cert" ] && [ -f "$local_key" ]; then
                                log INFO "Pushing Wildcard SSL for *.$chosen_dom to $target_host ($target_ip)..."
                                sshpass -p "$target_pass" ssh -p "$target_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$target_user@$target_ip" "mkdir -p /var/lib/pg-node/certs/$chosen_dom"
                                sshpass -p "$target_pass" scp -P "$target_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$local_cert" "$target_user@$target_ip:/var/lib/pg-node/certs/$chosen_dom/fullchain.pem" >/dev/null
                                sshpass -p "$target_pass" scp -P "$target_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$local_key" "$target_user@$target_ip:/var/lib/pg-node/certs/$chosen_dom/privkey.pem" >/dev/null

                                sshpass -p "$target_pass" ssh -p "$target_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$target_user@$target_ip" \
                                    "cp -f /var/lib/pg-node/certs/$chosen_dom/fullchain.pem /var/lib/pg-node/certs/ssl_cert.pem && cp -f /var/lib/pg-node/certs/$chosen_dom/privkey.pem /var/lib/pg-node/certs/ssl_key.pem && docker restart node 2>/dev/null || true; systemctl restart pg-node-service 2>/dev/null || true"

                                log OK "Wildcard SSL for *.$chosen_dom applied successfully to $target_host!"
                            fi
                        fi
                        read -rp "  Press [ENTER] to continue..." < /dev/tty
                    fi
                    ;;
                5)
                    toggle_node_bbr "$target_ip" "$target_port" "$target_user" "$target_pass" "$target_host"
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                6)
                    eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node restart -y 2>/dev/null || true'"
                    log OK "Node service restarted."
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                7)
                    eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node logs'"
                    ;;
                8)
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
                9)
                    generate_node_self_signed "$target_ip" "$target_port" "$target_user" "$target_pass" "$target_host"
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                10)
                    eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node service'"
                    ;;
                11)
                    eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node xray'"
                    ;;
                12)
                    eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node update -y 2>/dev/null || true'"
                    log OK "PasarGuard node software update triggered."
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    ;;
                13)
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
                16)
                    local tmp_d; tmp_d=$(mktemp)
                    jq "del(.[$idx_pos])" "$NODES_FILE" > "$tmp_d" && mv "$tmp_d" "$NODES_FILE"
                    log OK "Node removed from local inventory."
                    read -rp "  Press [ENTER] to continue..." < /dev/tty
                    break
                    ;;
                17)
                    read -rp "  Type 'yes' to completely uninstall node and clean DNS: " PURGE_C < /dev/tty
                    if [ "$PURGE_C" == "yes" ]; then
                        eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; echo -e \"y\\ny\" | pg-node uninstall 2>/dev/null || true; docker rm -f node 2>/dev/null || true; systemctl stop pg-node pg-node-service 2>/dev/null || true; rm -rf /opt/pg-node /var/lib/pg-node /usr/local/bin/pg-node /usr/bin/pg-node /etc/systemd/system/pg-node*.service; systemctl daemon-reload 2>/dev/null || true; ufw delete allow $target_sport/tcp 2>/dev/null || true'"
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
        echo -e "  ${C_CYAN}[3]${RST} 🔗 Attach Existing Active Node (Auto-Discover & Multi-SSL Sync)"
        echo -e "  ${C_GRAY}[0]  Back to Main Dashboard${RST}"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-3]: ${RST}")" NM_OPT < /dev/tty
        case "$NM_OPT" in
            1) deploy_new_node ;;
            2) manage_saved_nodes ;;
            3) add_existing_active_node ;;
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
                    echo -e "  ${BOLD}${C_CYAN}📋 DNS PRESETS TEMPLATES MANAGEMENT${RST}\n"
                    local p_keys=()
                    while IFS= read -r k; do [ -n "$k" ] && p_keys+=("$k"); done < <(jq -r 'keys[]' "$PRESETS_FILE" 2>/dev/null)

                    if [ ${#p_keys[@]} -eq 0 ]; then
                        echo -e "  ${C_YELLOW}No presets defined yet.${RST}\n"
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
                    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" P_SUB_OPT < /dev/tty

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
