#!/bin/bash

# ==============================================================================
# PasarGuard Multi-Node Auto-Deployer
# Modular Architecture: Nodes | Domains & SSL | Cloudflare DNS | Backup & Logs
# ==============================================================================

set -o pipefail

REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
APP_DIR="$(cd "$(dirname "$REAL_PATH")" && pwd)"
DOMAINS_FILE="$APP_DIR/domains.json"
NODES_FILE="$APP_DIR/nodes.json"
PRESETS_FILE="$APP_DIR/dns_presets.json"
BACKUP_DIR="$APP_DIR/backups"
LOG_FILE="$APP_DIR/deployer.log"

COLOR_RESET="\e[0m"
COLOR_GREEN="\e[32m"
COLOR_RED="\e[31m"
COLOR_YELLOW="\e[33m"
COLOR_BLUE="\e[34m"
COLOR_CYAN="\e[36m"
COLOR_BOLD="\e[1m"

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "[$timestamp] [$level] $message" >> "$LOG_FILE"
    case "$level" in
        INFO)  echo -e "${COLOR_BLUE}[*]${COLOR_RESET} $message" ;;
        OK)    echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $message" ;;
        WARN)  echo -e "${COLOR_YELLOW}[!]${COLOR_RESET} $message" ;;
        ERROR) echo -e "${COLOR_RED}[✗]${COLOR_RESET} $message" ;;
    esac
}

install_base_tools() {
    local missing_pkgs=()
    for pkg in jq sshpass curl certbot python3-certbot-dns-cloudflare tar; do
        if ! command -v "$pkg" >/dev/null 2>&1 && ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log INFO "Installing required dependencies: ${missing_pkgs[*]}..."
        sudo apt-get update -qq
        sudo apt-get install -qq -y "${missing_pkgs[@]}" >/dev/null 2>&1
        log OK "Base dependencies installed."
    fi
}

init_db() {
    [ ! -f "$DOMAINS_FILE" ] && echo '[]' > "$DOMAINS_FILE"
    [ ! -f "$NODES_FILE" ] && echo '[]' > "$NODES_FILE"
    [ ! -f "$PRESETS_FILE" ] && echo '{"default": ["sub1", "cdn", "direct", "vpn"]}' > "$PRESETS_FILE"
    mkdir -p "$BACKUP_DIR"
}

get_domains_count() {
    jq '. | length' "$DOMAINS_FILE"
}

list_domain_profiles() {
    local count
    count=$(get_domains_count)
    if [ "$count" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}No domain profiles registered yet.${COLOR_RESET}"
        return 1
    fi
    echo -e "${COLOR_CYAN}Registered Domain Profiles:${COLOR_RESET}"
    jq -r 'to_entries[] | "  [" + ((.key + 1) | tostring) + "] " + .value.domain + " - Zone: " + .value.zone_id' "$DOMAINS_FILE"
    return 0
}

upsert_cloudflare_dns() {
    local zone_id="$1"
    local token="$2"
    local record_name="$3"
    local ip_address="$4"
    local comment_text="$5"

    local rec_type="A"
    [[ "$ip_address" == *:* ]] && rec_type="AAAA"

    local query_res rec_id
    query_res=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?name=$record_name&type=$rec_type" \
         -H "Authorization: Bearer $token" \
         -H "Content-Type: application/json")

    rec_id=$(echo "$query_res" | jq -r --arg ip "$ip_address" '.result[]? | select(.content == $ip) | .id' | head -n 1)

    if [ -n "$rec_id" ]; then
        curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$rec_id" \
             -H "Authorization: Bearer $token" \
             -H "Content-Type: application/json" \
             --data "{\"comment\":\"$comment_text\"}" >/dev/null
        log OK "DNS $record_name ($rec_type) active. Comment updated: [$comment_text]"
    else
        local post_res
        post_res=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
             -H "Authorization: Bearer $token" \
             -H "Content-Type: application/json" \
             --data "{\"type\":\"$rec_type\",\"name\":\"$record_name\",\"content\":\"$ip_address\",\"ttl\":1,\"proxied\":false,\"comment\":\"$comment_text\"}")

        if echo "$post_res" | jq -e '.success' >/dev/null 2>&1; then
            log OK "Created DNS: $record_name ($rec_type: $ip_address)"
        else
            local err_msg
            err_msg=$(echo "$post_res" | jq -r '.errors[0].message // "Unknown error"')
            log WARN "Could not create DNS $record_name: $err_msg"
        fi
    fi
}

# ==============================================================================
# SECTION 1: NODE MANAGEMENT
# ==============================================================================

