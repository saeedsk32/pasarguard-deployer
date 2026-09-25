#!/bin/bash

# ==============================================================================
# PasarGuard Multi-Node Auto-Deployer
# Pre-injects official Wildcard SSL into /var/lib/pg-node/certs/ and /var/lib/pasarguard/ssl/
# ==============================================================================

set -o pipefail

REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
APP_DIR="$(cd "$(dirname "$REAL_PATH")" && pwd)"
DOMAINS_FILE="$APP_DIR/domains.json"
NODES_FILE="$APP_DIR/nodes.json"
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

        sudo mkdir -p "/var/lib/pasarguard/ssl" "/var/lib/pg-node/certs"
        sudo cat "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" | sudo tee "/var/lib/pasarguard/ssl/cert.pem" >/dev/null
        sudo cat "/etc/letsencrypt/live/$DOMAIN/privkey.pem" | sudo tee "/var/lib/pasarguard/ssl/key.pem" >/dev/null
        sudo cp "/var/lib/pasarguard/ssl/cert.pem" "/var/lib/pg-node/certs/ssl_cert.pem"
        sudo cp "/var/lib/pasarguard/ssl/key.pem" "/var/lib/pg-node/certs/ssl_key.pem"
        sudo chmod 644 "/var/lib/pasarguard/ssl/cert.pem" "/var/lib/pg-node/certs/ssl_cert.pem"
        sudo chmod 600 "/var/lib/pasarguard/ssl/key.pem" "/var/lib/pg-node/certs/ssl_key.pem"
        log OK "Master SSL synced to: /var/lib/pasarguard/ssl/ and /var/lib/pg-node/certs/"

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
    read -rp "Select Domain Profile [1-$count]: " DOM_IDX
    if ! [[ "$DOM_IDX" =~ ^[0-9]+$ ]] || [ "$DOM_IDX" -lt 1 ] || [ "$DOM_IDX" -gt "$count" ]; then
        log ERROR "Invalid profile selection."
        return 1
    fi

    local selected_domain selected_token selected_zone
    selected_domain=$(jq -r ".[$((DOM_IDX - 1))].domain" "$DOMAINS_FILE")
    selected_token=$(jq -r ".[$((DOM_IDX - 1))].token" "$DOMAINS_FILE")
    selected_zone=$(jq -r ".[$((DOM_IDX - 1))].zone_id" "$DOMAINS_FILE")

    read -rp "Node Hostname: " NODE_NAME
    read -rp "Node Server IP: " NODE_IP
    read -rp "SSH Port [22]: " NODE_SSH_PORT
    NODE_SSH_PORT=${NODE_SSH_PORT:-22}
    read -rp "SSH User [root]: " NODE_SSH_USER
    NODE_SSH_USER=${NODE_SSH_USER:-root}
    read -rsp "SSH Password: " NODE_SSH_PASS
    echo ""
    read -rp "Subdomain prefix for node: " SUBDOMAIN_PREFIX
    read -rp "Service Port [62050]: " SERVICE_PORT
    SERVICE_PORT=${SERVICE_PORT:-62050}
    read -rp "API Port [62051]: " API_PORT
    API_PORT=${API_PORT:-62051}
    read -rp "Install PasarGuard Node binary? [Y/n]: " INSTALL_PG
    INSTALL_PG=${INSTALL_PG:-Y}

    local full_hostname="$SUBDOMAIN_PREFIX.$selected_domain"
    local cert_src="/etc/letsencrypt/live/$selected_domain/fullchain.pem"
    local key_src="/etc/letsencrypt/live/$selected_domain/privkey.pem"

    if [ ! -f "$cert_src" ] || [ ! -f "$key_src" ]; then
        log ERROR "Certificates not found for $selected_domain in Let's Encrypt directory."
        return 1
    fi

    log INFO "Validating SSH connection to $NODE_IP:$NODE_SSH_PORT..."
    local ssh_cmd="sshpass -p '$NODE_SSH_PASS' ssh -p $NODE_SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 $NODE_SSH_USER@$NODE_IP"

    if ! eval "$ssh_cmd 'echo connected'" >/dev/null 2>&1; then
        log ERROR "Cannot connect via SSH. Verify IP, port, and password."
        return 1
    fi
    log OK "SSH connection established."

    log INFO "Applying system configurations on remote node..."
    eval "$ssh_cmd 'hostnamectl set-hostname \"$NODE_NAME\" || true'"
    eval "$ssh_cmd 'modprobe tcp_bbr 2>/dev/null || true; echo \"net.core.default_qdisc=fq\" > /etc/sysctl.d/99-bbr.conf; echo \"net.ipv4.tcp_congestion_control=bbr\" >> /etc/sysctl.d/99-bbr.conf; sysctl --system >/dev/null 2>&1 || true'"

    log INFO "Updating remote system packages (non-interactive)..."
    eval "$ssh_cmd 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -qq -y'"

    log INFO "Configuring firewall for PasarGuard ports ($SERVICE_PORT, $API_PORT)..."
    eval "$ssh_cmd 'ufw allow $SERVICE_PORT/tcp >/dev/null 2>&1 || true; ufw allow $API_PORT/tcp >/dev/null 2>&1 || true'"

    log INFO "Pre-deploying Wildcard SSL to /var/lib/pg-node/certs/ and /var/lib/pasarguard/ssl/ ..."
    eval "$ssh_cmd 'mkdir -p /var/lib/pg-node/certs /var/lib/pasarguard/ssl /opt/pg-node'"
    
    cat "$cert_src" | eval "$ssh_cmd 'cat > /var/lib/pasarguard/ssl/cert.pem && cp /var/lib/pasarguard/ssl/cert.pem /var/lib/pg-node/certs/ssl_cert.pem && chmod 644 /var/lib/pasarguard/ssl/cert.pem /var/lib/pg-node/certs/ssl_cert.pem'"
    cat "$key_src" | eval "$ssh_cmd 'cat > /var/lib/pasarguard/ssl/key.pem && cp /var/lib/pasarguard/ssl/key.pem /var/lib/pg-node/certs/ssl_key.pem && chmod 600 /var/lib/pasarguard/ssl/key.pem /var/lib/pg-node/certs/ssl_key.pem'"
    log OK "Wildcard SSL pre-seeded successfully."

    log INFO "Configuring Cloudflare DNS A-record: $full_hostname -> $NODE_IP..."
    local check_dns_res record_id
    check_dns_res=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$selected_zone/dns_records?name=$full_hostname&type=A" \
         -H "Authorization: Bearer $selected_token" \
         -H "Content-Type: application/json")

    record_id=$(echo "$check_dns_res" | jq -r '.result[0].id // empty')

    if [ -n "$record_id" ]; then
        log INFO "Updating existing A-record ($record_id)..."
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$selected_zone/dns_records/$record_id" \
             -H "Authorization: Bearer $selected_token" \
             -H "Content-Type: application/json" \
             --data "{\"type\":\"A\",\"name\":\"$full_hostname\",\"content\":\"$NODE_IP\",\"ttl\":1,\"proxied\":false}" >/dev/null
    else
        log INFO "Creating new A-record..."
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$selected_zone/dns_records" \
             -H "Authorization: Bearer $selected_token" \
             -H "Content-Type: application/json" \
             --data "{\"type\":\"A\",\"name\":\"$full_hostname\",\"content\":\"$NODE_IP\",\"ttl\":1,\"proxied\":false}" >/dev/null
    fi
    log OK "Cloudflare DNS configured."

    local node_token="Not detected"
    if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
        log INFO "Executing official pg-node installer..."
        eval "$ssh_cmd 'printf \"\n\n\" | sudo bash -c \"\$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh)\" @ install || true'"

        log INFO "Enforcing official Wildcard SSL certificates over self-signed certs..."
        cat "$cert_src" | eval "$ssh_cmd 'cat > /var/lib/pg-node/certs/ssl_cert.pem && cat > /var/lib/pasarguard/ssl/cert.pem && chmod 644 /var/lib/pg-node/certs/ssl_cert.pem /var/lib/pasarguard/ssl/cert.pem'"
        cat "$key_src" | eval "$ssh_cmd 'cat > /var/lib/pg-node/certs/ssl_key.pem && cat > /var/lib/pasarguard/ssl/key.pem && chmod 600 /var/lib/pg-node/certs/ssl_key.pem /var/lib/pasarguard/ssl/key.pem'"

        eval "$ssh_cmd 'cd /opt/pg-node && docker compose restart 2>/dev/null || docker restart node 2>/dev/null || true'"

        local token_candidate
        token_candidate=$(eval "$ssh_cmd 'grep -E \"^[A-Z_]*KEY=\" /opt/pg-node/.env 2>/dev/null | cut -d\"=\" -f2 | tr -d \" \\r\\n\"'" | grep -oE '[0-9a-fA-F-]{36}' | head -n 1 || true)
        if [ -n "$token_candidate" ]; then
            node_token="$token_candidate"
        fi
    fi

    local cert_content
    cert_content=$(cat "$cert_src")

    local tmp_node
    tmp_node=$(mktemp)
    jq --arg nm "$NODE_NAME" --arg ip "$NODE_IP" --arg pt "$NODE_SSH_PORT" --arg usr "$NODE_SSH_USER" \
       --arg pwd "$NODE_SSH_PASS" --arg dom "$full_hostname" --arg bdom "$selected_domain" \
       --arg sport "$SERVICE_PORT" --arg aport "$API_PORT" --arg tok "$node_token" \
       'map(select(.hostname != $nm)) + [{
          "hostname": $nm,
          "ip": $ip,
          "ssh_port": $pt,
          "ssh_user": $usr,
          "ssh_pass": $pwd,
          "address": $dom,
          "base_domain": $bdom,
          "service_port": $sport,
          "api_port": $aport,
          "api_token": $tok,
          "ssl_cert_path": "/var/lib/pg-node/certs/ssl_cert.pem",
          "ssl_key_path": "/var/lib/pg-node/certs/ssl_key.pem",
          "deployed_at": (now | todate)
       }]' "$NODES_FILE" > "$tmp_node" && mv "$tmp_node" "$NODES_FILE"

    echo -e "\n${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}       NODE DEPLOYMENT SUMMARY FOR PASARGUARD PANEL        ${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Node Name:${COLOR_RESET}     $NODE_NAME"
    echo -e "  ${COLOR_BOLD}Address:${COLOR_RESET}       $full_hostname"
    echo -e "  ${COLOR_BOLD}Service Port:${COLOR_RESET}  $SERVICE_PORT"
    echo -e "  ${COLOR_BOLD}API Port:${COLOR_RESET}      $API_PORT"
    echo -e "  ${COLOR_BOLD}Cert Path:${COLOR_RESET}     /var/lib/pg-node/certs/ssl_cert.pem"
    echo -e "  ${COLOR_BOLD}Key Path:${COLOR_RESET}      /var/lib/pg-node/certs/ssl_key.pem"
    if [ "$node_token" != "Not detected" ]; then
        echo -e "  ${COLOR_BOLD}API Token:${COLOR_RESET}     ${COLOR_YELLOW}$node_token${COLOR_RESET}"
    fi
    echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_BOLD}Public Certificate Content:${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}$cert_content${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}\n"
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

    local target_ip target_port target_user target_pass target_host target_addr target_sport target_aport target_token target_bdom
    target_ip=$(jq -r ".[$((N_IDX - 1))].ip" "$NODES_FILE")
    target_port=$(jq -r ".[$((N_IDX - 1))].ssh_port" "$NODES_FILE")
    target_user=$(jq -r ".[$((N_IDX - 1))].ssh_user" "$NODES_FILE")
    target_pass=$(jq -r ".[$((N_IDX - 1))].ssh_pass" "$NODES_FILE")
    target_host=$(jq -r ".[$((N_IDX - 1))].hostname" "$NODES_FILE")
    target_addr=$(jq -r ".[$((N_IDX - 1))].address" "$NODES_FILE")
    target_sport=$(jq -r ".[$((N_IDX - 1))].service_port // 62050" "$NODES_FILE")
    target_aport=$(jq -r ".[$((N_IDX - 1))].api_port // 62051" "$NODES_FILE")
    target_token=$(jq -r ".[$((N_IDX - 1))].api_token // empty" "$NODES_FILE")
    target_bdom=$(jq -r ".[$((N_IDX - 1))].base_domain" "$NODES_FILE")

    local ssh_cmd="sshpass -p '$target_pass' ssh -p $target_port -o StrictHostKeyChecking=no $target_user@$target_ip"

    if [ -z "$target_token" ] || [[ "$target_token" == *"#"* ]] || [ "$target_token" == "Not detected" ]; then
        local live_tok
        live_tok=$(eval "$ssh_cmd 'grep -E \"^[A-Z_]*KEY=\" /opt/pg-node/.env 2>/dev/null | cut -d\"=\" -f2 | tr -d \" \\r\\n\"'" | grep -oE '[0-9a-fA-F-]{36}' | head -n 1 || true)
        if [ -n "$live_tok" ]; then
            target_token="$live_tok"
            local tmp_sync
            tmp_sync=$(mktemp)
            jq --arg idx "$((N_IDX - 1))" --arg tok "$live_tok" '.[($idx|tonumber)].api_token = $tok' "$NODES_FILE" > "$tmp_sync" && mv "$tmp_sync" "$NODES_FILE"
        fi
    fi

    echo -e "\nActions for node: $target_host - $target_ip"
    echo "  1) View Panel Connection Info (Address, Ports, Token and Full Card)"
    echo "  2) Restart PasarGuard Node Container / Service"
    echo "  3) Re-sync Wildcard SSL"
    echo "  4) Delete Node from Local Inventory"
    echo "  5) Cancel"
    read -rp "Action [1-5]: " N_ACT

    case "$N_ACT" in
        1)
            local cert_data
            cert_data=$(eval "$ssh_cmd 'cat /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || cat /var/lib/pasarguard/ssl/cert.pem 2>/dev/null'" || true)
            echo -e "\n${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}"
            echo -e "${COLOR_GREEN}${COLOR_BOLD}            PASARGUARD PANEL CONNECTION DETAILS            ${COLOR_RESET}"
            echo -e "${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}"
            echo -e "  ${COLOR_BOLD}Node Name:${COLOR_RESET}     $target_host"
            echo -e "  ${COLOR_BOLD}Address:${COLOR_RESET}       $target_addr"
            echo -e "  ${COLOR_BOLD}Service Port:${COLOR_RESET}  $target_sport"
            echo -e "  ${COLOR_BOLD}API Port:${COLOR_RESET}      $target_aport"
            echo -e "  ${COLOR_BOLD}Cert Path:${COLOR_RESET}     /var/lib/pg-node/certs/ssl_cert.pem"
            echo -e "  ${COLOR_BOLD}Key Path:${COLOR_RESET}      /var/lib/pg-node/certs/ssl_key.pem"
            echo -e "  ${COLOR_BOLD}API Token:${COLOR_RESET}     ${COLOR_YELLOW}${target_token:-Not found}${COLOR_RESET}"
            echo -e "${COLOR_CYAN}------------------------------------------------------------${COLOR_RESET}"
            echo -e "${COLOR_BOLD}Public Certificate Content:${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}$cert_data${COLOR_RESET}"
            echo -e "${COLOR_GREEN}${COLOR_BOLD}============================================================${COLOR_RESET}\n"
            ;;
        2)
            eval "$ssh_cmd 'cat /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || cat /var/lib/pasarguard/ssl/cert.pem'" || log ERROR "Failed to read cert."
            ;;
        3)
            eval "$ssh_cmd 'cd /opt/pg-node && docker compose restart 2>/dev/null || docker restart node 2>/dev/null || true'"
            log OK "Restart command dispatched."
            ;;
        4)
            local c_src="/etc/letsencrypt/live/$target_bdom/fullchain.pem"
            local k_src="/etc/letsencrypt/live/$target_bdom/privkey.pem"
            cat "$c_src" | eval "$ssh_cmd 'cat > /var/lib/pg-node/certs/ssl_cert.pem && cat > /var/lib/pasarguard/ssl/cert.pem && chmod 644 /var/lib/pg-node/certs/ssl_cert.pem /var/lib/pasarguard/ssl/cert.pem'"
            cat "$k_src" | eval "$ssh_cmd 'cat > /var/lib/pg-node/certs/ssl_key.pem && cat > /var/lib/pasarguard/ssl/key.pem && chmod 600 /var/lib/pg-node/certs/ssl_key.pem /var/lib/pasarguard/ssl/key.pem'"
            eval "$ssh_cmd 'cd /opt/pg-node && docker compose restart 2>/dev/null || docker restart node 2>/dev/null || true'"
            log OK "Wildcard SSL re-synced and service restarted."
            ;;
        5)
            local tmp_d
            tmp_d=$(mktemp)
            jq "del(.[$((N_IDX - 1))])" "$NODES_FILE" > "$tmp_d" && mv "$tmp_d" "$NODES_FILE"
            log OK "Node removed from local inventory."
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
            sudo mkdir -p /var/lib/pasarguard/ssl /var/lib/pg-node/certs
            sudo cat "$cert" | sudo tee /var/lib/pasarguard/ssl/cert.pem >/dev/null
            sudo cat "$key" | sudo tee /var/lib/pasarguard/ssl/key.pem >/dev/null
            sudo cp /var/lib/pasarguard/ssl/cert.pem /var/lib/pg-node/certs/ssl_cert.pem
            sudo cp /var/lib/pasarguard/ssl/key.pem /var/lib/pg-node/certs/ssl_key.pem

            local node_count
            node_count=$(jq '. | length' "$NODES_FILE")
            for n in $(seq 0 $((node_count - 1))); do
                local nbdom nip nport nuser npass
                nbdom=$(jq -r ".[$n].base_domain" "$NODES_FILE")
                if [ "$nbdom" == "$dom" ]; then
                    nip=$(jq -r ".[$n].ip" "$NODES_FILE")
                    nport=$(jq -r ".[$n].ssh_port" "$NODES_FILE")
                    nuser=$(jq -r ".[$n].ssh_user" "$NODES_FILE")
                    npass=$(jq -r ".[$n].ssh_pass" "$NODES_FILE")

                    log INFO "Pushing updated certs to node ($nip)..."
                    local sc="sshpass -p '$npass' ssh -p $nport -o StrictHostKeyChecking=no $nuser@$nip"
                    cat "$cert" | eval "$sc 'cat > /var/lib/pg-node/certs/ssl_cert.pem && cat > /var/lib/pasarguard/ssl/cert.pem && chmod 644 /var/lib/pg-node/certs/ssl_cert.pem /var/lib/pasarguard/ssl/cert.pem'"
                    cat "$key" | eval "$sc 'cat > /var/lib/pg-node/certs/ssl_key.pem && cat > /var/lib/pasarguard/ssl/key.pem && chmod 600 /var/lib/pg-node/certs/ssl_key.pem /var/lib/pasarguard/ssl/key.pem'"
                    eval "$sc 'cd /opt/pg-node && docker compose restart 2>/dev/null || docker restart node 2>/dev/null || true'"
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
    echo -e "  [1] Deploy New Node (Auto SSL Injection & Zero Self-Signed)"
    echo -e "  [2] Issue Wildcard SSL Certificate (Let's Encrypt + Cloudflare)"
    echo -e "  [3] Sync SSL to Local Master Server"
    echo -e "  [4] Manage Saved Nodes (Inspect, Restart, Re-sync SSL)"
    echo -e "  [5] Domain Profiles Manager"
    echo -e "  [6] Renew & Synchronize All SSLs"
    echo -e "  [7] View Execution Logs"
    echo -e "  [8] Exit"
    echo ""
    read -rp "Select an option [1-8]: " OPTION

    case "$OPTION" in
        1) deploy_new_node ;;
        2) issue_wildcard_ssl ;;
        3) 
           echo -e "\nSyncing to Master SSL directories..."
           list_domain_profiles && {
               read -rp "Select Domain Index: " D_IDX
               D_SEL=$(jq -r ".[$((D_IDX - 1))].domain" "$DOMAINS_FILE")
               sudo mkdir -p /var/lib/pasarguard/ssl /var/lib/pg-node/certs
               sudo cat "/etc/letsencrypt/live/$D_SEL/fullchain.pem" | sudo tee /var/lib/pasarguard/ssl/cert.pem >/dev/null
               sudo cat "/etc/letsencrypt/live/$D_SEL/privkey.pem" | sudo tee /var/lib/pasarguard/ssl/key.pem >/dev/null
               sudo cp /var/lib/pasarguard/ssl/cert.pem /var/lib/pg-node/certs/ssl_cert.pem
               sudo cp /var/lib/pasarguard/ssl/key.pem /var/lib/pg-node/certs/ssl_key.pem
               sudo chmod 644 /var/lib/pasarguard/ssl/cert.pem /var/lib/pg-node/certs/ssl_cert.pem
               sudo chmod 600 /var/lib/pasarguard/ssl/key.pem /var/lib/pg-node/certs/ssl_key.pem
               log OK "Master SSL synced successfully."
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
        6) renew_sync_all_ssl ;;
        7) [ -f "$LOG_FILE" ] && tail -n 50 "$LOG_FILE" || echo "No logs found." ;;
        8) echo "Goodbye!"; exit 0 ;;
        *) echo -e "${COLOR_RED}Invalid option.${COLOR_RESET}" ;;
    esac
done
