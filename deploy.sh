#!/bin/bash

# ==============================================================================
# PasarGuard Multi-Node Auto-Deployer (Ultra-UI Edition)
# High-End Visual TUI | Multi-Node | Multi-IP | Clean IPs | Backup & Restore
# ==============================================================================

set -o pipefail

REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
APP_DIR="$(cd "$(dirname "$REAL_PATH")" && pwd)"
DOMAINS_FILE="$APP_DIR/domains.json"
NODES_FILE="$APP_DIR/nodes.json"
PRESETS_FILE="$APP_DIR/dns_presets.json"
BACKUP_DIR="$APP_DIR/backups"
LOG_FILE="$APP_DIR/deployer.log"

# --- Advanced Terminal Visual Palette ---
RST="\e[0m"
BOLD="\e[1m"
DIM="\e[2m"
ITALIC="\e[3m"
C_RED="\e[38;5;196m"
C_GREEN="\e[38;5;48m"
C_YELLOW="\e[38;5;220m"
C_BLUE="\e[38;5;39m"
C_PURPLE="\e[38;5;141m"
C_CYAN="\e[38;5;51m"
C_WHITE="\e[38;5;255m"
C_GRAY="\e[38;5;244m"
BG_PRIMARY="\e[48;5;236m"
BG_BLUE="\e[48;5;24m"

ui_banner() {
    clear 2>/dev/null || true
    echo -e "${C_CYAN}╭────────────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██████╗  ██████╗${RST} ${BOLD}${C_PURPLE}██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██╔══██╗██╔════╝${RST} ${BOLD}${C_PURPLE}██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██████╔╝██║  ███╗${RST}${BOLD}${C_PURPLE}██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝ ${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██╔═══╝ ██║   ██║${RST}${BOLD}${C_PURPLE}██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝  ${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${BOLD}${C_BLUE}██║     ╚██████╔╝${RST}${BOLD}${C_PURPLE}██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║   ${RST}   ${C_CYAN}│${RST}"
    echo -e "${C_CYAN}│${RST}  ${DIM}Automated DevOps by Saeed SK (@saeedsk32) v5.4${RST}         ${C_CYAN}│${RST}"
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

install_base_tools() {
    local missing_pkgs=()
    for pkg in jq sshpass curl certbot python3-certbot-dns-cloudflare tar python3; do
        if ! command -v "$pkg" >/dev/null 2>&1 && ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log INFO "Installing core modules: ${missing_pkgs[*]}..."
        sudo apt-get update -qq
        sudo apt-get install -qq -y "${missing_pkgs[@]}" >/dev/null 2>&1
        log OK "Base dependencies verified."
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
        echo -e "  ${C_YELLOW}No domain profiles registered yet.${RST}"
        return 1
    fi
    echo -e "\n  ${BOLD}${C_CYAN}Registered Cloudflare Domains:${RST}"
    jq -r 'to_entries[] | "    \u001b[38;5;141m[" + ((.key + 1) | tostring) + "]\u001b[0m \u001b[1m" + .value.domain + "\u001b[0m \u001b[38;5;244m(Zone: " + .value.zone_id + ")\u001b[0m"' "$DOMAINS_FILE"
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
        log OK "DNS $record_name ($rec_type) active. Comment synced."
    else
        local post_res
        post_res=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
             -H "Authorization: Bearer $token" \
             -H "Content-Type: application/json" \
             --data "{\"type\":\"$rec_type\",\"name\":\"$record_name\",\"content\":\"$ip_address\",\"ttl\":1,\"proxied\":false,\"comment\":\"$comment_text\"}")

        if echo "$post_res" | jq -e '.success' >/dev/null 2>&1; then
            log OK "Created DNS Record: $record_name ($rec_type: $ip_address)"
        else
            local err_msg
            err_msg=$(echo "$post_res" | jq -r '.errors[0].message // "Unknown error"')
            log WARN "DNS record skipped: $err_msg"
        fi
    fi
}

# ==============================================================================
# SECTION 1: NODE MANAGEMENT
# ==============================================================================