deploy_new_node() {
    echo -e "\n${COLOR_BOLD}${COLOR_CYAN}--- Deploy New PasarGuard Node ---${COLOR_RESET}"
    if ! list_domain_profiles; then
        echo -e "${COLOR_YELLOW}Please add a domain profile first in Domain & SSL Manager.${COLOR_RESET}"
        return 1
    fi

    local count
    count=$(get_domains_count)
    read -rp "Select Main Domain Profile for Node [1-$count]: " DOM_IDX
    if ! [[ "$DOM_IDX" =~ ^[0-9]+$ ]] || [ "$DOM_IDX" -lt 1 ] || [ "$DOM_IDX" -gt "$count" ]; then
        log ERROR "Invalid profile selection."
        return 1
    fi

    local selected_domain selected_token selected_zone
    selected_domain=$(jq -r ".[$((DOM_IDX - 1))].domain" "$DOMAINS_FILE")
    selected_token=$(jq -r ".[$((DOM_IDX - 1))].token" "$DOMAINS_FILE")
    selected_zone=$(jq -r ".[$((DOM_IDX - 1))].zone_id" "$DOMAINS_FILE")

    read -rp "Node Hostname (e.g. node-DE1): " NODE_NAME
    NODE_NAME=${NODE_NAME:-"node-DE1"}
    
    read -rp "Primary Server IPv4 (SSH & Panel Connection): " NODE_IP
    read -rp "Server IPv6 (leave blank if none): " NODE_IPV6
    NODE_IPV6=$(echo "$NODE_IPV6" | tr -d ' ')
    read -rp "Additional IPv4s on this server (comma-separated, or Enter): " EXTRA_IPS
    
    read -rp "SSH Port [22]: " NODE_SSH_PORT
    NODE_SSH_PORT=${NODE_SSH_PORT:-22}
    read -rp "SSH User [root]: " NODE_SSH_USER
    NODE_SSH_USER=${NODE_SSH_USER:-root}
    read -rsp "SSH Password: " NODE_SSH_PASS
    echo ""

    echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Guide: Enter only the subdomain prefix for node panel connection.${COLOR_RESET}"
    echo -e "Example: If you enter '${COLOR_BOLD}de1${COLOR_RESET}', address will be '${COLOR_BOLD}de1.$selected_domain${COLOR_RESET}'"
    echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
    read -rp "Subdomain prefix for node [de1]: " SUBDOMAIN_PREFIX
    SUBDOMAIN_PREFIX=${SUBDOMAIN_PREFIX:-"de1"}

    echo -e "\n${COLOR_CYAN}Port Configuration (Aligned with PasarGuard Panel):${COLOR_RESET}"
    read -rp "Node Port (gRPC/REST Server Port for Panel) [62051]: " SERVICE_PORT
    SERVICE_PORT=${SERVICE_PORT:-62051}
    read -rp "Advanced API Port (node-serviced Background Port) [62050]: " API_PORT
    API_PORT=${API_PORT:-62050}

    echo -e "\n${COLOR_CYAN}Protocol Configuration:${COLOR_RESET}"
    read -rp "Select Protocol: [1] gRPC (Recommended/Default) or [2] REST [1]: " PROTO_CHOICE
    local PROTO_FLAG="--use-grpc"
    local PROTO_NAME="grpc"
    if [ "$PROTO_CHOICE" == "2" ] || [[ "$PROTO_CHOICE" =~ ^[Rr] ]]; then
        PROTO_FLAG="--use-rest"
        PROTO_NAME="rest"
    fi
    log INFO "Selected protocol: $PROTO_NAME"

    echo -e "\n${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Cloudflare DNS Auto-Pointing Presets:${COLOR_RESET}"
    local p_keys=()
    while IFS= read -r k; do
        p_keys+=("$k")
    done < <(jq -r 'keys[]' "$PRESETS_FILE")

    for i in "${!p_keys[@]}"; do
        local p_name="${p_keys[$i]}"
        local p_records
        p_records=$(jq -c --arg k "$p_name" '.[$k]' "$PRESETS_FILE")
        echo -e "  [$((i + 1))] Preset: ${COLOR_GREEN}$p_name${COLOR_RESET} -> $p_records"
    done
    echo "  [0] Custom / Skip Presets"
    read -rp "Select DNS Preset [1-${#p_keys[@]} or 0]: " P_SEL

    local preset_subs=()
    if [[ "$P_SEL" =~ ^[1-9][0-9]*$ ]] && [ "$P_SEL" -le "${#p_keys[@]}" ]; then
        local chosen_key="${p_keys[$((P_SEL - 1))]}"
        while IFS= read -r sub_val; do
            preset_subs+=("$sub_val")
        done < <(jq -r --arg k "$chosen_key" '.[$k][]' "$PRESETS_FILE")
        log INFO "Loaded DNS Preset '$chosen_key': ${preset_subs[*]}"
    fi

    read -rp "Additional Custom Subdomains (comma-separated, or Enter to skip): " MANUAL_SUBS

    echo -e "\n${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Multi-Domain SSL Pre-Deployment:${COLOR_RESET}"
    echo -e "Select domain certificates to upload into this node (for multi-inbounds):"
    jq -r 'to_entries[] | "  [" + ((.key + 1) | tostring) + "] " + .value.domain' "$DOMAINS_FILE"
    echo -e "Enter profile numbers (e.g. '1, 2' or press ENTER for main domain only)"
    echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
    read -rp "Select Domain Profiles: " EXTRA_DOM_IDXS

    read -rp "Install PasarGuard Node binary? [Y/n]: " INSTALL_PG
    INSTALL_PG=${INSTALL_PG:-Y}

    local SYSTEMD_FLAG="--install-service"
    if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
        read -rp "Install and start systemd background service? [Y/n]: " ASK_SYSTEMD
        ASK_SYSTEMD=${ASK_SYSTEMD:-Y}
        if ! [[ "$ASK_SYSTEMD" =~ ^[Yy]$ ]]; then
            SYSTEMD_FLAG="--no-install-service"
        fi
    fi

    local full_hostname="$SUBDOMAIN_PREFIX.$selected_domain"
    local cert_src="/etc/letsencrypt/live/$selected_domain/cert.pem"
    [ ! -f "$cert_src" ] && cert_src="/etc/letsencrypt/live/$selected_domain/fullchain.pem"
    local fullchain_src="/etc/letsencrypt/live/$selected_domain/fullchain.pem"
    local key_src="/etc/letsencrypt/live/$selected_domain/privkey.pem"

    if [ ! -f "$cert_src" ] || [ ! -f "$key_src" ]; then
        log ERROR "Certificates not found for $selected_domain in Let's Encrypt directory."
        return 1
    fi

    log INFO "Validating SSH connection to $NODE_IP:$NODE_SSH_PORT..."
    if ! sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$NODE_SSH_USER@$NODE_IP" "echo connected" >/dev/null 2>&1; then
        log ERROR "Cannot connect via SSH. Verify IP, port, and password."
        return 1
    fi
    log OK "SSH connection established."

    log INFO "Applying system configurations on remote node..."
    sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no "$NODE_SSH_USER@$NODE_IP" bash << REMOTE_INIT
export DEBIAN_FRONTEND=noninteractive
hostnamectl set-hostname "$NODE_NAME" || true
modprobe tcp_bbr 2>/dev/null || true
echo "net.core.default_qdisc=fq" > /etc/sysctl.d/99-bbr.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-bbr.conf
sysctl --system >/dev/null 2>&1 || true
apt-get update -qq
apt-get upgrade -qq -y
ufw allow $SERVICE_PORT/tcp >/dev/null 2>&1 || true
ufw allow $API_PORT/tcp >/dev/null 2>&1 || true
mkdir -p /tmp/node_ssl /var/lib/pg-node/certs /var/lib/pasarguard/ssl /opt/pg-node
REMOTE_INIT

    log INFO "Transferring Wildcard SSL source files for $selected_domain to remote node..."
    cat "$fullchain_src" | sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no "$NODE_SSH_USER@$NODE_IP" "cat > /tmp/node_ssl/cert.pem && chmod 644 /tmp/node_ssl/cert.pem"
    cat "$key_src" | sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no "$NODE_SSH_USER@$NODE_IP" "cat > /tmp/node_ssl/key.pem && chmod 600 /tmp/node_ssl/key.pem"
    log OK "Main Wildcard SSL uploaded successfully."

    local installed_ssl_domains=("$selected_domain")
    if [ -n "$EXTRA_DOM_IDXS" ]; then
        IFS=',' read -ra EXTRA_DOM_ARR <<< "$EXTRA_DOM_IDXS"
        for ed_idx in "${EXTRA_DOM_ARR[@]}"; do
            ed_idx=$(echo "$ed_idx" | tr -d ' ')
            if [[ "$ed_idx" =~ ^[0-9]+$ ]] && [ "$ed_idx" -ge 1 ] && [ "$ed_idx" -le "$count" ]; then
                local extra_dom
                extra_dom=$(jq -r ".[$((ed_idx - 1))].domain" "$DOMAINS_FILE")
                if [ "$extra_dom" != "$selected_domain" ]; then
                    local e_fullchain="/etc/letsencrypt/live/$extra_dom/fullchain.pem"
                    local e_key="/etc/letsencrypt/live/$extra_dom/privkey.pem"
                    if [ -f "$e_fullchain" ] && [ -f "$e_key" ]; then
                        log INFO "Injecting additional Wildcard SSL for $extra_dom..."
                        sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no "$NODE_SSH_USER@$NODE_IP" "mkdir -p /var/lib/pg-node/certs/$extra_dom"
                        cat "$e_fullchain" | sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no "$NODE_SSH_USER@$NODE_IP" "cat > /var/lib/pg-node/certs/$extra_dom/fullchain.pem && chmod 644 /var/lib/pg-node/certs/$extra_dom/fullchain.pem"
                        cat "$e_key" | sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no "$NODE_SSH_USER@$NODE_IP" "cat > /var/lib/pg-node/certs/$extra_dom/privkey.pem && chmod 600 /var/lib/pg-node/certs/$extra_dom/privkey.pem"
                        installed_ssl_domains+=("$extra_dom")
                        log OK "Injected SSL for: $extra_dom"
                    fi
                fi
            fi
        done
    fi

    local node_comment="PG-Node: $NODE_NAME | Main-IPv4"
    upsert_cloudflare_dns "$selected_zone" "$selected_token" "$full_hostname" "$NODE_IP" "$node_comment"
    
    if [ -n "$NODE_IPV6" ]; then
        local node_v6_comment="PG-Node: $NODE_NAME | Main-IPv6"
        upsert_cloudflare_dns "$selected_zone" "$selected_token" "$full_hostname" "$NODE_IPV6" "$node_v6_comment"
    fi

    local all_server_ips=("$NODE_IP")
    if [ -n "$EXTRA_IPS" ]; then
        IFS=',' read -ra E_IPS <<< "$EXTRA_IPS"
        for e_ip in "${E_IPS[@]}"; do
            e_ip=$(echo "$e_ip" | tr -d ' ')
            [ -n "$e_ip" ] && all_server_ips+=("$e_ip")
        done
    fi
    [ -n "$NODE_IPV6" ] && all_server_ips+=("$NODE_IPV6")

    local all_extra_subs=("${preset_subs[@]}")
    if [ -n "$MANUAL_SUBS" ]; then
        IFS=',' read -ra M_ARR <<< "$MANUAL_SUBS"
        for m_val in "${M_ARR[@]}"; do
            m_val=$(echo "$m_val" | tr -d ' ')
            [ -n "$m_val" ] && all_extra_subs+=("$m_val")
        done
    fi

    local created_dns_list=("$full_hostname ($NODE_IP)")
    [ -n "$NODE_IPV6" ] && created_dns_list+=("$full_hostname ($NODE_IPV6)")

    local ip_pool_idx=0
    for sub_item in "${all_extra_subs[@]}"; do
        if [ -n "$sub_item" ]; then
            local target_sub_ip="${all_server_ips[$ip_pool_idx]}"
            ip_pool_idx=$(( (ip_pool_idx + 1) % ${#all_server_ips[@]} ))

            local extra_full_sub="$sub_item.$selected_domain"
            local sub_comment="PG-Node: $NODE_NAME | Subdomain: $sub_item"
            upsert_cloudflare_dns "$selected_zone" "$selected_token" "$extra_full_sub" "$target_sub_ip" "$sub_comment"
            created_dns_list+=("$extra_full_sub ($target_sub_ip)")
        fi
    done

    local node_token="Not detected"
    if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
        log INFO "Installing PasarGuard Node cleanly ($PROTO_NAME mode)..."
        sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no "$NODE_SSH_USER@$NODE_IP" bash << REMOTE_INSTALL
export TERM=xterm-256color
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh -o /usr/local/bin/pg-node
chmod +x /usr/local/bin/pg-node
/usr/local/bin/pg-node install-script >/dev/null 2>&1 || true

/usr/local/bin/pg-node install -y --override $PROTO_FLAG --cert-path /tmp/node_ssl/cert.pem --key-path /tmp/node_ssl/key.pem --service-port $SERVICE_PORT --api-port $API_PORT $SYSTEMD_FLAG
/usr/local/bin/pg-node restart -n >/dev/null 2>&1 || true
rm -rf /tmp/node_ssl
REMOTE_INSTALL

        sleep 2
        local token_candidate
        token_candidate=$(sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no "$NODE_SSH_USER@$NODE_IP" "grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' /opt/pg-node/.env 2>/dev/null | head -n 1" || true)
        if [ -n "$token_candidate" ]; then
            node_token="$token_candidate"
        fi
    fi

    local leaf_cert
    leaf_cert=$(openssl x509 -in "$cert_src" 2>/dev/null || cat "$cert_src")

    local dns_json ssl_json ips_json
    dns_json=$(printf '%s\n' "${created_dns_list[@]}" | jq -R . | jq -s .)
    ssl_json=$(printf '%s\n' "${installed_ssl_domains[@]}" | jq -R . | jq -s .)
    ips_json=$(printf '%s\n' "${all_server_ips[@]}" | jq -R . | jq -s .)

    local tmp_node
    tmp_node=$(mktemp)
    jq --arg nm "$NODE_NAME" --arg ip "$NODE_IP" --arg pt "$NODE_SSH_PORT" --arg usr "$NODE_SSH_USER" \
       --arg pwd "$NODE_SSH_PASS" --arg dom "$full_hostname" --arg bdom "$selected_domain" \
       --arg sport "$SERVICE_PORT" --arg aport "$API_PORT" --arg tok "$node_token" --arg proto "$PROTO_NAME" \
       --argjson dns "$dns_json" --argjson ssls "$ssl_json" --argjson ips "$ips_json" \
       'map(select(.hostname != $nm)) + [{
          "hostname": $nm,
          "ip": $ip,
          "all_ips": $ips,
          "ssh_port": $pt,
          "ssh_user": $usr,
          "ssh_pass": $pwd,
          "address": $dom,
          "base_domain": $bdom,
          "service_port": $sport,
          "api_port": $aport,
          "api_token": $tok,
          "protocol": $proto,
          "dns_records": $dns,
          "ssl_domains": $ssls,
          "ssl_cert_path": "/var/lib/pg-node/certs/ssl_cert.pem",
          "ssl_key_path": "/var/lib/pg-node/certs/ssl_key.pem",
          "deployed_at": (now | todate)
       }]' "$NODES_FILE" > "$tmp_node" && mv "$tmp_node" "$NODES_FILE"

    echo -e "\n${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}       NODE DEPLOYMENT SUMMARY FOR PASARGUARD PANEL        ${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Node Name:${COLOR_RESET}        $NODE_NAME"
    echo -e "  ${COLOR_BOLD}Node Address:${COLOR_RESET}     $full_hostname"
    echo -e "  ${COLOR_BOLD}Node Port:${COLOR_RESET}        ${COLOR_GREEN}$SERVICE_PORT${COLOR_RESET}  --> [Enter in Panel 'Node Port']"
    echo -e "  ${COLOR_BOLD}API Port:${COLOR_RESET}         ${COLOR_YELLOW}$API_PORT${COLOR_RESET}  --> [Enter in Advanced Settings 'API Port']"
    echo -e "  ${COLOR_BOLD}Connection Type:${COLOR_RESET}  ${COLOR_CYAN}${PROTO_NAME^^}${COLOR_RESET}  --> [Select in Advanced Settings]"
    echo -e "  ${COLOR_BOLD}API Key:${COLOR_RESET}          ${COLOR_YELLOW}${node_token}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_BOLD}Active DNS Records on Cloudflare (with Label Comments):${COLOR_RESET}"
    for rec in "${created_dns_list[@]}"; do
        echo -e "  ${COLOR_GREEN}• $rec${COLOR_RESET}"
    done
    echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_BOLD}Available Multi-Domain SSLs on Node:${COLOR_RESET}"
    for dom_entry in "${installed_ssl_domains[@]}"; do
        if [ "$dom_entry" == "$selected_domain" ]; then
            echo -e "  ${COLOR_GREEN}• $dom_entry${COLOR_RESET} (Default: /var/lib/pg-node/certs/ssl_cert.pem)"
        else
            echo -e "  ${COLOR_GREEN}• $dom_entry${COLOR_RESET} (Path: /var/lib/pg-node/certs/$dom_entry/fullchain.pem)"
        fi
    done
    echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_BOLD}Certificate (Copy exactly into Panel Certificate box):${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}$leaf_cert${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}\n"
}

