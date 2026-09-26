#!/bin/bash

# ==============================================================================
# PasarGuard Multi-Node Auto-Deployer
# Pre-injects official Wildcard SSL & integrates natively with pg-node CLI
# Supports: Multi-IP, DNS Presets, Multi-SSL, Clean IPs Management
# ==============================================================================

set -o pipefail

REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
APP_DIR="$(cd "$(dirname "$REAL_PATH")" && pwd)"
DOMAINS_FILE="$APP_DIR/domains.json"
NODES_FILE="$APP_DIR/nodes.json"
PRESETS_FILE="$APP_DIR/dns_presets.json"
CLEAN_IPS_FILE="$APP_DIR/clean_ips.json"
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
    for pkg in jq sshpass curl certbot python3-certbot-dns-cloudflare; do
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
    [ ! -f "$CLEAN_IPS_FILE" ] && echo '[]' > "$CLEAN_IPS_FILE"
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

issue_wildcard_ssl() {
    echo -e "\n${COLOR_BOLD}${COLOR_CYAN}--- Issue Wildcard SSL: Let's Encrypt + Cloudflare ---${COLOR_RESET}"
    read -rp "Enter Base Domain (e.g. example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)

    read -rp "Enter Cloudflare API Token: " CF_TOKEN
    CF_TOKEN=$(echo "$CF_TOKEN" | xargs)

    read -rp "Enter Cloudflare Zone ID: " ZONE_ID
    ZONE_ID=$(echo "$ZONE_ID" | xargs)

    read -rp "Enter Contact Email (Press Enter for admin@$DOMAIN): " CONTACT_EMAIL
    CONTACT_EMAIL=${CONTACT_EMAIL:-"admin@$DOMAIN"}

    if [ -z "$DOMAIN" ] || [ -z "$CF_TOKEN" ] || [ -z "$ZONE_ID" ]; then
        log ERROR "Domain, API Token, and Zone ID cannot be empty."
        return 1
    fi

    local cf_cred_dir="/root/.secrets/certbot"
    local cf_cred_file="$cf_cred_dir/cloudflare_$DOMAIN.ini"
    sudo mkdir -p "$cf_cred_dir"
    sudo chmod 700 "$cf_cred_dir"

    echo "dns_cloudflare_api_token = $CF_TOKEN" | sudo tee "$cf_cred_file" >/dev/null
    sudo chmod 600 "$cf_cred_file"

    log INFO "Requesting Wildcard SSL for $DOMAIN and *.$DOMAIN..."
    if sudo certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$cf_cred_file" \
        --dns-cloudflare-propagation-seconds 30 \
        -d "$DOMAIN" -d "*.$DOMAIN" \
        --non-interactive --agree-tos -m "$CONTACT_EMAIL"; then
        
        log OK "Wildcard SSL certificate successfully generated."

        sudo mkdir -p "/var/lib/pasarguard/ssl" "/var/lib/pasarguard/certs" "/var/lib/pg-node/certs"
        local base_prefix="${DOMAIN%%.*}"
        sudo cat "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" | sudo tee "/var/lib/pasarguard/ssl/cert.pem" "/var/lib/pasarguard/certs/$base_prefix.cer" "/var/lib/pasarguard/certs/cert.pem" "/var/lib/pg-node/certs/ssl_cert.pem" >/dev/null
        sudo cat "/etc/letsencrypt/live/$DOMAIN/privkey.pem" | sudo tee "/var/lib/pasarguard/ssl/key.pem" "/var/lib/pasarguard/certs/$base_prefix.key" "/var/lib/pasarguard/certs/key.pem" "/var/lib/pg-node/certs/ssl_key.pem" >/dev/null
        sudo chmod 644 "/var/lib/pasarguard/ssl/cert.pem" "/var/lib/pasarguard/certs/"* /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || true
        sudo chmod 600 "/var/lib/pasarguard/ssl/key.pem" "/var/lib/pasarguard/certs/"*.key /var/lib/pg-node/certs/ssl_key.pem 2>/dev/null || true
        log OK "Master SSL synced to: /var/lib/pasarguard/certs/ and /var/lib/pg-node/certs/"

        local tmp_file
        tmp_file=$(mktemp)
        jq --arg dom "$DOMAIN" --arg tok "$CF_TOKEN" --arg zid "$ZONE_ID" --arg eml "$CONTACT_EMAIL" \
           'map(select(.domain != $dom)) + [{"domain": $dom, "token": $tok, "zone_id": $zid, "email": $eml, "updated_at": (now | todate)}]' \
           "$DOMAINS_FILE" > "$tmp_file" && mv "$tmp_file" "$DOMAINS_FILE"
        log OK "Domain profile saved."
    else
        log ERROR "Certbot failed to generate Wildcard SSL."
        return 1
    fi
}