deploy_new_node() {
    echo -e "\n  ${BOLD}${C_CYAN}╭──────────────────────────────────────────────────╮${RST}"
    echo -e "  ${BOLD}${C_CYAN}│           🚀  DEPLOY NEW PASARGUARD NODE         │${RST}"
    echo -e "  ${BOLD}${C_CYAN}╰──────────────────────────────────────────────────╯${RST}"
    if ! list_domain_profiles; then
        echo -e "  ${C_YELLOW}Please add a domain profile first in Domain & SSL Manager.${RST}"
        return 1
    fi

    local count
    count=$(get_domains_count)
    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Main Domain Profile [1-$count]: ${RST}")" DOM_IDX
    if ! [[ "$DOM_IDX" =~ ^[0-9]+$ ]] || [ "$DOM_IDX" -lt 1 ] || [ "$DOM_IDX" -gt "$count" ]; then
        log ERROR "Invalid profile selection."
        return 1
    fi

    local selected_domain selected_token selected_zone
    selected_domain=$(jq -r ".[$((DOM_IDX - 1))].domain" "$DOMAINS_FILE")
    selected_token=$(jq -r ".[$((DOM_IDX - 1))].token" "$DOMAINS_FILE")
    selected_zone=$(jq -r ".[$((DOM_IDX - 1))].zone_id" "$DOMAINS_FILE")

    read -rp "$(echo -e "  ${C_PURPLE}▶ Node Hostname [node-DE1]: ${RST}")" NODE_NAME
    NODE_NAME=${NODE_NAME:-"node-DE1"}
    
    read -rp "$(echo -e "  ${C_PURPLE}▶ Primary Server IPv4: ${RST}")" NODE_IP
    read -rp "$(echo -e "  ${C_PURPLE}▶ Server IPv6 (Optional, Enter to skip): ${RST}")" NODE_IPV6
    NODE_IPV6=$(echo "$NODE_IPV6" | tr -d ' ')
    read -rp "$(echo -e "  ${C_PURPLE}▶ Additional IPv4s (comma-separated, Optional): ${RST}")" EXTRA_IPS
    
    read -rp "$(echo -e "  ${C_PURPLE}▶ SSH Port [22]: ${RST}")" NODE_SSH_PORT
    NODE_SSH_PORT=${NODE_SSH_PORT:-22}
    read -rp "$(echo -e "  ${C_PURPLE}▶ SSH User [root]: ${RST}")" NODE_SSH_USER
    NODE_SSH_USER=${NODE_SSH_USER:-root}
    read -rsp "$(echo -e "  ${C_PURPLE}▶ SSH Password: ${RST}")" NODE_SSH_PASS
    echo ""

    echo -e "\n  ${C_GRAY}Example: Entering '${BOLD}de1${RST}${C_GRAY}' maps to '${BOLD}de1.$selected_domain${RST}${C_GRAY}'${RST}"
    read -rp "$(echo -e "  ${C_PURPLE}▶ Subdomain prefix for node [de1]: ${RST}")" SUBDOMAIN_PREFIX
    SUBDOMAIN_PREFIX=${SUBDOMAIN_PREFIX:-"de1"}

    read -rp "$(echo -e "  ${C_PURPLE}▶ Node Port (Main Port in Panel) [62051]: ${RST}")" SERVICE_PORT
    SERVICE_PORT=${SERVICE_PORT:-62051}
    read -rp "$(echo -e "  ${C_PURPLE}▶ Advanced API Port (Background Port) [62050]: ${RST}")" API_PORT
    API_PORT=${API_PORT:-62050}

    read -rp "$(echo -e "  ${C_PURPLE}▶ Select Protocol: [1] gRPC (Default) or [2] REST [1]: ${RST}")" PROTO_CHOICE
    local PROTO_FLAG="--use-grpc"
    local PROTO_NAME="grpc"
    if [ "$PROTO_CHOICE" == "2" ] || [[ "$PROTO_CHOICE" =~ ^[Rr] ]]; then
        PROTO_FLAG="--use-rest"
        PROTO_NAME="rest"
    fi

    # DNS Presets Selection
    echo -e "\n  ${BOLD}${C_CYAN}Cloudflare DNS Auto-Pointing Templates:${RST}"
    local p_keys=()
    while IFS= read -r k; do p_keys+=("$k"); done < <(jq -r 'keys[]' "$PRESETS_FILE")

    for i in "${!p_keys[@]}"; do
        local p_name="${p_keys[$i]}"
        local p_records
        p_records=$(jq -c --arg k "$p_name" '.[$k]' "$PRESETS_FILE")
        echo -e "    ${C_PURPLE}[$((i + 1))]${RST} ${BOLD}$p_name${RST} ${C_GRAY}-> $p_records${RST}"
    done
    echo -e "    ${C_GRAY}[0] Custom / Skip Templates${RST}"
    read -rp "$(echo -e "  ${C_PURPLE}▶ Select DNS Preset [1-${#p_keys[@]} or 0]: ${RST}")" P_SEL

    local preset_subs=()
    if [[ "$P_SEL" =~ ^[1-9][0-9]*$ ]] && [ "$P_SEL" -le "${#p_keys[@]}" ]; then
        local chosen_key="${p_keys[$((P_SEL - 1))]}"
        while IFS= read -r sub_val; do preset_subs+=("$sub_val"); done < <(jq -r --arg k "$chosen_key" '.[$k][]' "$PRESETS_FILE")
        log INFO "Loaded DNS Preset: $chosen_key"
    fi

    read -rp "$(echo -e "  ${C_PURPLE}▶ Extra Custom Subdomains (comma-separated, Optional): ${RST}")" MANUAL_SUBS

    echo -e "\n  ${BOLD}${C_CYAN}Multi-Domain SSL Pre-Deployment:${RST}"
    jq -r 'to_entries[] | "    \u001b[38;5;141m[" + ((.key + 1) | tostring) + "]\u001b[0m \u001b[1m" + .value.domain + "\u001b[0m"' "$DOMAINS_FILE"
    read -rp "$(echo -e "  ${C_PURPLE}▶ Select Profiles to Inject (e.g. '1, 2' or Enter for primary only): ${RST}")" EXTRA_DOM_IDXS

    read -rp "$(echo -e "  ${C_PURPLE}▶ Install PasarGuard Node binary? [Y/n]: ${RST}")" INSTALL_PG
    INSTALL_PG=${INSTALL_PG:-Y}

    local SYSTEMD_FLAG="--install-service"
    if [[ "$INSTALL_PG" =~ ^[Yy]$ ]]; then
        read -rp "$(echo -e "  ${C_PURPLE}▶ Install and start systemd background service? [Y/n]: ${RST}")" ASK_SYSTEMD
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
        log ERROR "Certificates not found for $selected_domain in Let's Encrypt store."
        return 1
    fi

    log INFO "Verifying SSH connection to $NODE_IP:$NODE_SSH_PORT..."
    if ! sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$NODE_SSH_USER@$NODE_IP" "echo connected" >/dev/null 2>&1; then
        log ERROR "Cannot connect via SSH. Verify IP, port, and credentials."
        return 1
    fi
    log OK "SSH connection established."

    log INFO "Tuning kernel TCP BBR and baseline firewall..."
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

    log INFO "Deploying Wildcard SSL keys to remote node..."
    cat "$fullchain_src" | sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no "$NODE_SSH_USER@$NODE_IP" "cat > /tmp/node_ssl/cert.pem && chmod 644 /tmp/node_ssl/cert.pem"
    cat "$key_src" | sshpass -p "$NODE_SSH_PASS" ssh -p "$NODE_SSH_PORT" -o StrictHostKeyChecking=no "$NODE_SSH_USER@$NODE_IP" "cat > /tmp/node_ssl/key.pem && chmod 600 /tmp/node_ssl/key.pem"
    log OK "Primary Wildcard SSL transferred."

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
        log INFO "Provisioning PasarGuard Node core ($PROTO_NAME)..."
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
        [ -n "$token_candidate" ] && node_token="$token_candidate"
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

    echo -e "\n  ${C_GREEN}╭────────────────────────────────────────────────────────────────────────╮${RST}"
    echo -e "  ${C_GREEN}│${RST}        ${BOLD}${C_WHITE}✔ PASARGUARD NODE DEPLOYED SUCCESSFULLY${RST}                       ${C_GREEN}│${RST}"
    echo -e "  ${C_GREEN}├────────────────────────────────────────────────────────────────────────┤${RST}"
    printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : %-47s ${C_GREEN}│${RST}\n" "Node Name" "$NODE_NAME"
    printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : %-47s ${C_GREEN}│${RST}\n" "Node Address" "$full_hostname"
    printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : ${C_GREEN}%-47s${RST} ${C_GREEN}│${RST}\n" "Node Port (Panel)" "$SERVICE_PORT"
    printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : ${C_YELLOW}%-47s${RST} ${C_GREEN}│${RST}\n" "API Port (Advanced)" "$API_PORT"
    printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : ${C_CYAN}%-47s${RST} ${C_GREEN}│${RST}\n" "Protocol" "${PROTO_NAME^^}"
    printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : ${C_YELLOW}%-47s${RST} ${C_GREEN}│${RST}\n" "API Key" "$node_token"
    echo -e "  ${C_GREEN}├────────────────────────────────────────────────────────────────────────┤${RST}"
    echo -e "  ${C_GREEN}│${RST}  ${BOLD}Cloudflare DNS Records:${RST}                                               ${C_GREEN}│${RST}"
    for rec in "${created_dns_list[@]}"; do
        printf "  ${C_GREEN}│${RST}   • %-66s ${C_GREEN}│${RST}\n" "$rec"
    done
    echo -e "  ${C_GREEN}├────────────────────────────────────────────────────────────────────────┤${RST}"
    echo -e "  ${C_GREEN}│${RST}  ${BOLD}Certificate (Copy exactly into Panel Certificate box):${RST}                ${C_GREEN}│${RST}"
    echo -e "  ${C_GREEN}╰────────────────────────────────────────────────────────────────────────╯${RST}"
    echo -e "${C_YELLOW}$leaf_cert${RST}\n"
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

    echo -e "\n  ${BOLD}${C_CYAN}--- Migrate / Change IP for Node: $target_host ---${RST}"
    echo -e "  Current Registered IP: ${C_RED}$old_ip${RST}"
    read -rp "$(echo -e "  ${C_PURPLE}▶ Enter NEW Server IPv4: ${RST}")" NEW_IP
    NEW_IP=$(echo "$NEW_IP" | tr -d ' ')
    [ -z "$NEW_IP" ] && { log ERROR "New IP cannot be empty."; return 1; }

    read -rp "$(echo -e "  ${C_PURPLE}▶ Keep current SSH Password? [Y/n]: ${RST}")" KEEP_PASS
    KEEP_PASS=${KEEP_PASS:-Y}
    if ! [[ "$KEEP_PASS" =~ ^[Yy]$ ]]; then
        read -rsp "$(echo -e "  ${C_PURPLE}▶ Enter new SSH Password: ${RST}")" target_pass
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
    echo -e "  ${C_GREEN}✔ Node $target_host now points to new IP: $NEW_IP${RST}\n"
}

manage_saved_nodes() {
    local count
    count=$(jq '. | length' "$NODES_FILE")
    if [ "$count" -eq 0 ]; then
        echo -e "  ${C_YELLOW}No deployed nodes registered.${RST}"
        return 0
    fi

    echo -e "\n  ${BOLD}${C_CYAN}Current Active Nodes:${RST}"
    jq -r 'to_entries[] | "    \u001b[38;5;141m[" + ((.key + 1) | tostring) + "]\u001b[0m \u001b[1m" + .value.hostname + "\u001b[0m \u001b[38;5;244m(" + .value.ip + ")\u001b[0m -> " + .value.address' "$NODES_FILE"

    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Node [1-$count]: ${RST}")" N_IDX
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

    echo -e "\n  ${BOLD}${C_CYAN}╭──────────────────────────────────────────────────╮${RST}"
    echo -e "  ${BOLD}${C_CYAN}│      🛠️   MANAGEMENT: $target_host ($target_ip)${RST}"
    echo -e "  ${BOLD}${C_CYAN}╰──────────────────────────────────────────────────╯${RST}"
    echo -e "    ${C_CYAN}[1]${RST} 📄 View Panel Connection Info & Card"
    echo -e "    ${C_GREEN}[2]${RST} ${BOLD}🔁 1-Click Server IP Migration (Auto DNS)${RST}"
    echo -e "    ${C_CYAN}[3]${RST} 🔐 Inject / Manage Multi-Domain SSLs"
    echo -e "    ${C_CYAN}[4]${RST} 🌐 Add Extra Subdomain to this Node"
    echo -e "    ${C_CYAN}[5]${RST} ⚡ Switch Protocol (gRPC <-> REST)"
    echo -e "    ${C_CYAN}[6]${RST} ⚙️  Manage Systemd Service"
    echo -e "    ${C_CYAN}[7]${RST} 📦 Update / Change Xray-core"
    echo -e "    ${C_CYAN}[8]${RST} 🔄 Update PasarGuard Node Software"
    echo -e "    ${C_CYAN}[9]${RST} 🗺️  Update GeoFiles (GeoIP & GeoSite)"
    echo -e "    ${C_CYAN}[10]${RST} ♻️  Restart Node Service"
    echo -e "    ${C_CYAN}[11]${RST} 📜 Follow Live Node Logs (Ctrl+C to exit)"
    echo -e "    ${C_YELLOW}[12]${RST} 🗑️  Delete from Local Inventory Only"
    echo -e "    ${C_RED}[13]${RST} 💣 Completely Uninstall Node & Clean DNS"
    echo -e "    ${C_GRAY}[0]${RST}  Back"
    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Choose Action [0-13]: ${RST}")" N_ACT

    case "$N_ACT" in
        1)
            local cert_data single_cert
            cert_data=$(eval "$ssh_cmd 'cat /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || cat /var/lib/pasarguard/ssl/cert.pem 2>/dev/null'" || true)
            single_cert=$(echo "$cert_data" | openssl x509 2>/dev/null || echo "$cert_data")
            
            echo -e "\n  ${C_GREEN}╭────────────────────────────────────────────────────────────────────────╮${RST}"
            echo -e "  ${C_GREEN}│${RST}        ${BOLD}${C_WHITE}PASARGUARD PANEL CONNECTION DETAILS${RST}                             ${C_GREEN}│${RST}"
            echo -e "  ${C_GREEN}├────────────────────────────────────────────────────────────────────────┤${RST}"
            printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : %-47s ${C_GREEN}│${RST}\n" "Node Name" "$target_host"
            printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : %-47s ${C_GREEN}│${RST}\n" "Node Address" "$target_addr"
            printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : ${C_GREEN}%-47s${RST} ${C_GREEN}│${RST}\n" "Node Port" "$target_sport"
            printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : ${C_YELLOW}%-47s${RST} ${C_GREEN}│${RST}\n" "API Port" "$target_aport"
            printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : ${C_CYAN}%-47s${RST} ${C_GREEN}│${RST}\n" "Connection Type" "${target_proto^^}"
            printf "  ${C_GREEN}│${RST}  ${BOLD}%-20s${RST} : ${C_YELLOW}%-47s${RST} ${C_GREEN}│${RST}\n" "API Key" "${target_token:-Not found}"
            echo -e "  ${C_GREEN}├────────────────────────────────────────────────────────────────────────┤${RST}"
            echo -e "  ${C_GREEN}│${RST}  ${BOLD}Cloudflare DNS Records:${RST}                                               ${C_GREEN}│${RST}"
            jq -r ".[$((N_IDX - 1))].dns_records[]? // empty" "$NODES_FILE" | while read -r drec; do
                printf "  ${C_GREEN}│${RST}   • %-66s ${C_GREEN}│${RST}\n" "$drec"
            done
            echo -e "  ${C_GREEN}├────────────────────────────────────────────────────────────────────────┤${RST}"
            echo -e "  ${C_GREEN}│${RST}  ${BOLD}SSL Certificate (Leaf / <2048 chars for Panel):${RST}                       ${C_GREEN}│${RST}"
            echo -e "  ${C_GREEN}╰────────────────────────────────────────────────────────────────────────╯${RST}"
            echo -e "${C_YELLOW}$single_cert${RST}\n"
            ;;
        2) migrate_node_ip "$((N_IDX - 1))" ;;
        3)
            list_domain_profiles
            local d_count
            d_count=$(get_domains_count)
            read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Domain to Inject [1-$d_count]: ${RST}")" INJ_IDX
            if [[ "$INJ_IDX" =~ ^[0-9]+$ ]] && [ "$INJ_IDX" -ge 1 ] && [ "$INJ_IDX" -le "$d_count" ]; then
                local inj_dom
                inj_dom=$(jq -r ".[$((INJ_IDX - 1))].domain" "$DOMAINS_FILE")
                local inj_fullchain="/etc/letsencrypt/live/$inj_dom/fullchain.pem"
                local inj_key="/etc/letsencrypt/live/$inj_dom/privkey.pem"
                if [ -f "$inj_fullchain" ] && [ -f "$inj_key" ]; then
                    log INFO "Injecting SSL for $inj_dom to $target_host..."
                    eval "$ssh_cmd 'mkdir -p /var/lib/pg-node/certs/$inj_dom'"
                    cat "$inj_fullchain" | eval "$ssh_cmd 'cat > /var/lib/pg-node/certs/$inj_dom/fullchain.pem && chmod 644 /var/lib/pg-node/certs/$inj_dom/fullchain.pem'"
                    cat "$inj_key" | eval "$ssh_cmd 'cat > /var/lib/pg-node/certs/$inj_dom/privkey.pem && chmod 600 /var/lib/pg-node/certs/$inj_dom/privkey.pem'"
                    
                    local tmp_mupd
                    tmp_mupd=$(mktemp)
                    jq --arg idx "$((N_IDX - 1))" --arg ndom "$inj_dom" \
                       '.[($idx|tonumber)].ssl_domains = ((.[($idx|tonumber)].ssl_domains // []) + [$ndom] | unique)' \
                       "$NODES_FILE" > "$tmp_mupd" && mv "$tmp_mupd" "$NODES_FILE"
                    log OK "SSL for $inj_dom active at /var/lib/pg-node/certs/$inj_dom/"
                fi
            fi
            ;;
        4)
            read -rp "$(echo -e "  ${C_PURPLE}▶ Subdomain prefix (e.g. edge1): ${RST}")" NEW_SUB
            NEW_SUB=$(echo "$NEW_SUB" | tr -d ' ')
            read -rp "$(echo -e "  ${C_PURPLE}▶ Target IP [$target_ip]: ${RST}")" CHOSEN_IP
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
            read -rp "$(echo -e "  ${C_PURPLE}▶ Select Protocol [1: gRPC | 2: REST]: ${RST}")" PROTO_SEL
            local p_flag="--use-grpc" p_str="grpc"
            [ "$PROTO_SEL" == "2" ] && { p_flag="--use-rest"; p_str="rest"; }
            eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node install -y --override $p_flag --cert-path /var/lib/pg-node/certs/ssl_cert.pem --key-path /var/lib/pg-node/certs/ssl_key.pem --service-port $target_sport --api-port $target_aport'"
            local tmp_upd
            tmp_upd=$(mktemp)
            jq --arg idx "$((N_IDX - 1))" --arg ps "$p_str" '.[($idx|tonumber)].protocol = $ps' "$NODES_FILE" > "$tmp_upd" && mv "$tmp_upd" "$NODES_FILE"
            log OK "Switched to $p_str protocol."
            ;;
        6)
            read -rp "$(echo -e "  ${C_PURPLE}▶ [1] Install Service | [2] Remove Service: ${RST}")" SYS_SEL
            [ "$SYS_SEL" == "1" ] && eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node service-install'"
            [ "$SYS_SEL" == "2" ] && eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node service-uninstall'"
            ;;
        7)
            read -rp "$(echo -e "  ${C_PURPLE}▶ Enter Xray version [latest]: ${RST}")" X_VER
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
            echo -e "  ${C_RED}${BOLD}WARNING: Will wipe node software, DNS records and inventory.${RST}"
            read -rp "$(echo -e "  ${C_RED}Type 'yes' to confirm: ${RST}")" CONFIRM_PURGE
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
        ui_banner
        echo -e "  ${BOLD}${C_CYAN}MODULE 1: NODE MANAGEMENT${RST}"
        echo -e "  ${C_GRAY}Deploy, configure and orchestrate PasarGuard remote nodes${RST}\n"
        echo -e "  ${C_CYAN}[1]${RST} 🚀 Deploy New Node ${C_GRAY}(Multi-IP, Multi-SSL & Presets)${RST}"
        echo -e "  ${C_CYAN}[2]${RST} 📋 Manage Saved Nodes ${C_GRAY}(IP Migration, Inbounds & Protocol)${RST}"
        echo -e "  ${C_GRAY}[0]  Back to Main Dashboard${RST}"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" NM_OPT
        case "$NM_OPT" in
            1) deploy_new_node ;;
            2) manage_saved_nodes ;;
            0) break ;;
            *) ;;
        esac
    done
}