migrate_node_ip() {
    local n_idx="$1"
    local old_ip target_port target_user target_pass target_host target_addr target_bdom
    old_ip=$(jq -r ".[$n_idx].ip" "$NODES_FILE")
    target_port=$(jq -r ".[$n_idx].ssh_port" "$NODES_FILE")
    target_user=$(jq -r ".[$n_idx].ssh_user" "$NODES_FILE")
    target_pass=$(jq -r ".[$n_idx].ssh_pass" "$NODES_FILE")
    target_host=$(jq -r ".[$n_idx].hostname" "$NODES_FILE")
    target_addr=$(jq -r ".[$n_idx].address" "$NODES_FILE")
    target_bdom=$(jq -r ".[$n_idx].base_domain" "$NODES_FILE")

    echo -e "\n${COLOR_CYAN}${COLOR_BOLD}--- Migrate / Change IP for Node: $target_host ---${COLOR_RESET}"
    echo -e "Current Registered IP: ${COLOR_RED}$old_ip${COLOR_RESET}"
    read -rp "Enter NEW Server IPv4: " NEW_IP
    NEW_IP=$(echo "$NEW_IP" | tr -d ' ')
    [ -z "$NEW_IP" ] && { log ERROR "New IP cannot be empty."; return 1; }

    read -rp "Keep current SSH Password? [Y/n]: " KEEP_PASS
    KEEP_PASS=${KEEP_PASS:-Y}
    if ! [[ "$KEEP_PASS" =~ ^[Yy]$ ]]; then
        read -rsp "Enter new SSH Password: " target_pass
        echo ""
    fi

    log INFO "Validating SSH connectivity on new IP: $NEW_IP:$target_port..."
    if ! sshpass -p "$target_pass" ssh -p "$target_port" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$target_user@$NEW_IP" "echo connected" >/dev/null 2>&1; then
        log ERROR "Cannot connect to new IP via SSH."
        return 1
    fi
    log OK "SSH connection confirmed on new IP."

    local c_tok c_zid
    c_tok=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .token' "$DOMAINS_FILE")
    c_zid=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .zone_id' "$DOMAINS_FILE")

    if [ -n "$c_tok" ] && [ -n "$c_zid" ]; then
        log INFO "Migrating Cloudflare DNS records from $old_ip to $NEW_IP..."
        while IFS= read -r dns_name; do
            [ -z "$dns_name" ] && continue
            local clean_name
            clean_name=$(echo "$dns_name" | awk '{print $1}')
            
            local rec_id
            rec_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records?name=$clean_name&type=A" \
                 -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" | jq -r --arg oip "$old_ip" '.result[]? | select(.content == $oip) | .id' | head -n 1)

            local mig_comment="PG-Node: $target_host | Migrated to $NEW_IP at $(date '+%Y-%m-%d')"
            if [ -n "$rec_id" ]; then
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records/$rec_id" \
                     -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" \
                     --data "{\"type\":\"A\",\"name\":\"$clean_name\",\"content\":\"$NEW_IP\",\"ttl\":1,\"proxied\":false,\"comment\":\"$mig_comment\"}" >/dev/null
                log OK "Cloudflare record $clean_name updated -> $NEW_IP"
            else
                upsert_cloudflare_dns "$c_zid" "$c_tok" "$clean_name" "$NEW_IP" "$mig_comment"
            fi
        done < <(jq -r ".[$n_idx].dns_records[]? // empty" "$NODES_FILE")
    fi

    local tmp_mig
    tmp_mig=$(mktemp)
    jq --arg idx "$n_idx" --arg nip "$NEW_IP" --arg pwd "$target_pass" \
       '.[($idx|tonumber)].ip = $nip | .[($idx|tonumber)].ssh_pass = $pwd' "$NODES_FILE" > "$tmp_mig" && mv "$tmp_mig" "$NODES_FILE"

    log OK "Node IP migration completed successfully!"
}