deploy_new_node() {
    echo -e "\n${COLOR_BOLD}${COLOR_CYAN}--- Deploy New PasarGuard Node ---${COLOR_RESET}"
    if ! list_domain_profiles; then
        echo -e "${COLOR_YELLOW}Please add a domain profile first (Option 2).${COLOR_RESET}"
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
    
    # Primary & Secondary Multi-IP Setup
    read -rp "Primary Server IP (SSH & Panel Connection): " NODE_IP
    read -rp "Additional IPs on this server (comma-separated, or press Enter): " EXTRA_IPS
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

    # DNS Presets Selection
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

    # Multi-Domain SSLs Prompt
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

    # Multi-Domain SSL Transfer
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

    # Create Primary Node DNS Record
    log INFO "Configuring Primary Cloudflare DNS A-record: $full_hostname -> $NODE_IP..."
    local check_dns_res record_id
    check_dns_res=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$selected_zone/dns_records?name=$full_hostname&type=A" \
         -H "Authorization: Bearer $selected_token" \
         -H "Content-Type: application/json")

    record_id=$(echo "$check_dns_res" | jq -r '.result[0].id // empty')
    if [ -n "$record_id" ]; then
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$selected_zone/dns_records/$record_id" \
             -H "Authorization: Bearer $selected_token" -H "Content-Type: application/json" \
             --data "{\"type\":\"A\",\"name\":\"$full_hostname\",\"content\":\"$NODE_IP\",\"ttl\":1,\"proxied\":false}" >/dev/null
    else
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$selected_zone/dns_records" \
             -H "Authorization: Bearer $selected_token" -H "Content-Type: application/json" \
             --data "{\"type\":\"A\",\"name\":\"$full_hostname\",\"content\":\"$NODE_IP\",\"ttl\":1,\"proxied\":false}" >/dev/null
    fi
    log OK "Primary DNS configured: $full_hostname"

    # Merge Presets and Manual Subdomains
    local all_extra_subs=("${preset_subs[@]}")
    if [ -n "$MANUAL_SUBS" ]; then
        IFS=',' read -ra M_ARR <<< "$MANUAL_SUBS"
        for m_val in "${M_ARR[@]}"; do
            m_val=$(echo "$m_val" | tr -d ' ')
            [ -n "$m_val" ] && all_extra_subs+=("$m_val")
        done
    fi

    # Create All Extra Subdomains (supporting secondary IPs round-robin or assigned)
    local secondary_ips_list=()
    if [ -n "$EXTRA_IPS" ]; then
        IFS=',' read -ra E_IPS <<< "$EXTRA_IPS"
        for e_ip in "${E_IPS[@]}"; do
            e_ip=$(echo "$e_ip" | tr -d ' ')
            [ -n "$e_ip" ] && secondary_ips_list+=("$e_ip")
        done
    fi

    local created_dns_list=("$full_hostname")
    local ip_pool=("$NODE_IP" "${secondary_ips_list[@]}")
    local ip_pool_idx=0

    for sub_item in "${all_extra_subs[@]}"; do
        if [ -n "$sub_item" ]; then
            local target_sub_ip="${ip_pool[$ip_pool_idx]}"
            ip_pool_idx=$(( (ip_pool_idx + 1) % ${#ip_pool[@]} ))

            local extra_full_sub="$sub_item.$selected_domain"
            log INFO "Creating DNS A-record: $extra_full_sub -> $target_sub_ip..."
            local ex_chk ex_id
            ex_chk=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$selected_zone/dns_records?name=$extra_full_sub&type=A" \
                 -H "Authorization: Bearer $selected_token" -H "Content-Type: application/json")
            ex_id=$(echo "$ex_chk" | jq -r '.result[0].id // empty')

            if [ -n "$ex_id" ]; then
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$selected_zone/dns_records/$ex_id" \
                     -H "Authorization: Bearer $selected_token" -H "Content-Type: application/json" \
                     --data "{\"type\":\"A\",\"name\":\"$extra_full_sub\",\"content\":\"$target_sub_ip\",\"ttl\":1,\"proxied\":false}" >/dev/null
            else
                curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$selected_zone/dns_records" \
                     -H "Authorization: Bearer $selected_token" -H "Content-Type: application/json" \
                     --data "{\"type\":\"A\",\"name\":\"$extra_full_sub\",\"content\":\"$target_sub_ip\",\"ttl\":1,\"proxied\":false}" >/dev/null
            fi
            created_dns_list+=("$extra_full_sub ($target_sub_ip)")
            log OK "Created: $extra_full_sub -> $target_sub_ip"
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

    local dns_json ssl_json sec_ips_json
    dns_json=$(printf '%s\n' "${created_dns_list[@]}" | jq -R . | jq -s .)
    ssl_json=$(printf '%s\n' "${installed_ssl_domains[@]}" | jq -R . | jq -s .)
    sec_ips_json=$(printf '%s\n' "${secondary_ips_list[@]}" | jq -R . | jq -s .)

    local tmp_node
    tmp_node=$(mktemp)
    jq --arg nm "$NODE_NAME" --arg ip "$NODE_IP" --arg pt "$NODE_SSH_PORT" --arg usr "$NODE_SSH_USER" \
       --arg pwd "$NODE_SSH_PASS" --arg dom "$full_hostname" --arg bdom "$selected_domain" \
       --arg sport "$SERVICE_PORT" --arg aport "$API_PORT" --arg tok "$node_token" --arg proto "$PROTO_NAME" \
       --argjson dns "$dns_json" --argjson ssls "$ssl_json" --argjson sec_ips "$sec_ips_json" \
       'map(select(.hostname != $nm)) + [{
          "hostname": $nm,
          "ip": $ip,
          "secondary_ips": $sec_ips,
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
    echo -e "${COLOR_BOLD}Active DNS Records on Cloudflare:${COLOR_RESET}"
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

manage_dns_presets() {
    while true; do
        echo -e "\n${COLOR_CYAN}${COLOR_BOLD}--- DNS Subdomain Presets Manager ---${COLOR_RESET}"
        jq -r 'to_entries[] | "  [" + .key + "]: " + (.value | join(", "))' "$PRESETS_FILE"
        echo ""
        echo "  1) Add / Update Preset"
        echo "  2) Delete Preset"
        echo "  3) Return to Main Menu"
        read -rp "Select Option [1-3]: " PR_OPT

        case "$PR_OPT" in
            1)
                read -rp "Enter Preset Name (e.g. standard / gaming / cdn): " PNAME
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
            3)
                break
                ;;
        esac
    done
}

manage_clean_ips() {
    while true; do
        echo -e "\n${COLOR_CYAN}${COLOR_BOLD}--- Cloudflare Clean IPs Manager ---${COLOR_RESET}"
        list_domain_profiles || true
        local d_count
        d_count=$(get_domains_count)
        if [ "$d_count" -eq 0 ]; then
            echo -e "${COLOR_YELLOW}Add a domain profile first.${COLOR_RESET}"
            break
        fi

        echo "  1) Mass Register Clean IPs into Cloudflare DNS"
        echo "  2) View Saved Clean IPs"
        echo "  3) Return to Main Menu"
        read -rp "Select Option [1-3]: " CL_OPT

        case "$CL_OPT" in
            1)
                read -rp "Select Target Domain Profile [1-$d_count]: " C_DOM_IDX
                local c_dom c_tok c_zid
                c_dom=$(jq -r ".[$((C_DOM_IDX - 1))].domain" "$DOMAINS_FILE")
                c_tok=$(jq -r ".[$((C_DOM_IDX - 1))].token" "$DOMAINS_FILE")
                c_zid=$(jq -r ".[$((C_DOM_IDX - 1))].zone_id" "$DOMAINS_FILE")

                read -rp "Subdomain prefix for Clean IPs (e.g. 'clean' -> clean1.$c_dom, clean2.$c_dom): " PREFIX
                PREFIX=${PREFIX:-"clean"}
                echo -e "Enter Clean IPs (comma-separated or paste multiple IPs):"
                read -rp "IPs: " RAW_IPS

                IFS=',' read -ra IP_LIST <<< "$RAW_IPS"
                local idx=1
                for cip in "${IP_LIST[@]}"; do
                    cip=$(echo "$cip" | tr -d ' \r\n')
                    if [[ "$cip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        local rec_name="${PREFIX}${idx}.${c_dom}"
                        log INFO "Registering $rec_name -> $cip on Cloudflare..."
                        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records" \
                             -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" \
                             --data "{\"type\":\"A\",\"name\":\"$rec_name\",\"content\":\"$cip\",\"ttl\":1,\"proxied\":false}" >/dev/null
                        log OK "Created Clean IP DNS: $rec_name -> $cip"
                        idx=$((idx + 1))
                    fi
                done
                ;;
            2)
                echo -e "${COLOR_YELLOW}Saved Clean IP records are managed directly within your Cloudflare Zone.${COLOR_RESET}"
                ;;
            3)
                break
                ;;
        esac
    done
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

    echo -e "\nActions for node: $target_host - $target_ip"
    echo "  1) View Panel Connection Info (Address, Ports, Token and Full Card)"
    echo "  2) Manage & Sync Multi-Domain SSLs (View/Inject Domain Certificates)"
    echo "  3) Manage Cloudflare DNS Records (Add Extra Subdomains to this Node)"
    echo "  4) Switch Node Protocol (gRPC <-> REST)"
    echo "  5) Manage Systemd Service (Install / Remove pg-node-service)"
    echo "  6) Update / Change Xray-core (pg-node core-update)"
    echo "  7) Update PasarGuard Node Software (pg-node update)"
    echo "  8) Download / Update GeoFiles (pg-node geofiles)"
    echo "  9) Restart PasarGuard Node (pg-node restart)"
    echo "  10) View Live Node Logs (pg-node logs)"
    echo "  11) Delete Node from Local Inventory Only"
    echo "  12) Completely Uninstall Node from Server, Cloudflare & Inventory"
    echo "  13) Cancel"
    read -rp "Action [1-13]: " N_ACT

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
                    echo -e "  ${COLOR_GREEN}• $sdom${COLOR_RESET} (Custom Inbounds: /var/lib/pg-node/certs/$sdom/fullchain.pem)"
                fi
            done
            echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
            echo -e "${COLOR_BOLD}Certificate (Copy exactly into Panel Certificate box):${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}$single_cert${COLOR_RESET}"
            echo -e "${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}\n"
            ;;
        2)
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
                else
                    log ERROR "Certificate files for $inj_dom not found on Master."
                fi
            fi
            ;;
        3)
            echo -e "\n${COLOR_CYAN}--- Add Additional Cloudflare Subdomain DNS ---${COLOR_RESET}"
            read -rp "Enter new subdomain prefix (e.g. proxy2): " NEW_SUB
            NEW_SUB=$(echo "$NEW_SUB" | tr -d ' ')
            if [ -n "$NEW_SUB" ]; then
                local new_full_rec="$NEW_SUB.$target_bdom"
                local c_tok c_zid
                c_tok=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .token' "$DOMAINS_FILE")
                c_zid=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .zone_id' "$DOMAINS_FILE")
                if [ -n "$c_tok" ] && [ -n "$c_zid" ]; then
                    log INFO "Registering DNS $new_full_rec -> $target_ip..."
                    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records" \
                         -H "Authorization: Bearer $c_tok" \
                         -H "Content-Type: application/json" \
                         --data "{\"type\":\"A\",\"name\":\"$new_full_rec\",\"content\":\"$target_ip\",\"ttl\":1,\"proxied\":false}" >/dev/null
                    
                    local tmp_dnsup
                    tmp_dnsup=$(mktemp)
                    jq --arg idx "$((N_IDX - 1))" --arg nrec "$new_full_rec" \
                       '.[($idx|tonumber)].dns_records = ((.[($idx|tonumber)].dns_records // []) + [$nrec] | unique)' \
                       "$NODES_FILE" > "$tmp_dnsup" && mv "$tmp_dnsup" "$NODES_FILE"
                    log OK "DNS record created: $new_full_rec"
                fi
            fi
            ;;
        4)
            echo -e "\n${COLOR_CYAN}--- Switch Node Protocol ---${COLOR_RESET}"
            echo "  1) Use gRPC (Official Default)"
            echo "  2) Use REST"
            read -rp "Select Protocol [1-2]: " PROTO_SEL
            if [ "$PROTO_SEL" == "1" ]; then
                log INFO "Configuring node to use gRPC protocol..."
                eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node install -y --override --use-grpc --cert-path /var/lib/pg-node/certs/ssl_cert.pem --key-path /var/lib/pg-node/certs/ssl_key.pem --service-port $target_sport --api-port $target_aport'"
                local tmp_upd
                tmp_upd=$(mktemp)
                jq --arg idx "$((N_IDX - 1))" '.[($idx|tonumber)].protocol = "grpc"' "$NODES_FILE" > "$tmp_upd" && mv "$tmp_upd" "$NODES_FILE"
                log OK "Switched to gRPC protocol."
            elif [ "$PROTO_SEL" == "2" ]; then
                log INFO "Configuring node to use REST protocol..."
                eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node install -y --override --use-rest --cert-path /var/lib/pg-node/certs/ssl_cert.pem --key-path /var/lib/pg-node/certs/ssl_key.pem --service-port $target_sport --api-port $target_aport'"
                local tmp_upd
                tmp_upd=$(mktemp)
                jq --arg idx "$((N_IDX - 1))" '.[($idx|tonumber)].protocol = "rest"' "$NODES_FILE" > "$tmp_upd" && mv "$tmp_upd" "$NODES_FILE"
                log OK "Switched to REST protocol."
            fi
            ;;
        5)
            echo -e "\n${COLOR_CYAN}--- Manage Systemd Service ---${COLOR_RESET}"
            echo "  1) Install and Start pg-node-service (Systemd)"
            echo "  2) Remove pg-node-service (Systemd)"
            read -rp "Action [1-2]: " SYS_SEL
            if [ "$SYS_SEL" == "1" ]; then
                eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node service-install'"
                log OK "Systemd service installed and started."
            elif [ "$SYS_SEL" == "2" ]; then
                eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node service-uninstall'"
                log OK "Systemd service removed."
            fi
            ;;
        6)
            echo -e "\n${COLOR_CYAN}--- Update / Change Xray-core ---${COLOR_RESET}"
            read -rp "Enter Xray version (Press Enter for 'latest'): " X_VER
            X_VER=${X_VER:-latest}
            log INFO "Updating Xray-core to version: $X_VER on $target_ip..."
            eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node core-update --version $X_VER'"
            log OK "Xray-core update dispatched."
            ;;
        7)
            log INFO "Updating PasarGuard Node software to latest..."
            eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node update -y'"
            log OK "Node updated successfully."
            ;;
        8)
            log INFO "Updating GeoFiles (GeoIP and GeoSite)..."
            eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node geofiles'"
            log OK "GeoFiles downloaded/updated."
            ;;
        9)
            log INFO "Restarting node service..."
            eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node restart -n 2>/dev/null || true'"
            log OK "Node service restarted."
            ;;
        10)
            log INFO "Streaming Node Logs (Press Ctrl+C to return)..."
            eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node logs'"
            ;;
        11)
            local tmp_d
            tmp_d=$(mktemp)
            jq "del(.[$((N_IDX - 1))])" "$NODES_FILE" > "$tmp_d" && mv "$tmp_d" "$NODES_FILE"
            log OK "Node removed from local inventory only."
            ;;
        12)
            echo -e "${COLOR_RED}${COLOR_BOLD}WARNING: This will completely destroy all PasarGuard node data, remove docker containers, delete certificates on $target_ip, clean up Cloudflare DNS, and delete the node profile!${COLOR_RESET}"
            read -rp "Are you absolutely sure? Type 'yes' to proceed: " CONFIRM_PURGE
            if [ "$CONFIRM_PURGE" == "yes" ]; then
                log INFO "Executing native pg-node uninstall on $target_ip..."
                sshpass -p "$target_pass" ssh -p "$target_port" -o StrictHostKeyChecking=no "$target_user@$target_ip" bash << REMOTE_UNINSTALL