# ==============================================================================
# SECTION 2: DOMAINS & SSL MANAGEMENT
# ==============================================================================

renew_sync_all_ssl() {
    echo -e "\n  ${BOLD}${C_CYAN}--- Renew & Synchronize All SSL Certificates ---${RST}"
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
                    log INFO "Pushing renewed cert to node ($nip)..."
                    cat "$cert" | sshpass -p "$npass" ssh -p "$nport" -o StrictHostKeyChecking=no "$nuser@$nip" "cat > /var/lib/pg-node/certs/ssl_cert.pem && cat > /var/lib/pasarguard/ssl/cert.pem && chmod 644 /var/lib/pg-node/certs/ssl_cert.pem /var/lib/pasarguard/ssl/cert.pem"
                    cat "$key" | sshpass -p "$npass" ssh -p "$nport" -o StrictHostKeyChecking=no "$nuser@$nip" "cat > /var/lib/pg-node/certs/ssl_key.pem && cat > /var/lib/pasarguard/ssl/key.pem && chmod 600 /var/lib/pg-node/certs/ssl_key.pem /var/lib/pasarguard/ssl/key.pem"
                    sshpass -p "$npass" ssh -p "$nport" -o StrictHostKeyChecking=no "$nuser@$nip" "export PATH=/usr/local/bin:\$PATH; pg-node restart -n 2>/dev/null || true"
                fi

                local is_sec
                is_sec=$(jq -r --arg d "$dom" ".[$n].ssl_domains[]? | select(. == \$d)" "$NODES_FILE")
                if [ -n "$is_sec" ] && [ "$dom" != "$nbdom" ]; then
                    cat "$cert" | sshpass -p "$npass" ssh -p "$nport" -o StrictHostKeyChecking=no "$nuser@$nip" "cat > /var/lib/pg-node/certs/$dom/fullchain.pem && chmod 644 /var/lib/pg-node/certs/$dom/fullchain.pem"
                    cat "$key" | sshpass -p "$npass" ssh -p "$nport" -o StrictHostKeyChecking=no "$nuser@$nip" "cat > /var/lib/pg-node/certs/$dom/privkey.pem && chmod 600 /var/lib/pg-node/certs/$dom/privkey.pem"
                fi
            done
        fi
    done
    log OK "1-Click Renewal & sync complete across Master and all nodes."
}