manage_saved_nodes() {
    local count
    count=$(jq '. | length' "$NODES_FILE")
    if [ "$count" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}No deployed nodes registered.${COLOR_RESET}"
        return 0
    fi

    echo -e "\n${COLOR_CYAN}--- Saved Node Inventory ---${COLOR_RESET}"
    jq -r 'to_entries[] | "  [" + ((.key + 1) | tostring) + "] " + .value.hostname + " (" + .value.ip + ") - " + .value.address' "$NODES_FILE"

    read -rp "Select Node [1-$count]: " N_IDX
    if ! [[ "$N_IDX" =~ ^[0-9]+$ ]] || [ "$N_IDX" -lt 1 ] || [ "$N_IDX" -gt "$count" ]; then
        log ERROR "Invalid selection."
        return 1
    fi

    local target_ip target_port target_user target_pass target_host target_addr target_sport target_aport target_token target_bdom target_proto
    target_ip=$(jq -r ".[$((N_IDX - 1))].ip" "$NODES_FILE")
    target_port=$(jq -r ".[$((N_IDX - 1))].ssh_port" "$NODES_FILE")
    target_user=$(jq -r ".[$((N_IDX - 1))].ssh_user" "$NODES_FILE")
    target_pass=$(jq -r ".[$((N_IDX - 1))].ssh_pass" "$NODES_FILE")
    target_host=$(jq -r ".[$((N_IDX - 1))].hostname" "$NODES_FILE")
    target_addr=$(jq -r ".[$((N_IDX - 1))].address" "$NODES_FILE")
    target_sport=$(jq -r ".[$((N_IDX - 1))].service_port // 62051" "$NODES_FILE")
    target_aport=$(jq -r ".[$((N_IDX - 1))].api_port // 62050" "$NODES_FILE")
    target_token=$(jq -r ".[$((N_IDX - 1))].api_token // empty" "$NODES_FILE")
    target_proto=$(jq -r ".[$((N_IDX - 1))].protocol // 'grpc'" "$NODES_FILE")
    target_bdom=$(jq -r ".[$((N_IDX - 1))].base_domain" "$NODES_FILE")

    local ssh_cmd="sshpass -p '$target_pass' ssh -p $target_port -o StrictHostKeyChecking=no $target_user@$target_ip"

    if [ -z "$target_token" ] || [[ "$target_token" == *"#"* ]] || [ "$target_token" == "Not detected" ] || [ ${#target_token} -ne 36 ]; then
        local live_tok
        live_tok=$(eval "$ssh_cmd 'grep -oE \"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\" /opt/pg-node/.env 2>/dev/null | head -n 1' || true")
        if [ -n "$live_tok" ]; then
            target_token="$live_tok"
            local tmp_sync
            tmp_sync=$(mktemp)
            jq --arg idx "$((N_IDX - 1))" --arg tok "$live_tok" '.[($idx|tonumber)].api_token = $tok' "$NODES_FILE" > "$tmp_sync" && mv "$tmp_sync" "$NODES_FILE"
        fi
    fi

    echo -e "\nActions for node: ${COLOR_BOLD}$target_host ($target_ip)${COLOR_RESET}"
    echo "  1) View Panel Connection Info (Address, Ports, Token & Full Card)"
    echo -e "  2) ${COLOR_GREEN}${COLOR_BOLD}Migrate / Change Server IP (1-Click Auto DNS & Config Update)${COLOR_RESET}"
    echo "  3) Manage & Sync Multi-Domain SSLs (Inject Domain Certs)"
    echo "  4) Add Extra Cloudflare DNS Record with Label"
    echo "  5) Switch Protocol (gRPC <-> REST)"
    echo "  6) Manage Systemd Service (Install / Uninstall)"
    echo "  7) Update / Change Xray-core"
    echo "  8) Update PasarGuard Node Software (pg-node update)"
    echo "  9) Download / Update GeoFiles (GeoIP & GeoSite)"
    echo "  10) Restart Node Service"
    echo "  11) View Live Node Logs (pg-node logs)"
    echo "  12) Delete Node from Local Inventory Only"
    echo "  13) Completely Uninstall Node from Server, Cloudflare & Inventory"
    echo "  0) Back"
    read -rp "Action [0-13]: " N_ACT

    case "$N_ACT" in
        1)
            local cert_data single_cert
            cert_data=$(eval "$ssh_cmd 'cat /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || cat /var/lib/pasarguard/ssl/cert.pem 2>/dev/null'" || true)
            single_cert=$(echo "$cert_data" | openssl x509 2>/dev/null || echo "$cert_data")
            
            echo -e "\n${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}"
            echo -e "${COLOR_GREEN}${COLOR_BOLD}            PASARGUARD PANEL CONNECTION DETAILS            ${COLOR_RESET}"
            echo -e "${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}"
            echo -e "  ${COLOR_BOLD}Node Name:${COLOR_RESET}        $target_host"
            echo -e "  ${COLOR_BOLD}Node Address:${COLOR_RESET}     $target_addr"
            echo -e "  ${COLOR_BOLD}Node Port:${COLOR_RESET}        ${COLOR_GREEN}$target_sport${COLOR_RESET}  --> [Set in Panel 'Node Port']"
            echo -e "  ${COLOR_BOLD}API Port:${COLOR_RESET}         ${COLOR_YELLOW}$target_aport${COLOR_RESET}  --> [Set in Advanced Settings 'API Port']"
            echo -e "  ${COLOR_BOLD}Connection Type:${COLOR_RESET}  ${COLOR_CYAN}${target_proto^^}${COLOR_RESET}  --> [Select in Advanced Settings]"
            echo -e "  ${COLOR_BOLD}API Key:${COLOR_RESET}          ${COLOR_YELLOW}${target_token:-Not found}${COLOR_RESET}"
            echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
            echo -e "${COLOR_BOLD}Registered Cloudflare DNS Records:${COLOR_RESET}"
            jq -r ".[$((N_IDX - 1))].dns_records[]? // empty" "$NODES_FILE" | while read -r drec; do
                echo -e "  ${COLOR_GREEN}• $drec${COLOR_RESET}"
            done
            echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
            echo -e "${COLOR_BOLD}SSL Domains Available on this Node:${COLOR_RESET}"
            jq -r ".[$((N_IDX - 1))].ssl_domains[]? // empty" "$NODES_FILE" | while read -r sdom; do
                if [ "$sdom" == "$target_bdom" ]; then
                    echo -e "  ${COLOR_GREEN}• $sdom${COLOR_RESET} (Default: /var/lib/pg-node/certs/ssl_cert.pem)"
                else
                    echo -e "  ${COLOR_GREEN}• $sdom${COLOR_RESET} (Custom: /var/lib/pg-node/certs/$sdom/fullchain.pem)"
                fi
            done
            echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
            echo -e "${COLOR_BOLD}Certificate (Copy exactly into Panel Certificate box):${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}$single_cert${COLOR_RESET}"
            echo -e "${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}\n"
            ;;
        2) migrate_node_ip "$((N_IDX - 1))" ;;
        3)
            echo -e "\n${COLOR_CYAN}--- Manage & Sync Multi-Domain SSLs ---${COLOR_RESET}"
            list_domain_profiles
            local d_count
            d_count=$(get_domains_count)
            read -rp "Select Domain Profile to Inject to Node [1-$d_count]: " INJ_IDX
            if [[ "$INJ_IDX" =~ ^[0-9]+$ ]] && [ "$INJ_IDX" -ge 1 ] && [ "$INJ_IDX" -le "$d_count" ]; then
                local inj_dom
                inj_dom=$(jq -r ".[$((INJ_IDX - 1))].domain" "$DOMAINS_FILE")
                local inj_fullchain="/etc/letsencrypt/live/$inj_dom/fullchain.pem"
                local inj_key="/etc/letsencrypt/live/$inj_dom/privkey.pem"
                if [ -f "$inj_fullchain" ] && [ -f "$inj_key" ]; then
                    log INFO "Uploading SSL for $inj_dom to $target_host..."
                    eval "$ssh_cmd 'mkdir -p /var/lib/pg-node/certs/$inj_dom'"
                    cat "$inj_fullchain" | eval "$ssh_cmd 'cat > /var/lib/pg-node/certs/$inj_dom/fullchain.pem && chmod 644 /var/lib/pg-node/certs/$inj_dom/fullchain.pem'"
                    cat "$inj_key" | eval "$ssh_cmd 'cat > /var/lib/pg-node/certs/$inj_dom/privkey.pem && chmod 600 /var/lib/pg-node/certs/$inj_dom/privkey.pem'"
                    
                    local tmp_mupd
                    tmp_mupd=$(mktemp)
                    jq --arg idx "$((N_IDX - 1))" --arg ndom "$inj_dom" \
                       '.[($idx|tonumber)].ssl_domains = ((.[($idx|tonumber)].ssl_domains // []) + [$ndom] | unique)' \
                       "$NODES_FILE" > "$tmp_mupd" && mv "$tmp_mupd" "$NODES_FILE"
                    log OK "SSL for $inj_dom injected at /var/lib/pg-node/certs/$inj_dom/"
                fi
            fi
            ;;
        4)
            read -rp "Enter new subdomain prefix (e.g. proxy2): " NEW_SUB
            NEW_SUB=$(echo "$NEW_SUB" | tr -d ' ')
            read -rp "Target IP [Default: $target_ip]: " CHOSEN_IP
            CHOSEN_IP=${CHOSEN_IP:-"$target_ip"}

            if [ -n "$NEW_SUB" ]; then
                local new_full_rec="$NEW_SUB.$target_bdom"
                local c_tok c_zid
                c_tok=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .token' "$DOMAINS_FILE")
                c_zid=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .zone_id' "$DOMAINS_FILE")
                if [ -n "$c_tok" ] && [ -n "$c_zid" ]; then
                    local rec_comment="PG-Node: $target_host | Custom: $NEW_SUB"
                    upsert_cloudflare_dns "$c_zid" "$c_tok" "$new_full_rec" "$CHOSEN_IP" "$rec_comment"
                    
                    local tmp_dnsup
                    tmp_dnsup=$(mktemp)
                    jq --arg idx "$((N_IDX - 1))" --arg nrec "$new_full_rec ($CHOSEN_IP)" \
                       '.[($idx|tonumber)].dns_records = ((.[($idx|tonumber)].dns_records // []) + [$nrec] | unique)' \
                       "$NODES_FILE" > "$tmp_dnsup" && mv "$tmp_dnsup" "$NODES_FILE"
                fi
            fi
            ;;
        5)
            echo "  1) Use gRPC (Default) | 2) Use REST"
            read -rp "Select Protocol [1-2]: " PROTO_SEL
            local p_flag="--use-grpc" p_str="grpc"
            [ "$PROTO_SEL" == "2" ] && { p_flag="--use-rest"; p_str="rest"; }
            eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node install -y --override $p_flag --cert-path /var/lib/pg-node/certs/ssl_cert.pem --key-path /var/lib/pg-node/certs/ssl_key.pem --service-port $target_sport --api-port $target_aport'"
            local tmp_upd
            tmp_upd=$(mktemp)
            jq --arg idx "$((N_IDX - 1))" --arg ps "$p_str" '.[($idx|tonumber)].protocol = $ps' "$NODES_FILE" > "$tmp_upd" && mv "$tmp_upd" "$NODES_FILE"
            log OK "Switched to $p_str protocol."
            ;;
        6)
            echo "  1) Install Service | 2) Remove Service"
            read -rp "Action [1-2]: " SYS_SEL
            [ "$SYS_SEL" == "1" ] && eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node service-install'"
            [ "$SYS_SEL" == "2" ] && eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node service-uninstall'"
            ;;
        7)
            read -rp "Enter Xray version [latest]: " X_VER
            X_VER=${X_VER:-latest}
            eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node core-update --version $X_VER'"
            ;;
        8) eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node update -y'" ;;
        9) eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node geofiles'" ;;
        10) eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node restart -n 2>/dev/null || true'"; log OK "Restarted." ;;
        11) eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node logs'" ;;
        12)
            local tmp_d
            tmp_d=$(mktemp)
            jq "del(.[$((N_IDX - 1))])" "$NODES_FILE" > "$tmp_d" && mv "$tmp_d" "$NODES_FILE"
            log OK "Node removed from local inventory."
            ;;
        13)
            echo -e "${COLOR_RED}${COLOR_BOLD}WARNING: Will wipe node software, DNS records and inventory.${COLOR_RESET}"
            read -rp "Type 'yes' to confirm: " CONFIRM_PURGE
            if [ "$CONFIRM_PURGE" == "yes" ]; then
                eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node uninstall -y 2>/dev/null || true; rm -rf /opt/pg-node /var/lib/pg-node /var/lib/pasarguard /usr/local/bin/pg-node; ufw delete allow $target_sport/tcp 2>/dev/null || true; ufw delete allow $target_aport/tcp 2>/dev/null || true'"
                local cf_tok cf_zid
                cf_tok=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .token' "$DOMAINS_FILE")
                cf_zid=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .zone_id' "$DOMAINS_FILE")
                if [ -n "$cf_tok" ] && [ -n "$cf_zid" ]; then
                    jq -r ".[$((N_IDX - 1))].dns_records[]? // empty" "$NODES_FILE" | while read -r r_to_del; do
                        local clean_name
                        clean_name=$(echo "$r_to_del" | awk '{print $1}')
                        local rec_id
                        rec_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$cf_zid/dns_records?name=$clean_name" \
                             -H "Authorization: Bearer $cf_tok" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
                        [ -n "$rec_id" ] && curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$cf_zid/dns_records/$rec_id" -H "Authorization: Bearer $cf_tok" -H "Content-Type: application/json" >/dev/null
                    done
                fi
                local tmp_del
                tmp_del=$(mktemp)
                jq "del(.[$((N_IDX - 1))])" "$NODES_FILE" > "$tmp_del" && mv "$tmp_del" "$NODES_FILE"
                log OK "Node completely wiped."
            fi
            ;;
        *) return 0 ;;
    esac
}