export PATH=/usr/local/bin:\$PATH
pg-node uninstall -y 2>/dev/null || true
rm -rf /opt/pg-node /var/lib/pg-node /var/lib/pasarguard /usr/local/bin/pg-node /etc/sysctl.d/99-bbr.conf
ufw delete allow $target_sport/tcp 2>/dev/null || true
ufw delete allow $target_aport/tcp 2>/dev/null || true
REMOTE_UNINSTALL
                log OK "Remote server cleaned up."

                local cf_tok cf_zid
                cf_tok=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .token' "$DOMAINS_FILE")
                cf_zid=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .zone_id' "$DOMAINS_FILE")
                if [ -n "$cf_tok" ] && [ -n "$cf_zid" ]; then
                    log INFO "Removing DNS records from Cloudflare..."
                    jq -r ".[$((N_IDX - 1))].dns_records[]? // empty" "$NODES_FILE" | while read -r r_to_del; do
                        local clean_name
                        clean_name=$(echo "$r_to_del" | awk '{print $1}')
                        local rec_id
                        rec_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$cf_zid/dns_records?name=$clean_name&type=A" \
                             -H "Authorization: Bearer $cf_tok" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
                        if [ -n "$rec_id" ]; then
                            curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$cf_zid/dns_records/$rec_id" \
                                 -H "Authorization: Bearer $cf_tok" -H "Content-Type: application/json" >/dev/null
                            log OK "Deleted Cloudflare record: $clean_name"
                        fi
                    done
                fi

                local tmp_del
                tmp_del=$(mktemp)
                jq "del(.[$((N_IDX - 1))])" "$NODES_FILE" > "$tmp_del" && mv "$tmp_del" "$NODES_FILE"
                log OK "Node purged from inventory. Cleanup complete."
            else
                echo "Purge canceled."
            fi
            ;;
        *)
            return 0
            ;;
    esac
}