domain_management_menu() {
    while true; do
        ui_banner
        echo -e "  ${BOLD}${C_CYAN}MODULE 2: DOMAINS & SSL MANAGER${RST}"
        echo -e "  ${C_GRAY}Wildcard SSL issuance, Certbot orchestration and domain profiles${RST}\n"
        echo -e "  ${C_CYAN}[1]${RST} 🔐 Issue New Wildcard SSL ${C_GRAY}(Let's Encrypt + Cloudflare)${RST}"
        echo -e "  ${C_CYAN}[2]${RST} 🔄 Sync Existing Domain SSL to Master Web Panel"
        echo -e "  ${C_CYAN}[3]${RST} ♻️  Renew & Synchronize All SSLs ${C_GRAY}(Master + All Nodes)${RST}"
        echo -e "  ${C_CYAN}[4]${RST} 📋 List & Delete Registered Domain Profiles"
        echo -e "  ${C_GRAY}[0]  Back to Main Dashboard${RST}"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-4]: ${RST}")" DM_OPT
        case "$DM_OPT" in
            1) issue_wildcard_ssl ;;
            2)
                list_domain_profiles && {
                    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Domain Index: ${RST}")" D_IDX
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
                read -rp "$(echo -e "\n  ${C_PURPLE}▶ Enter Profile Index to Delete (Enter to cancel): ${RST}")" DEL_I
                if [[ "$DEL_I" =~ ^[0-9]+$ ]]; then
                    local tmp_m
                    tmp_m=$(mktemp)
                    jq "del(.[$((DEL_I - 1))])" "$DOMAINS_FILE" > "$tmp_m" && mv "$tmp_m" "$DOMAINS_FILE"
                    log OK "Profile deleted."
                fi
                ;;
            0) break ;;
            *) ;;
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
    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Target Domain Profile [1-$d_count]: ${RST}")" C_DOM_IDX
    if ! [[ "$C_DOM_IDX" =~ ^[0-9]+$ ]] || [ "$C_DOM_IDX" -lt 1 ] || [ "$C_DOM_IDX" -gt "$d_count" ]; then
        return
    fi

    local c_dom c_tok c_zid
    c_dom=$(jq -r ".[$((C_DOM_IDX - 1))].domain" "$DOMAINS_FILE")
    c_tok=$(jq -r ".[$((C_DOM_IDX - 1))].token" "$DOMAINS_FILE")
    c_zid=$(jq -r ".[$((C_DOM_IDX - 1))].zone_id" "$DOMAINS_FILE")

    while true; do
        echo -e "\n  ${BOLD}${C_CYAN}╭──────────────────────────────────────────────────╮${RST}"
        echo -e "  ${BOLD}${C_CYAN}│      ⚡  CLEAN IPS CENTER: $c_dom ${RST}"
        echo -e "  ${BOLD}${C_CYAN}╰──────────────────────────────────────────────────╯${RST}"
        echo -e "    ${C_CYAN}[1]${RST} ➕ Add Clean IPs to Subdomain ${C_GRAY}(Round-Robin DNS)${RST}"
        echo -e "    ${C_CYAN}[2]${RST} 📊 Interactive Records Table ${C_GRAY}(Multi-Select, Edit & Delete)${RST}"
        echo -e "    ${C_GRAY}[0]${RST}  Back"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" CIP_OPT

        case "$CIP_OPT" in
            1)
                read -rp "$(echo -e "  ${C_PURPLE}▶ Subdomain prefix [cdn]: ${RST}")" PREFIX
                PREFIX=${PREFIX:-"cdn"}
                local full_target_sub="$PREFIX.$c_dom"

                read -rp "$(echo -e "  ${C_PURPLE}▶ ISP / Pool Label for Comments [Clean IP]: ${RST}")" ISP_LABEL
                ISP_LABEL=${ISP_LABEL:-"Clean IP"}

                echo -e "  ${C_GRAY}Paste multiple Clean IPs (comma, space, or newline separated):${RST}"
                read -rp "$(echo -e "  ${C_PURPLE}▶ IPs: ${RST}")" RAW_IPS

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
                    echo -e "  ${C_YELLOW}No records tagged with PG-CleanIP found on $c_dom.${RST}"
                    continue
                fi

                echo -e "\n  ${C_CYAN}╭────┬───────────────────────────┬───────┬─────────────────┬────────────────────────────────────────╮${RST}"
                printf "  ${C_CYAN}│${RST} ${BOLD}%-2s${RST} ${C_CYAN}│${RST} ${BOLD}%-25s${RST} ${C_CYAN}│${RST} ${BOLD}%-5s${RST} ${C_CYAN}│${RST} ${BOLD}%-15s${RST} ${C_CYAN}│${RST} ${BOLD}%-38s${RST} ${C_CYAN}│${RST}\n" "#" "Subdomain" "Type" "IP Address" "Comment Tag"
                echo -e "  ${C_CYAN}├────┼───────────────────────────┼───────┼─────────────────┼────────────────────────────────────────┤${RST}"
                for i in "${!rec_ids[@]}"; do
                    printf "  ${C_CYAN}│${RST} %-2d ${C_CYAN}│${RST} %-25s ${C_CYAN}│${RST} %-5s ${C_CYAN}│${RST} %-15s ${C_CYAN}│${RST} %-38s ${C_CYAN}│${RST}\n" "$((i + 1))" "${rec_names[$i]}" "${rec_types[$i]}" "${rec_ips[$i]}" "${rec_comments[$i]}"
                done
                echo -e "  ${C_CYAN}╰────┴───────────────────────────┴───────┴─────────────────┴────────────────────────────────────────╯${RST}"

                echo -e "  ${C_GRAY}Selection: Enter numbers (e.g. 1,3,4) or 'all' to select all records.${RST}"
                read -rp "$(echo -e "  ${C_PURPLE}▶ Select records (or Enter to cancel): ${RST}")" USER_SEL

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
                    echo "  No valid records selected."
                    continue
                fi

                echo -e "\n  ${BOLD}${C_CYAN}Batch Actions for ${#selected_indices[@]} Record(s):${RST}"
                echo -e "    ${C_RED}[1]${RST} 🗑️  Delete selected records"
                echo -e "    ${C_CYAN}[2]${RST} 🏷️  Batch Edit Comment / Tag"
                echo -e "    ${C_CYAN}[3]${RST} ✏️  Edit IP Address (Single record only)"
                echo -e "    ${C_CYAN}[4]${RST} 🔄 Batch Rename / Move Subdomain"
                echo -e "    ${C_GRAY}[0]${RST}  Cancel"
                read -rp "$(echo -e "\n  ${C_PURPLE}▶ Choose action [0-4]: ${RST}")" B_ACT

                case "$B_ACT" in
                    1)
                        read -rp "$(echo -e "  ${C_RED}Are you sure you want to delete ${#selected_indices[@]} record(s)? [y/N]: ${RST}")" CONF_DEL
                        if [[ "$CONF_DEL" =~ ^[Yy]$ ]]; then
                            for s_idx in "${selected_indices[@]}"; do
                                local d_id="${rec_ids[$s_idx]}"
                                curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records/$d_id" \
                                     -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" >/dev/null
                                echo -e "  ${C_RED}✔ Deleted:${RST} ${rec_names[$s_idx]} -> ${rec_ips[$s_idx]}"
                            done
                            log OK "Deleted ${#selected_indices[@]} clean IP records."
                        fi
                        ;;
                    2)
                        read -rp "$(echo -e "  ${C_PURPLE}▶ Enter NEW Comment tag: ${RST}")" NEW_COMMENT
                        if [ -n "$NEW_COMMENT" ]; then
                            for s_idx in "${selected_indices[@]}"; do
                                local d_id="${rec_ids[$s_idx]}"
                                local full_cmt="PG-CleanIP: $NEW_COMMENT | Updated $(date '+%Y-%m-%d')"
                                curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records/$d_id" \
                                     -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" \
                                     --data "{\"comment\":\"$full_cmt\"}" >/dev/null
                                echo -e "  ${C_GREEN}✔ Updated comment:${RST} ${rec_names[$s_idx]}"
                            done
                            log OK "Updated comments for ${#selected_indices[@]} records."
                        fi
                        ;;
                    3)
                        if [ ${#selected_indices[@]} -ne 1 ]; then
                            echo -e "  ${C_RED}IP edit can only be performed on 1 record at a time.${RST}"
                        else
                            local single_i="${selected_indices[0]}"
                            read -rp "$(echo -e "  ${C_PURPLE}▶ Enter new IP for ${rec_names[$single_i]}: ${RST}")" REPL_IP
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
                        read -rp "$(echo -e "  ${C_PURPLE}▶ Enter NEW Subdomain prefix (e.g. speed): ${RST}")" NEW_SUB_PREFIX
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
                                echo -e "  ${C_GREEN}✔ Renamed:${RST} ${rec_names[$s_idx]} -> ${BOLD}$new_fqdn${RST} ($curr_ip)"
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
        echo -e "\n  ${BOLD}${C_CYAN}--- Subdomain Templates / Presets ---${RST}"
        jq -r 'to_entries[] | "    \u001b[38;5;141m[" + .key + "]\u001b[0m: " + (.value | join(", "))' "$PRESETS_FILE"
        echo ""
        echo -e "    ${C_CYAN}[1]${RST} ➕ Add / Update Preset"
        echo -e "    ${C_RED}[2]${RST} 🗑️  Delete Preset"
        echo -e "    ${C_GRAY}[0]${RST}  Back"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" PR_OPT

        case "$PR_OPT" in
            1)
                read -rp "$(echo -e "  ${C_PURPLE}▶ Preset Name (e.g. speed): ${RST}")" PNAME
                PNAME=$(echo "$PNAME" | tr ' ' '_')
                read -rp "$(echo -e "  ${C_PURPLE}▶ Subdomains (comma-separated): ${RST}")" PSUBS
                if [ -n "$PNAME" ] && [ -n "$PSUBS" ]; then
                    local subs_json
                    subs_json=$(echo "$PSUBS" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | grep -v '^$' | jq -R . | jq -s .)
                    local tmp_pr
                    tmp_pr=$(mktemp)
                    jq --arg k "$PNAME" --argjson v "$subs_json" '.[$k] = $v' "$PRESETS_FILE" > "$tmp_pr" && mv "$tmp_pr" "$PRESETS_FILE"
                    log OK "Preset '$PNAME' saved."
                fi
                ;;
            2)
                read -rp "$(echo -e "  ${C_PURPLE}▶ Preset Name to delete: ${RST}")" PNAME_DEL
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
        ui_banner
        echo -e "  ${BOLD}${C_CYAN}MODULE 3: CLOUDFLARE DNS CENTER${RST}"
        echo -e "  ${C_GRAY}Round-Robin Clean IP pools and subdomain preset templates${RST}\n"
        echo -e "  ${C_CYAN}[1]${RST} ⚡ Clean IPs Center ${C_GRAY}(Interactive Table & Batch Ops)${RST}"
        echo -e "  ${C_CYAN}[2]${RST} 📋 DNS Subdomain Templates ${C_GRAY}(Presets for Nodes)${RST}"
        echo -e "  ${C_GRAY}[0]  Back to Main Dashboard${RST}"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" CFC_OPT
        case "$CFC_OPT" in
            1) manage_clean_ips_interactive ;;
            2) manage_dns_presets ;;
            0) break ;;
            *) ;;
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
    local backup_name="pg_deploy_backup_${timestamp}.tar.gz"
    local backup_file="$BACKUP_DIR/$backup_name"

    log INFO "Creating full configuration and SSL backup archive..."
    local backup_items=("$DOMAINS_FILE" "$NODES_FILE" "$PRESETS_FILE")
    [ -d "/etc/letsencrypt" ] && backup_items+=("/etc/letsencrypt")
    [ -d "/root/.secrets/certbot" ] && backup_items+=("/root/.secrets/certbot")
    [ -d "/var/lib/pasarguard/certs" ] && backup_items+=("/var/lib/pasarguard/certs")
    [ -d "/var/lib/pasarguard/ssl" ] && backup_items+=("/var/lib/pasarguard/ssl")

    if sudo tar -czf "$backup_file" -P "${backup_items[@]}" 2>/dev/null; then
        sudo chmod 644 "$backup_file"
        log OK "Backup successfully created: $backup_file"
        
        local srv_ip
        srv_ip=$(curl -s -4 --max-time 3 ifconfig.io 2>/dev/null || hostname -I | awk '{print $1}')
        local dl_port=8088

        echo -e "\n  ${C_GREEN}╭────────────────────────────────────────────────────────────────────────╮${RST}"
        echo -e "  ${C_GREEN}│${RST}        ${BOLD}${C_WHITE}✔ FULL BACKUP ARCHIVE READY FOR DOWNLOAD${RST}                     ${C_GREEN}│${RST}"
        echo -e "  ${C_GREEN}├────────────────────────────────────────────────────────────────────────┤${RST}"
        printf "  ${C_GREEN}│${RST}  ${BOLD}%-15s${RST} : %-52s ${C_GREEN}│${RST}\n" "File Name" "$backup_name"
        printf "  ${C_GREEN}│${RST}  ${BOLD}%-15s${RST} : %-52s ${C_GREEN}│${RST}\n" "File Size" "$(du -h "$backup_file" | awk '{print $1}')"
        echo -e "  ${C_GREEN}├────────────────────────────────────────────────────────────────────────┤${RST}"
        echo -e "  ${C_GREEN}│${RST}  ${BOLD}Direct Browser Download Link:${RST}                                         ${C_GREEN}│${RST}"
        printf "  ${C_GREEN}│${RST}  ${C_YELLOW}${BOLD}%-70s${RST} ${C_GREEN}│${RST}\n" "http://$srv_ip:$dl_port/$backup_name"
        echo -e "  ${C_GREEN}╰────────────────────────────────────────────────────────────────────────╯${RST}"
        echo -e "  ${C_GRAY}Server listening on port $dl_port. Download via browser, then press [ENTER] to stop.${RST}"

        sudo ufw allow $dl_port/tcp >/dev/null 2>&1 || true
        (cd "$BACKUP_DIR" && python3 -m http.server $dl_port >/dev/null 2>&1) &
        local srv_pid=$!

        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Press [ENTER] to close download server: ${RST}")"
        
        kill "$srv_pid" 2>/dev/null || true
        sudo ufw delete allow $dl_port/tcp >/dev/null 2>&1 || true
        sudo chmod 600 "$backup_file"
        log OK "Download server closed and port secured."
    else
        log ERROR "Failed to create backup archive."
    fi
}