node_management_menu() {
    while true; do
        echo -e "\n${COLOR_CYAN}${COLOR_BOLD}+--------------------------------------------------------------------+${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}|                   [1] NODE MANAGEMENT CENTER                       |${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}+--------------------------------------------------------------------+${COLOR_RESET}"
        echo -e "  [1] Deploy New Node (Multi-IP, Multi-SSL & Zero Error)"
        echo -e "  [2] Manage Saved Nodes (Inspect, IP Migration, Protocol, Purge)"
        echo -e "  [0] Back to Main Menu"
        read -rp "Select Option [0-2]: " NM_OPT
        case "$NM_OPT" in
            1) deploy_new_node ;;
            2) manage_saved_nodes ;;
            0) break ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ==============================================================================
# SECTION 2: DOMAINS & SSL MANAGEMENT
# ==============================================================================

domain_management_menu() {
    while true; do
        echo -e "\n${COLOR_CYAN}${COLOR_BOLD}+--------------------------------------------------------------------+${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}|                   [2] DOMAINS & SSL MANAGER                        |${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}+--------------------------------------------------------------------+${COLOR_RESET}"
        echo -e "  [1] Issue New Wildcard SSL Certificate (Let's Encrypt + Cloudflare)"
        echo -e "  [2] Sync Existing Domain SSL to Local Master Web Panel"
        echo -e "  [3] Renew & Synchronize All SSLs (Master + All Nodes)"
        echo -e "  [4] List & Delete Registered Domain Profiles"
        echo -e "  [0] Back to Main Menu"
        read -rp "Select Option [0-4]: " DM_OPT
        case "$DM_OPT" in
            1) issue_wildcard_ssl ;;
            2)
                list_domain_profiles && {
                    read -rp "Select Domain Index: " D_IDX
                    D_SEL=$(jq -r ".[$((D_IDX - 1))].domain" "$DOMAINS_FILE")
                    sudo mkdir -p /var/lib/pasarguard/ssl /var/lib/pasarguard/certs /var/lib/pg-node/certs
                    base_name="${D_SEL%%.*}"
                    sudo cat "/etc/letsencrypt/live/$D_SEL/fullchain.pem" | sudo tee /var/lib/pasarguard/ssl/cert.pem /var/lib/pasarguard/certs/"$base_name".cer /var/lib/pasarguard/certs/cert.pem /var/lib/pg-node/certs/ssl_cert.pem >/dev/null
                    sudo cat "/etc/letsencrypt/live/$D_SEL/privkey.pem" | sudo tee /var/lib/pasarguard/ssl/key.pem /var/lib/pasarguard/certs/"$base_name".key /var/lib/pasarguard/certs/key.pem /var/lib/pg-node/certs/ssl_key.pem >/dev/null
                    sudo chmod 644 /var/lib/pasarguard/ssl/cert.pem /var/lib/pasarguard/certs/*.cer /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || true
                    sudo chmod 600 /var/lib/pasarguard/ssl/key.pem /var/lib/pasarguard/certs/*.key /var/lib/pg-node/certs/ssl_key.pem 2>/dev/null || true
                    pasarguard restart 2>/dev/null || docker compose -f /opt/pasarguard/docker-compose.yml restart 2>/dev/null || true
                    log OK "Master SSL synced and PasarGuard web panel restarted."
                }
                ;;
            3) renew_sync_all_ssl ;;
            4)
                list_domain_profiles || true
                read -rp "Enter Profile Index to Delete (or press Enter to cancel): " DEL_I
                if [[ "$DEL_I" =~ ^[0-9]+$ ]]; then
                    local tmp_m
                    tmp_m=$(mktemp)
                    jq "del(.[$((DEL_I - 1))])" "$DOMAINS_FILE" > "$tmp_m" && mv "$tmp_m" "$DOMAINS_FILE"
                    log OK "Profile deleted."
                fi
                ;;
            0) break ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ==============================================================================
# SECTION 3: CLOUDFLARE DNS CENTER (CLEAN IPS & PRESETS)
# ==============================================================================

manage_clean_ips_interactive() {
    if ! list_domain_profiles; then return; fi
    local d_count
    d_count=$(get_domains_count)
    read -rp "Select Target Domain Profile [1-$d_count]: " C_DOM_IDX
    if ! [[ "$C_DOM_IDX" =~ ^[0-9]+$ ]] || [ "$C_DOM_IDX" -lt 1 ] || [ "$C_DOM_IDX" -gt "$d_count" ]; then
        return
    fi

    local c_dom c_tok c_zid
    c_dom=$(jq -r ".[$((C_DOM_IDX - 1))].domain" "$DOMAINS_FILE")
    c_tok=$(jq -r ".[$((C_DOM_IDX - 1))].token" "$DOMAINS_FILE")
    c_zid=$(jq -r ".[$((C_DOM_IDX - 1))].zone_id" "$DOMAINS_FILE")

    while true; do
        echo -e "\n${COLOR_CYAN}${COLOR_BOLD}=== Clean IPs Center for: $c_dom ===${COLOR_RESET}"
        echo "  [1] Add Clean IPs to Subdomain (Round-Robin DNS)"
        echo "  [2] Interactive Records Table (Multi-Select, Edit & Delete)"
        echo "  [0] Back"
        read -rp "Select Option [0-2]: " CIP_OPT

        case "$CIP_OPT" in
            1)
                echo -e "\n${COLOR_YELLOW}Enter the exact subdomain to attach all Clean IPs to:${COLOR_RESET}"
                echo -e "Example: '${COLOR_BOLD}cdn${COLOR_RESET}' will point multiple IPs to '${COLOR_BOLD}cdn.$c_dom${COLOR_RESET}'"
                read -rp "Subdomain prefix [cdn]: " PREFIX
                PREFIX=${PREFIX:-"cdn"}
                local full_target_sub="$PREFIX.$c_dom"

                read -rp "ISP / Pool Label for Comments (e.g. MCI / MTN / CleanPool): " ISP_LABEL
                ISP_LABEL=${ISP_LABEL:-"Clean IP"}

                echo -e "\n${COLOR_YELLOW}Paste Clean IPs (comma, space, or newline separated):${COLOR_RESET}"
                read -rp "IPs: " RAW_IPS

                local clean_ip_arr=($(echo "$RAW_IPS" | tr ',' ' ' | tr '\n' ' '))
                local count_added=0

                for cip in "${clean_ip_arr[@]}"; do
                    cip=$(echo "$cip" | tr -d ' \r\n')
                    if [[ "$cip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$cip" == *:* ]]; then
                        local c_comment="PG-CleanIP: $ISP_LABEL | Added $(date '+%Y-%m-%d')"
                        upsert_cloudflare_dns "$c_zid" "$c_tok" "$full_target_sub" "$cip" "$c_comment"
                        count_added=$((count_added + 1))
                    fi
                done
                log OK "Successfully attached $count_added clean IPs to $full_target_sub"
                ;;

            2)
                log INFO "Loading Clean IP records from Cloudflare..."
                local raw_json
                raw_json=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records?per_page=100" \
                     -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json")

                local rec_ids=() rec_names=() rec_types=() rec_ips=() rec_comments=()
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    rec_ids+=("$(echo "$line" | jq -r '.id')")
                    rec_names+=("$(echo "$line" | jq -r '.name')")
                    rec_types+=("$(echo "$line" | jq -r '.type')")
                    rec_ips+=("$(echo "$line" | jq -r '.content')")
                    rec_comments+=("$(echo "$line" | jq -r '.comment // ""')")
                done < <(echo "$raw_json" | jq -c '.result[]? | select(.comment != null and (.comment | contains("PG-CleanIP")))')

                local total_found=${#rec_ids[@]}
                if [ "$total_found" -eq 0 ]; then
                    echo -e "${COLOR_YELLOW}No records tagged with PG-CleanIP found on $c_dom.${COLOR_RESET}"
                    continue
                fi

                echo -e "\n${COLOR_CYAN}${COLOR_BOLD}+----+---------------------------+-------+-----------------+----------------------------------------+${COLOR_RESET}"
                printf "${COLOR_CYAN}${COLOR_BOLD}| %-2s | %-25s | %-5s | %-15s | %-38s |${COLOR_RESET}\n" "#" "Subdomain" "Type" "IP Address" "Comment Tag"
                echo -e "${COLOR_CYAN}${COLOR_BOLD}+----+---------------------------+-------+-----------------+----------------------------------------+${COLOR_RESET}"
                for i in "${!rec_ids[@]}"; do
                    printf "| %-2d | %-25s | %-5s | %-15s | %-38s |\n" "$((i + 1))" "${rec_names[$i]}" "${rec_types[$i]}" "${rec_ips[$i]}" "${rec_comments[$i]}"
                done
                echo -e "${COLOR_CYAN}${COLOR_BOLD}+----+---------------------------+-------+-----------------+----------------------------------------+${COLOR_RESET}"

                echo -e "\n${COLOR_YELLOW}Selection Options:${COLOR_RESET}"
                echo -e "  • Enter numbers separated by commas (e.g. ${COLOR_BOLD}1,3,4${COLOR_RESET})"
                echo -e "  • Type '${COLOR_BOLD}all${COLOR_RESET}' (or '${COLOR_BOLD}a${COLOR_RESET}') to select all records"
                echo -e "  • Press ENTER to cancel"
                read -rp "Select records: " USER_SEL

                [ -z "$USER_SEL" ] && continue

                local selected_indices=()
                local lower_sel
                lower_sel=$(echo "$USER_SEL" | tr '[:upper:]' '[:lower:]' | xargs)

                if [[ "$lower_sel" =~ ^(all|a|al)$ ]]; then
                    for i in "${!rec_ids[@]}"; do selected_indices+=("$i"); done
                else
                    IFS=',' read -ra S_PARTS <<< "$USER_SEL"
                    for p in "${S_PARTS[@]}"; do
                        p=$(echo "$p" | tr -d ' ')
                        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le "$total_found" ]; then
                            selected_indices+=("$((p - 1))")
                        fi
                    done
                fi

                if [ ${#selected_indices[@]} -eq 0 ]; then
                    echo "No valid selection."
                    continue
                fi

                echo -e "\nAction for ${COLOR_GREEN}${#selected_indices[@]}${COLOR_RESET} selected record(s):"
                echo "  [1] Delete selected records from Cloudflare"
                echo "  [2] Batch Edit Comment / Tag"
                echo "  [3] Edit IP Address (Single record only)"
                echo "  [4] Batch Rename / Move Subdomain (Change record host name)"
                echo "  [0] Cancel"
                read -rp "Choose action [0-4]: " B_ACT

                case "$B_ACT" in
                    1)
                        read -rp "Are you sure you want to delete ${#selected_indices[@]} record(s)? [y/N]: " CONF_DEL
                        if [[ "$CONF_DEL" =~ ^[Yy]$ ]]; then
                            for s_idx in "${selected_indices[@]}"; do
                                local d_id="${rec_ids[$s_idx]}"
                                curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records/$d_id" \
                                     -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" >/dev/null
                                echo -e "  ${COLOR_RED}✓ Deleted:${COLOR_RESET} ${rec_names[$s_idx]} -> ${rec_ips[$s_idx]}"
                            done
                            log OK "Deleted ${#selected_indices[@]} clean IP records."
                        fi
                        ;;
                    2)
                        read -rp "Enter NEW Comment tag for selected records: " NEW_COMMENT
                        if [ -n "$NEW_COMMENT" ]; then
                            for s_idx in "${selected_indices[@]}"; do
                                local d_id="${rec_ids[$s_idx]}"
                                local full_cmt="PG-CleanIP: $NEW_COMMENT | Updated $(date '+%Y-%m-%d')"
                                curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records/$d_id" \
                                     -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" \
                                     --data "{\"comment\":\"$full_cmt\"}" >/dev/null
                                echo -e "  ${COLOR_GREEN}✓ Updated comment:${COLOR_RESET} ${rec_names[$s_idx]}"
                            done
                            log OK "Updated comments for ${#selected_indices[@]} records."
                        fi
                        ;;
                    3)
                        if [ ${#selected_indices[@]} -ne 1 ]; then
                            echo -e "${COLOR_RED}IP edit can only be performed on 1 record at a time.${COLOR_RESET}"
                        else
                            local single_i="${selected_indices[0]}"
                            read -rp "Enter new IP for ${rec_names[$single_i]}: " REPL_IP
                            REPL_IP=$(echo "$REPL_IP" | tr -d ' ')
                            if [ -n "$REPL_IP" ]; then
                                local d_id="${rec_ids[$single_i]}"
                                local n_type="A"
                                [[ "$REPL_IP" == *:* ]] && n_type="AAAA"
                                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records/$d_id" \
                                     -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" \
                                     --data "{\"type\":\"$n_type\",\"name\":\"${rec_names[$single_i]}\",\"content\":\"$REPL_IP\",\"ttl\":1,\"proxied\":false,\"comment\":\"${rec_comments[$single_i]}\"}" >/dev/null
                                log OK "Record ${rec_names[$single_i]} updated to $REPL_IP"
                            fi
                        fi
                        ;;
                    4)
                        read -rp "Enter NEW Subdomain prefix for selected records (e.g. 'speed' -> speed.$c_dom): " NEW_SUB_PREFIX
                        NEW_SUB_PREFIX=$(echo "$NEW_SUB_PREFIX" | tr -d ' ')
                        if [ -n "$NEW_SUB_PREFIX" ]; then
                            local new_fqdn="$NEW_SUB_PREFIX.$c_dom"
                            for s_idx in "${selected_indices[@]}"; do
                                local d_id="${rec_ids[$s_idx]}"
                                local curr_type="${rec_types[$s_idx]}"
                                local curr_ip="${rec_ips[$s_idx]}"
                                local curr_cmt="${rec_comments[$s_idx]}"
                                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records/$d_id" \
                                     -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" \
                                     --data "{\"type\":\"$curr_type\",\"name\":\"$new_fqdn\",\"content\":\"$curr_ip\",\"ttl\":1,\"proxied\":false,\"comment\":\"$curr_cmt\"}" >/dev/null
                                echo -e "  ${COLOR_GREEN}✓ Renamed:${COLOR_RESET} ${rec_names[$s_idx]} -> ${COLOR_BOLD}$new_fqdn${COLOR_RESET} ($curr_ip)"
                            done
                            log OK "Renamed ${#selected_indices[@]} records to $new_fqdn."
                        fi
                        ;;
                    *) ;;
                esac
                ;;
            0) break ;;
            *) ;;
        esac
    done
}

manage_dns_presets() {
    while true; do
        echo -e "\n${COLOR_CYAN}${COLOR_BOLD}--- Subdomain Templates / Presets ---${COLOR_RESET}"
        jq -r 'to_entries[] | "  [" + .key + "]: " + (.value | join(", "))' "$PRESETS_FILE"
        echo ""
        echo "  [1] Add / Update Preset"
        echo "  [2] Delete Preset"
        echo "  [0] Back"
        read -rp "Select Option [0-2]: " PR_OPT

        case "$PR_OPT" in
            1)
                read -rp "Enter Preset Name (e.g. speed / cdn): " PNAME
                PNAME=$(echo "$PNAME" | tr ' ' '_')
                read -rp "Enter subdomains (comma-separated, e.g. sub1, cdn, direct, vpn): " PSUBS
                if [ -n "$PNAME" ] && [ -n "$PSUBS" ]; then
                    local subs_json
                    subs_json=$(echo "$PSUBS" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | grep -v '^$' | jq -R . | jq -s .)
                    local tmp_pr
                    tmp_pr=$(mktemp)
                    jq --arg k "$PNAME" --argjson v "$subs_json" '.[$k] = $v' "$PRESETS_FILE" > "$tmp_pr" && mv "$tmp_pr" "$PRESETS_FILE"
                    log OK "Preset '$PNAME' saved successfully."
                fi
                ;;
            2)
                read -rp "Enter Preset Name to delete: " PNAME_DEL
                local tmp_del
                tmp_del=$(mktemp)
                jq --arg k "$PNAME_DEL" 'del(.[$k])' "$PRESETS_FILE" > "$tmp_del" && mv "$tmp_del" "$PRESETS_FILE"
                log OK "Preset '$PNAME_DEL' deleted."
                ;;
            0) break ;;
            *) ;;
        esac
    done
}

cloudflare_dns_center_menu() {
    while true; do
        echo -e "\n${COLOR_CYAN}${COLOR_BOLD}+--------------------------------------------------------------------+${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}|                   [3] CLOUDFLARE DNS CENTER                        |${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}+--------------------------------------------------------------------+${COLOR_RESET}"
        echo -e "  [1] Clean IPs Center (Interactive Table, Multi-Select & Batch Ops)"
        echo -e "  [2] DNS Subdomain Templates (Presets for New Nodes)"
        echo -e "  [0] Back to Main Menu"
        read -rp "Select Option [0-2]: " CFC_OPT
        case "$CFC_OPT" in
            1) manage_clean_ips_interactive ;;
            2) manage_dns_presets ;;
            0) break ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ==============================================================================
# SECTION 4: BACKUP & RESTORE MODULE
# ==============================================================================

create_full_backup() {
    mkdir -p "$BACKUP_DIR"
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local backup_file="$BACKUP_DIR/pg_deploy_backup_${timestamp}.tar.gz"

    log INFO "Creating full configuration and SSL backup archive..."
    local backup_items=("$DOMAINS_FILE" "$NODES_FILE" "$PRESETS_FILE")
    [ -d "/etc/letsencrypt" ] && backup_items+=("/etc/letsencrypt")
    [ -d "/root/.secrets/certbot" ] && backup_items+=("/root/.secrets/certbot")
    [ -d "/var/lib/pasarguard/certs" ] && backup_items+=("/var/lib/pasarguard/certs")
    [ -d "/var/lib/pasarguard/ssl" ] && backup_items+=("/var/lib/pasarguard/ssl")

    if sudo tar -czf "$backup_file" -P "${backup_items[@]}" 2>/dev/null; then
        sudo chmod 600 "$backup_file"
        log OK "Backup successfully created: $backup_file"
        echo -e "\n${COLOR_GREEN}${COLOR_BOLD}✓ Complete Backup Created!${COLOR_RESET}"
        echo -e "  ${COLOR_CYAN}File Path:${COLOR_RESET} $backup_file"
        echo -e "  ${COLOR_CYAN}File Size:${COLOR_RESET} $(du -h "$backup_file" | awk '{print $1}')"
    else
        log ERROR "Failed to create backup archive."
    fi
}

restore_full_backup() {
    echo -e "\n${COLOR_CYAN}${COLOR_BOLD}--- Restore Configuration & SSLs ---${COLOR_RESET}"
    local backups=($(ls -t "$BACKUP_DIR"/pg_deploy_backup_*.tar.gz 2>/dev/null || true))

    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${COLOR_YELLOW}No backup archives found in $BACKUP_DIR.${COLOR_RESET}"
        read -rp "Enter full path to custom backup tar.gz file (or press Enter to cancel): " CUSTOM_BCK
        [ -z "$CUSTOM_BCK" ] && return
        if [ ! -f "$CUSTOM_BCK" ]; then
            log ERROR "File $CUSTOM_BCK not found."
            return
        fi
        local selected_archive="$CUSTOM_BCK"
    else
        echo -e "${COLOR_CYAN}Available Backup Archives:${COLOR_RESET}"
        for i in "${!backups[@]}"; do
            echo -e "  [$((i + 1))] $(basename "${backups[$i]}") - $(du -h "${backups[$i]}" | awk '{print $1}')"
        done
        read -rp "Select Backup [1-${#backups[@]}]: " B_IDX
        if ! [[ "$B_IDX" =~ ^[0-9]+$ ]] || [ "$B_IDX" -lt 1 ] || [ "$B_IDX" -gt "${#backups[@]}" ]; then
            log ERROR "Invalid selection."
            return
        fi
        local selected_archive="${backups[$((B_IDX - 1))]}"
    fi

    echo -e "${COLOR_RED}${COLOR_BOLD}WARNING: Restoring will overwrite existing databases and Let's Encrypt keys!${COLOR_RESET}"
    read -rp "Are you sure? Type 'yes' to proceed: " CONFIRM_RES
    if [ "$CONFIRM_RES" == "yes" ]; then
        log INFO "Extracting $selected_archive..."
        sudo tar -xzf "$selected_archive" -P
        
        sudo chmod 644 "$DOMAINS_FILE" "$NODES_FILE" "$PRESETS_FILE" 2>/dev/null || true
        sudo chmod -R 700 /root/.secrets/certbot 2>/dev/null || true
        sudo chmod -R 600 /root/.secrets/certbot/* 2>/dev/null || true
        sudo chmod -R 755 /etc/letsencrypt 2>/dev/null || true
        
        pasarguard restart 2>/dev/null || true
        log OK "Restore completed and master panel services restarted."
    else
        echo "Restore cancelled."
    fi
}

backup_restore_menu() {
    while true; do
        echo -e "\n${COLOR_CYAN}${COLOR_BOLD}+--------------------------------------------------------------------+${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}|                   [4] BACKUP & RESTORE CENTER                      |${COLOR_RESET}"
        echo -e "${COLOR_CYAN}${COLOR_BOLD}+--------------------------------------------------------------------+${COLOR_RESET}"
        echo -e "  [1] Create Complete Backup (Databases + SSL Certs + Cloudflare Configs)"
        echo -e "  [2] Restore from Backup Archive"
        echo -e "  [3] Quick JSON Database Print (Export Nodes & Domains)"
        echo -e "  [0] Back to Main Menu"
        read -rp "Select Option [0-3]: " BKP_OPT

        case "$BKP_OPT" in
            1) create_full_backup ;;
            2) restore_full_backup ;;
            3)
                echo -e "\n${COLOR_CYAN}--- domains.json ---${COLOR_RESET}"
                cat "$DOMAINS_FILE"
                echo -e "\n${COLOR_CYAN}--- nodes.json ---${COLOR_RESET}"
                cat "$NODES_FILE"
                ;;
            0) break ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ==============================================================================
# MAIN INTERFACE
# ==============================================================================

install_base_tools
init_db

while true; do
    echo -e "\n${COLOR_CYAN}${COLOR_BOLD}======================================================================${COLOR_RESET}"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}                 PASARGUARD MULTI-NODE AUTO-DEPLOYER                  ${COLOR_RESET}"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}======================================================================${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}[1] 🚀 Node Management Center${COLOR_RESET}     (Deploy, 1-Click Migrate, Inbounds)"
    echo -e "  ${COLOR_BOLD}[2] 🌐 Domains & SSL Manager${COLOR_RESET}      (Certbot, Wildcards, Multi-SSL Sync)"
    echo -e "  ${COLOR_BOLD}[3] ⚡ Cloudflare DNS Center${COLOR_RESET}      (Clean IPs Table, Presets Templates)"
    echo -e "  ${COLOR_BOLD}[4] 💾 Backup & Restore Center${COLOR_RESET}    (Full Archive Export / 1-Click Import)"
    echo -e "  ${COLOR_BOLD}[5] 📋 System Diagnostics & Logs${COLOR_RESET}  (Execution Trace & Health Status)"
    echo -e "  ${COLOR_BOLD}[0] 🚪 Exit${COLOR_RESET}"
    echo -e "${COLOR_CYAN}----------------------------------------------------------------------${COLOR_RESET}"
    read -rp "Select Module [0-5]: " MAIN_CHOICE

    case "$MAIN_CHOICE" in
        1) node_management_menu ;;
        2) domain_management_menu ;;
        3) cloudflare_dns_center_menu ;;
        4) backup_restore_menu ;;
        5) [ -f "$LOG_FILE" ] && tail -n 50 "$LOG_FILE" || echo "No logs found." ;;
        0) echo "Goodbye!"; exit 0 ;;
        *) echo -e "${COLOR_RED}Invalid choice.${COLOR_RESET}" ;;
    esac
done