renew_sync_all_ssl() {
    echo -e "\n${COLOR_CYAN}--- Renew & Synchronize All SSL Certificates ---${COLOR_RESET}"
    log INFO "Triggering Certbot renew on Master..."
    sudo certbot renew --quiet || true

    local count
    count=$(get_domains_count)
    if [ "$count" -eq 0 ]; then
        log WARN "No domain profiles found."
        return 0
    fi

    for i in $(seq 0 $((count - 1))); do
        local dom
        dom=$(jq -r ".[$i].domain" "$DOMAINS_FILE")
        local cert="/etc/letsencrypt/live/$dom/fullchain.pem"
        local key="/etc/letsencrypt/live/$dom/privkey.pem"

        if [ -f "$cert" ] && [ -f "$key" ]; then
            log INFO "Syncing renewed SSL to Master..."
            sudo mkdir -p /var/lib/pasarguard/ssl /var/lib/pasarguard/certs /var/lib/pg-node/certs
            local base_prefix="${dom%%.*}"
            sudo cat "$cert" | sudo tee /var/lib/pasarguard/ssl/cert.pem "/var/lib/pasarguard/certs/$base_prefix.cer" /var/lib/pasarguard/certs/cert.pem /var/lib/pg-node/certs/ssl_cert.pem >/dev/null
            sudo cat "$key" | sudo tee /var/lib/pasarguard/ssl/key.pem "/var/lib/pasarguard/certs/$base_prefix.key" /var/lib/pasarguard/certs/key.pem /var/lib/pg-node/certs/ssl_key.pem >/dev/null
            sudo chmod 644 /var/lib/pasarguard/ssl/cert.pem /var/lib/pasarguard/certs/* /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || true
            sudo chmod 600 /var/lib/pasarguard/ssl/key.pem /var/lib/pasarguard/certs/*.key /var/lib/pg-node/certs/ssl_key.pem 2>/dev/null || true
            pasarguard restart 2>/dev/null || true

            local node_count
            node_count=$(jq '. | length' "$NODES_FILE")
            for n in $(seq 0 $((node_count - 1))); do
                local nbdom nip nport nuser npass
                nbdom=$(jq -r ".[$n].base_domain" "$NODES_FILE")
                nip=$(jq -r ".[$n].ip" "$NODES_FILE")
                nport=$(jq -r ".[$n].ssh_port" "$NODES_FILE")
                nuser=$(jq -r ".[$n].ssh_user" "$NODES_FILE")
                npass=$(jq -r ".[$n].ssh_pass" "$NODES_FILE")

                if [ "$nbdom" == "$dom" ]; then
                    log INFO "Pushing primary renewed cert to node ($nip)..."
                    cat "$cert" | sshpass -p "$npass" ssh -p "$nport" -o StrictHostKeyChecking=no "$nuser@$nip" "cat > /var/lib/pg-node/certs/ssl_cert.pem && cat > /var/lib/pasarguard/ssl/cert.pem && chmod 644 /var/lib/pg-node/certs/ssl_cert.pem /var/lib/pasarguard/ssl/cert.pem"
                    cat "$key" | sshpass -p "$npass" ssh -p "$nport" -o StrictHostKeyChecking=no "$nuser@$nip" "cat > /var/lib/pg-node/certs/ssl_key.pem && cat > /var/lib/pasarguard/ssl/key.pem && chmod 600 /var/lib/pg-node/certs/ssl_key.pem /var/lib/pasarguard/ssl/key.pem"
                    sshpass -p "$npass" ssh -p "$nport" -o StrictHostKeyChecking=no "$nuser@$nip" "export PATH=/usr/local/bin:\$PATH; pg-node restart -n 2>/dev/null || true"
                fi

                local is_sec
                is_sec=$(jq -r --arg d "$dom" ".[$n].ssl_domains[]? | select(. == \$d)" "$NODES_FILE")
                if [ -n "$is_sec" ] && [ "$dom" != "$nbdom" ]; then
                    log INFO "Updating secondary SSL for $dom on node ($nip)..."
                    cat "$cert" | sshpass -p "$npass" ssh -p "$nport" -o StrictHostKeyChecking=no "$nuser@$nip" "cat > /var/lib/pg-node/certs/$dom/fullchain.pem && chmod 644 /var/lib/pg-node/certs/$dom/fullchain.pem"
                    cat "$key" | sshpass -p "$npass" ssh -p "$nport" -o StrictHostKeyChecking=no "$nuser@$nip" "cat > /var/lib/pg-node/certs/$dom/privkey.pem && chmod 600 /var/lib/pg-node/certs/$dom/privkey.pem"
                fi
            done
        fi
    done
    log OK "1-Click Renewal & sync complete across Master and all nodes."
}

# --- Main Entry Point ---
install_base_tools
init_db

while true; do
    echo -e "\n${COLOR_CYAN}${COLOR_BOLD}+--------------------------------------------------------------------+${COLOR_RESET}"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}|                PASARGUARD MULTI-NODE AUTO-DEPLOYER                 |${COLOR_RESET}"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}+--------------------------------------------------------------------+${COLOR_RESET}"
    echo -e "  [1] Deploy New Node (Multi-IP, DNS Presets & Zero Error)"
    echo -e "  [2] Issue Wildcard SSL Certificate (Let's Encrypt + Cloudflare)"
    echo -e "  [3] Sync SSL to Local Master Server"
    echo -e "  [4] Manage Saved Nodes (Inspect, Multi-SSL, Multi-DNS, Protocol)"
    echo -e "  [5] Domain Profiles Manager"
    echo -e "  [6] DNS Subdomain Presets Manager (Templates for new nodes)"
    echo -e "  [7] Cloudflare Clean IPs Manager (Mass DNS record generation)"
    echo -e "  [8] Renew & Synchronize All SSLs"
    echo -e "  [9] View Execution Logs"
    echo -e "  [10] Exit"
    echo ""
    read -rp "Select an option [1-10]: " OPTION

    case "$OPTION" in
        1) deploy_new_node ;;
        2) issue_wildcard_ssl ;;
        3) 
           echo -e "\nSyncing to Master SSL directories..."
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
        4) manage_saved_nodes ;;
        5) 
           list_domain_profiles || true
           echo "  1) Delete Domain Profile"
           echo "  2) Back to Menu"
           read -rp "Action: " D_ACT
           if [ "$D_ACT" == "1" ]; then
               read -rp "Enter Profile Index to Delete: " DEL_I
               tmp_m=$(mktemp)
               jq "del(.[$((DEL_I - 1))])" "$DOMAINS_FILE" > "$tmp_m" && mv "$tmp_m" "$DOMAINS_FILE"
               log OK "Profile deleted."
           fi
           ;;
        6) manage_dns_presets ;;
        7) manage_clean_ips ;;
        8) renew_sync_all_ssl ;;
        9) [ -f "$LOG_FILE" ] && tail -n 50 "$LOG_FILE" || echo "No logs found." ;;
        10) echo "Goodbye!"; exit 0 ;;
        *) echo -e "${COLOR_RED}Invalid option.${COLOR_RESET}" ;;
    esac
done