restore_full_backup() {
    echo -e "\n  ${BOLD}${C_CYAN}--- Restore Configuration & SSLs ---${RST}"
    local backups=($(ls -t "$BACKUP_DIR"/pg_deploy_backup_*.tar.gz 2>/dev/null || true))

    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "  ${C_YELLOW}No backup archives found in $BACKUP_DIR.${RST}"
        read -rp "$(echo -e "  ${C_PURPLE}▶ Path to custom tar.gz file (Enter to cancel): ${RST}")" CUSTOM_BCK
        [ -z "$CUSTOM_BCK" ] && return
        local selected_archive="$CUSTOM_BCK"
    else
        echo -e "  ${C_CYAN}Available Backup Archives:${RST}"
        for i in "${!backups[@]}"; do
            echo -e "    ${C_PURPLE}[$((i + 1))]${RST} $(basename "${backups[$i]}") ${C_GRAY}($(du -h "${backups[$i]}" | awk '{print $1}'))${RST}"
        done
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Backup [1-${#backups[@]}]: ${RST}")" B_IDX
        if ! [[ "$B_IDX" =~ ^[0-9]+$ ]] || [ "$B_IDX" -lt 1 ] || [ "$B_IDX" -gt "${#backups[@]}" ]; then
            log ERROR "Invalid selection."
            return
        fi
        local selected_archive="${backups[$((B_IDX - 1))]}"
    fi

    echo -e "  ${C_RED}${BOLD}WARNING: Restoring will overwrite existing databases and Let's Encrypt keys!${RST}"
    read -rp "$(echo -e "  ${C_RED}Type 'yes' to proceed: ${RST}")" CONFIRM_RES
    if [ "$CONFIRM_RES" == "yes" ]; then
        log INFO "Extracting $selected_archive..."
        sudo tar -xzf "$selected_archive" -P
        
        sudo chmod 644 "$DOMAINS_FILE" "$NODES_FILE" "$PRESETS_FILE" 2>/dev/null || true
        sudo chmod -R 700 /root/.secrets/certbot 2>/dev/null || true
        sudo chmod -R 600 /root/.secrets/certbot/* 2>/dev/null || true
        sudo chmod -R 755 /etc/letsencrypt 2>/dev/null || true
        
        pasarguard restart 2>/dev/null || true
        log OK "Restore completed and master panel services restarted."
    fi
}

backup_restore_menu() {
    while true; do
        ui_banner
        echo -e "  ${BOLD}${C_CYAN}MODULE 4: BACKUP & RESTORE CENTER${RST}"
        echo -e "  ${C_GRAY}Automated disaster recovery, JSON exports and browser download${RST}\n"
        echo -e "  ${C_CYAN}[1]${RST} 💾 Create Complete Backup ${C_GRAY}(Instant Browser Download Link)${RST}"
        echo -e "  ${C_CYAN}[2]${RST} 🔁 Restore from Backup Archive ${C_GRAY}(1-Click Restore)${RST}"
        echo -e "  ${C_CYAN}[3]${RST} 📄 Quick JSON Print ${C_GRAY}(Export Nodes & Domains in Terminal)${RST}"
        echo -e "  ${C_GRAY}[0]  Back to Main Dashboard${RST}"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-3]: ${RST}")" BKP_OPT

        case "$BKP_OPT" in
            1) create_full_backup ;;
            2) restore_full_backup ;;
            3)
                echo -e "\n  ${C_CYAN}--- domains.json ---${RST}"
                cat "$DOMAINS_FILE"
                echo -e "\n  ${C_CYAN}--- nodes.json ---${RST}"
                cat "$NODES_FILE"
                read -rp "$(echo -e "\n  ${C_PURPLE}Press [ENTER] to continue...${RST}")"
                ;;
            0) break ;;
            *) ;;
        esac
    done
}

# ==============================================================================
# MAIN DASHBOARD
# ==============================================================================

install_base_tools
init_db

while true; do
    ui_banner
    local active_nodes_count active_domains_count
    active_nodes_count=$(jq '. | length' "$NODES_FILE" 2>/dev/null || echo 0)
    active_domains_count=$(jq '. | length' "$DOMAINS_FILE" 2>/dev/null || echo 0)

    echo -e "  ${DIM}System Status:${RST} ${C_GREEN}Active${RST}  │  ${DIM}Nodes Registered:${RST} ${BOLD}$active_nodes_count${RST}  │  ${DIM}Domains Loaded:${RST} ${BOLD}$active_domains_count${RST}\n"
    echo -e "  ${BOLD}${C_CYAN}[1] 🚀 Node Management Center${RST}     ${C_GRAY}Deploy, 1-Click Migrate, Inbounds, Xray${RST}"
    echo -e "  ${BOLD}${C_CYAN}[2] 🌐 Domains & SSL Manager${RST}      ${C_GRAY}Certbot, Wildcards, Multi-SSL Sync${RST}"
    echo -e "  ${BOLD}${C_CYAN}[3] ⚡ Cloudflare DNS Center${RST}      ${C_GRAY}Clean IPs Table, Presets Templates${RST}"
    echo -e "  ${BOLD}${C_CYAN}[4] 💾 Backup & Restore Center${RST}    ${C_GRAY}1-Click Download Link & Recovery${RST}"
    echo -e "  ${BOLD}${C_CYAN}[5] 📋 Diagnostics & Log Trace${RST}    ${C_GRAY}View Live Operations History${RST}"
    echo -e "  ${BOLD}${C_GRAY}[0] 🚪 Exit${RST}"
    echo -e "\n${C_CYAN}────────────────────────────────────────────────────────────────────────${RST}"
    read -rp "$(echo -e "  ${C_PURPLE}▶ Select Module [0-5]: ${RST}")" MAIN_CHOICE

    case "$MAIN_CHOICE" in
        1) node_management_menu ;;
        2) domain_management_menu ;;
        3) cloudflare_dns_center_menu ;;
        4) backup_restore_menu ;;
        5) [ -f "$LOG_FILE" ] && tail -n 50 "$LOG_FILE" || echo "No logs found." ; read -rp "$(echo -e "\n  ${C_PURPLE}Press [ENTER] to return...${RST}")" ;;
        0) echo -e "\n  ${C_GREEN}Session closed successfully. Goodbye!${RST}\n"; exit 0 ;;
        *) ;;
    esac
done
