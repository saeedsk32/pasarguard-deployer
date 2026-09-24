#!/bin/bash

CLR_RESET="\e[0m"
CLR_BOLD="\e[1m"
CLR_CYAN="\e[36m"
CLR_GREEN="\e[32m"
CLR_YELLOW="\e[33m"
CLR_BLUE="\e[34m"
CLR_MAGENTA="\e[35m"
CLR_RED="\e[31m"
CLR_GRAY="\e[90m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="$SCRIPT_DIR/domains.json"
NODES_FILE="$SCRIPT_DIR/nodes.json"
LOG_FILE="$SCRIPT_DIR/deployer.log"
STANDARD_SSL_BASE="/etc/ssl/pasarguard"

touch "$LOG_FILE"

log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
    echo -e "${CLR_BLUE}[*] $1${CLR_RESET}"
    echo "$msg" >> "$LOG_FILE"
}

log_success() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1"
    echo -e "${CLR_GREEN}[✓] $1${CLR_RESET}"
    echo "$msg" >> "$LOG_FILE"
}

log_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1"
    echo -e "${CLR_YELLOW}[!] $1${CLR_RESET}"
    echo "$msg" >> "$LOG_FILE"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    echo -e "${CLR_RED}[x] $1${CLR_RESET}"
    echo "$msg" >> "$LOG_FILE"
}

install_base_tools() {
    local need_install=false
    for tool in jq sshpass curl certbot; do
        if ! command -v "$tool" &> /dev/null; then
            need_install=true
            break
        fi
    done

    if ! dpkg -s python3-certbot-dns-cloudflare &> /dev/null; then
        need_install=true
    fi

    if [ "$need_install" = true ]; then
        log_info "Installing missing dependencies (Certbot Cloudflare plugin, jq, sshpass)..."
        sudo apt-get update -qq > /dev/null 2>&1
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq sshpass curl certbot python3-certbot-dns-cloudflare > /dev/null 2>&1
        log_success "Prerequisites installed successfully."
    fi
}

install_base_tools

[ ! -f "$DOMAINS_FILE" ] && echo '[]' > "$DOMAINS_FILE"
[ ! -f "$NODES_FILE" ] && echo '[]' > "$NODES_FILE"

sync_cert_file_remote() {
    local src_file="$1"
    local dest_file="$2"
    local ip="$3"
    local port="$4"
    local user="$5"

    sshpass -e ssh -o StrictHostKeyChecking=no -p "$port" "${user}@${ip}" "cat > '$dest_file'" < "$src_file"
}

copy_cert_to_local_master() {
    local domain="$1"
    local src_cert="$2"
    local src_key="$3"
    local target_dir="${STANDARD_SSL_BASE}/${domain}"

    sudo mkdir -p "$target_dir"
    if [ -f "$src_cert" ] && [ -f "$src_key" ]; then
        sudo cp -L "$src_cert" "${target_dir}/fullchain.pem"
        sudo cp -L "$src_key" "${target_dir}/privkey.pem"
        sudo chmod 644 "${target_dir}/fullchain.pem"
        sudo chmod 600 "${target_dir}/privkey.pem"
        log_success "Master SSL synced to: ${target_dir}/"
        return 0
    else
        log_error "Source SSL files for $domain not found."
        return 1
    fi
}

issue_wildcard_ssl() {
    clear
    echo -e "${CLR_CYAN}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}|          ISSUE WILDCARD SSL (Let's Encrypt / DNS)         |${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
    echo -e "${CLR_GRAY}Issues certificate for: domain.com & *.domain.com${CLR_RESET}\n"

    read -p "Domain Name (e.g. example.com): " ISSUE_DOMAIN
    [ -z "$ISSUE_DOMAIN" ] && { log_error "Domain cannot be empty."; read -p "Press [Enter]..."; return; }

    local existing_token=$(jq -r ".[] | select(.domain==\"$ISSUE_DOMAIN\") | .cf_token // empty" "$DOMAINS_FILE" 2>/dev/null)
    local existing_zone=$(jq -r ".[] | select(.domain==\"$ISSUE_DOMAIN\") | .zone_id // empty" "$DOMAINS_FILE" 2>/dev/null)

    read -p "Cloudflare API Token [$existing_token]: " INPUT_CF_TOKEN
    CF_TOKEN=${INPUT_CF_TOKEN:-$existing_token}

    read -p "Cloudflare Zone ID [$existing_zone]: " INPUT_CF_ZONE
    CF_ZONE=${INPUT_CF_ZONE:-$existing_zone}

    read -p "Contact Email: " CERT_EMAIL
    CERT_EMAIL=${CERT_EMAIL:-"admin@$ISSUE_DOMAIN"}

    if [ -z "$CF_TOKEN" ]; then
        log_error "Cloudflare API Token is required to complete DNS challenge!"
        read -p "Press [Enter] to return..."
        return
    fi

    local cf_cred_dir="/etc/letsencrypt"
    local cf_cred_file="${cf_cred_dir}/cloudflare_${ISSUE_DOMAIN}.ini"
    sudo mkdir -p "$cf_cred_dir"
    
    echo "dns_cloudflare_api_token = $CF_TOKEN" | sudo tee "$cf_cred_file" > /dev/null
    sudo chmod 600 "$cf_cred_file"

    log_info "Requesting Wildcard SSL via Cloudflare DNS challenge..."

    sudo certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$cf_cred_file" \
        --dns-cloudflare-propagation-seconds 20 \
        -d "$ISSUE_DOMAIN" \
        -d "*.$ISSUE_DOMAIN" \
        --agree-tos \
        --non-interactive \
        --email "$CERT_EMAIL"

    local cert_target="/etc/letsencrypt/live/$ISSUE_DOMAIN/fullchain.pem"
    local key_target="/etc/letsencrypt/live/$ISSUE_DOMAIN/privkey.pem"

    if [ -f "$cert_target" ] && [ -f "$key_target" ]; then
        log_success "Wildcard Certificate successfully generated!"

        copy_cert_to_local_master "$ISSUE_DOMAIN" "$cert_target" "$key_target"

        local new_entry=$(jq -n \
            --arg dom "$ISSUE_DOMAIN" \
            --arg tok "$CF_TOKEN" \
            --arg zone "$CF_ZONE" \
            --arg cert "$cert_target" \
            --arg key "$key_target" \
            '{domain: $dom, cf_token: $tok, zone_id: $zone, cert_path: $cert, key_path: $key}')

        jq "del(.[] | select(.domain == \"$ISSUE_DOMAIN\"))" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp"
        jq ". += [$new_entry]" "$DOMAINS_FILE.tmp" > "$DOMAINS_FILE" && rm -f "$DOMAINS_FILE.tmp"

        log_success "Domain profile saved in database."
        echo -e "\n${CLR_GREEN}Master Certificate Paths:${CLR_RESET}"
        echo -e "  - Fullchain: ${CLR_YELLOW}${STANDARD_SSL_BASE}/${ISSUE_DOMAIN}/fullchain.pem${CLR_RESET}"
        echo -e "  - Privkey:   ${CLR_YELLOW}${STANDARD_SSL_BASE}/${ISSUE_DOMAIN}/privkey.pem${CLR_RESET}"
    else
        log_error "Certificate issue failed. Please check Cloudflare API permissions."
    fi

    read -p "Press [Enter] to continue..."
}

sync_master_local_menu() {
    clear
    echo -e "${CLR_BLUE}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
    echo -e "${CLR_BLUE}${CLR_BOLD}|          SYNC CERTIFICATES TO LOCAL MASTER SERVER         |${CLR_RESET}"
    echo -e "${CLR_BLUE}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
    local count=$(jq '. | length' "$DOMAINS_FILE")
    
    if [ "$count" -eq 0 ]; then
        log_error "No domain profiles found. Please add or issue a domain first."
        read -p "Press [Enter] to return..."
        return
    fi

    for ((i=0; i<count; i++)); do
        echo -e " ${CLR_CYAN}$((i+1)))${CLR_RESET} $(jq -r ".[$i].domain" "$DOMAINS_FILE")"
    done
    echo -e " ${CLR_YELLOW}A)${CLR_RESET} Sync ALL domains to Master"
    echo -e "${CLR_BLUE}-------------------------------------------------------------${CLR_RESET}"
    read -p "Select domain [1-$count or A]: " SYNC_CHOICE

    local target_indices=()
    if [[ "$SYNC_CHOICE" =~ ^[Aa]$ ]]; then
        for ((i=0; i<count; i++)); do target_indices+=("$i"); done
    elif [[ "$SYNC_CHOICE" =~ ^[0-9]+$ ]] && [ "$SYNC_CHOICE" -ge 1 ] && [ "$SYNC_CHOICE" -le "$count" ]; then
        target_indices+=("$((SYNC_CHOICE-1))")
    else
        log_error "Invalid selection."
        read -p "Press [Enter]..."
        return
    fi

    for idx in "${target_indices[@]}"; do
        local dom=$(jq -r ".[$idx].domain" "$DOMAINS_FILE")
        local cert=$(jq -r ".[$idx].cert_path" "$DOMAINS_FILE")
        local key=$(jq -r ".[$idx].key_path" "$DOMAINS_FILE")
        copy_cert_to_local_master "$dom" "$cert" "$key"
    done

    echo -e "\n${CLR_GREEN}[✓] All selected certificates are now ready on Master server under:${CLR_RESET}"
    echo -e "${CLR_YELLOW}${STANDARD_SSL_BASE}/<domain>/${CLR_RESET}"
    read -p "Press [Enter] to return..."
}

add_or_update_dns_record() {
    local token="$1"
    local zone="$2"
    local full_domain="$3"
    local ip="$4"

    log_info "Cloudflare DNS: $full_domain -> $ip"

    local search_res=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records?name=${full_domain}&type=A" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json")

    local record_id=$(echo "$search_res" | jq -r '.result[0].id // empty')

    if [ -n "$record_id" ]; then
        log_info "Existing DNS record found (ID: $record_id). Updating..."
        local update_res=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records/${record_id}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${full_domain}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}")
        
        [ "$(echo "$update_res" | jq -r '.success')" = "true" ] && log_success "DNS updated to $ip." || log_error "DNS update failed."
    else
        log_info "No DNS record found. Creating new A-record..."
        local create_res=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${full_domain}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}")
        
        [ "$(echo "$create_res" | jq -r '.success')" = "true" ] && log_success "DNS created successfully." || log_error "DNS creation failed."
    fi
}

# --- بخش مدیریت کامل پروفایل‌ها (افزودن، ویرایش، حذف) ---
manage_domains() {
    while true; do
        clear
        echo -e "${CLR_MAGENTA}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
        echo -e "${CLR_MAGENTA}${CLR_BOLD}|                 DOMAIN PROFILES MANAGER                   |${CLR_RESET}"
        echo -e "${CLR_MAGENTA}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
        local count=$(jq '. | length' "$DOMAINS_FILE")
        
        if [ "$count" -eq 0 ]; then
            echo -e "${CLR_YELLOW}No domain profiles registered yet.${CLR_RESET}"
        else
            for ((i=0; i<count; i++)); do
                local name=$(jq -r ".[$i].domain" "$DOMAINS_FILE")
                local zone=$(jq -r ".[$i].zone_id" "$DOMAINS_FILE")
                echo -e " ${CLR_CYAN}$((i+1)))${CLR_RESET} Domain: ${CLR_BOLD}$name${CLR_RESET} ${CLR_GRAY}| Zone ID: $zone${CLR_RESET}"
            done
        fi
        echo -e "${CLR_MAGENTA}-------------------------------------------------------------${CLR_RESET}"
        echo -e " ${CLR_GREEN}1)${CLR_RESET} Add Domain Profile Manually"
        echo -e " ${CLR_YELLOW}2)${CLR_RESET} Edit an Existing Domain Profile"
        echo -e " ${CLR_RED}3)${CLR_RESET} Delete a Domain Profile"
        echo -e " ${CLR_GRAY}4)${CLR_RESET} Back to Main Menu"
        echo -e "${CLR_MAGENTA}-------------------------------------------------------------${CLR_RESET}"
        read -p "Select option [1-4]: " D_OPT

        case $D_OPT in
            1)
                echo -e "\n${CLR_BOLD}--- Add New Profile ---${CLR_RESET}"
                read -p "Domain Name (e.g. site.com): " D_NAME
                [ -z "$D_NAME" ] && { log_error "Domain name is required."; sleep 1; continue; }
                read -p "Cloudflare API Token: " D_TOKEN
                read -p "Cloudflare Zone ID: " D_ZONE
                read -p "Cert Path [/etc/letsencrypt/live/$D_NAME/fullchain.pem]: " D_CERT
                D_CERT=${D_CERT:-"/etc/letsencrypt/live/$D_NAME/fullchain.pem"}
                read -p "Key Path [/etc/letsencrypt/live/$D_NAME/privkey.pem]: " D_KEY
                D_KEY=${D_KEY:-"/etc/letsencrypt/live/$D_NAME/privkey.pem"}

                local new_entry=$(jq -n \
                    --arg dom "$D_NAME" \
                    --arg tok "$D_TOKEN" \
                    --arg zone "$D_ZONE" \
                    --arg cert "$D_CERT" \
                    --arg key "$D_KEY" \
                    '{domain: $dom, cf_token: $tok, zone_id: $zone, cert_path: $cert, key_path: $key}')
                
                jq ". += [$new_entry]" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" && mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
                copy_cert_to_local_master "$D_NAME" "$D_CERT" "$D_KEY"
                log_success "Domain profile registered."
                sleep 1
                ;;
            2)
                if [ "$count" -eq 0 ]; then
                    log_warn "No profiles available to edit."
                    sleep 1
                    continue
                fi
                echo ""
                read -p "Enter profile number to edit [1-$count]: " EDIT_INDEX
                if [[ "$EDIT_INDEX" =~ ^[0-9]+$ ]] && [ "$EDIT_INDEX" -ge 1 ] && [ "$EDIT_INDEX" -le "$count" ]; then
                    local idx=$((EDIT_INDEX-1))
                    local cur_dom=$(jq -r ".[$idx].domain" "$DOMAINS_FILE")
                    local cur_tok=$(jq -r ".[$idx].cf_token" "$DOMAINS_FILE")
                    local cur_zone=$(jq -r ".[$idx].zone_id" "$DOMAINS_FILE")
                    local cur_cert=$(jq -r ".[$idx].cert_path" "$DOMAINS_FILE")
                    local cur_key=$(jq -r ".[$idx].key_path" "$DOMAINS_FILE")

                    echo -e "\n${CLR_GRAY}--- Press [Enter] to keep current value ---${CLR_RESET}"
                    read -p "Domain Name [$cur_dom]: " NEW_DOM
                    NEW_DOM=${NEW_DOM:-$cur_dom}

                    read -p "Cloudflare API Token [${cur_tok:0:4}...]: " NEW_TOK
                    NEW_TOK=${NEW_TOK:-$cur_tok}

                    read -p "Cloudflare Zone ID [$cur_zone]: " NEW_ZONE
                    NEW_ZONE=${NEW_ZONE:-$cur_zone}

                    read -p "Cert Path [$cur_cert]: " NEW_CERT
                    NEW_CERT=${NEW_CERT:-$cur_cert}

                    read -p "Key Path [$cur_key]: " NEW_KEY
                    NEW_KEY=${NEW_KEY:-$cur_key}

                    local updated_entry=$(jq -n \
                        --arg dom "$NEW_DOM" \
                        --arg tok "$NEW_TOK" \
                        --arg zone "$NEW_ZONE" \
                        --arg cert "$NEW_CERT" \
                        --arg key "$NEW_KEY" \
                        '{domain: $dom, cf_token: $tok, zone_id: $zone, cert_path: $cert, key_path: $key}')

                    jq ".[$idx] = $updated_entry" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" && mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
                    copy_cert_to_local_master "$NEW_DOM" "$NEW_CERT" "$NEW_KEY"
                    log_success "Domain profile updated successfully!"
                else
                    log_error "Invalid profile number."
                fi
                sleep 1
                ;;
            3)
                read -p "Enter number to delete: " DEL_INDEX
                if [[ "$DEL_INDEX" =~ ^[0-9]+$ ]] && [ "$DEL_INDEX" -ge 1 ] && [ "$DEL_INDEX" -le "$count" ]; then
                    local idx=$((DEL_INDEX-1))
                    local d_target=$(jq -r ".[$idx].domain" "$DOMAINS_FILE")
                    jq "del(.[$idx])" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" && mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
                    log_warn "Profile $d_target removed."
                else
                    log_error "Invalid number."
                fi
                sleep 1
                ;;
            4)
                break
                ;;
        esac
    done
}

node_actions_menu() {
    local n_idx="$1"
    local n_ip=$(jq -r ".[$n_idx].ip" "$NODES_FILE")
    local n_port=$(jq -r ".[$n_idx].port" "$NODES_FILE")
    local n_user=$(jq -r ".[$n_idx].user" "$NODES_FILE")
    local n_pass=$(jq -r ".[$n_idx].pass" "$NODES_FILE")
    local n_sub=$(jq -r ".[$n_idx].subdomain" "$NODES_FILE")
    local n_host=$(jq -r ".[$n_idx].hostname // \"(None)\"" "$NODES_FILE")
    local n_sport=$(jq -r ".[$n_idx].service_port // 62050" "$NODES_FILE")
    local n_aport=$(jq -r ".[$n_idx].api_port // 62051" "$NODES_FILE")

    while true; do
        clear
        echo -e "${CLR_CYAN}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
        echo -e "${CLR_CYAN}${CLR_BOLD}|                    NODE CONTROL CENTER                    |${CLR_RESET}"
        echo -e "${CLR_CYAN}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
        echo -e " ${CLR_BOLD}Hostname:${CLR_RESET}     ${CLR_GREEN}$n_host${CLR_RESET}"
        echo -e " ${CLR_BOLD}IP Address:${CLR_RESET}   ${CLR_YELLOW}$n_ip${CLR_RESET} (SSH Port: $n_port)"
        echo -e " ${CLR_BOLD}Subdomain:${CLR_RESET}    ${CLR_CYAN}$n_sub${CLR_RESET}"
        echo -e " ${CLR_BOLD}Service Port:${CLR_RESET} ${CLR_MAGENTA}$n_sport${CLR_RESET} | ${CLR_BOLD}API Port:${CLR_RESET} ${CLR_MAGENTA}$n_aport${CLR_RESET}"
        echo -e " ${CLR_BOLD}Exact SSL Paths on this Node:${CLR_RESET}"
        for d in $(jq -r ".[$n_idx].domains[]" "$NODES_FILE"); do
            echo -e "   * Cert: ${CLR_YELLOW}${STANDARD_SSL_BASE}/${d}/fullchain.pem${CLR_RESET}"
            echo -e "   * Key:  ${CLR_YELLOW}${STANDARD_SSL_BASE}/${d}/privkey.pem${CLR_RESET}"
        done
        echo -e "${CLR_CYAN}-------------------------------------------------------------${CLR_RESET}"
        echo -e " ${CLR_GREEN}1)${CLR_RESET} View SSL Public Certificate Content"
        echo -e " ${CLR_YELLOW}2)${CLR_RESET} Update PasarGuard Node Software & Xray Core"
        echo -e " ${CLR_BLUE}3)${CLR_RESET} Restart Node Docker Service"
        echo -e " ${CLR_RED}4)${CLR_RESET} Delete Node from Database"
        echo -e " ${CLR_GRAY}5)${CLR_RESET} Back"
        echo -e "${CLR_CYAN}-------------------------------------------------------------${CLR_RESET}"
        read -p "Select action [1-5]: " ACT_OPT

        export SSHPASS="$n_pass"

        case $ACT_OPT in
            1)
                local first_dom=$(jq -r ".[$n_idx].domains[0]" "$NODES_FILE")
                echo -e "\n${CLR_GRAY}--- BEGIN CERTIFICATE FILE CONTENT (${first_dom}) ---${CLR_RESET}"
                sshpass -e ssh -o StrictHostKeyChecking=no -p "$n_port" "${n_user}@${n_ip}" \
                    "cat ${STANDARD_SSL_BASE}/${first_dom}/fullchain.pem 2>/dev/null"
                echo -e "${CLR_GRAY}--- END CERTIFICATE FILE CONTENT ---${CLR_RESET}\n"
                read -p "Press [Enter] to continue..."
                ;;
            2)
                log_info "Updating PasarGuard Node on $n_ip..."
                sshpass -e ssh -o StrictHostKeyChecking=no -p "$n_port" "${n_user}@${n_ip}" bash -s << 'REMOTE_EOF'
                    curl -fsSL https://raw.githubusercontent.com/PasarGuard/scripts/main/pg-node.sh -o /tmp/pg-node.sh
                    sudo bash /tmp/pg-node.sh update --non-interactive || sudo bash /tmp/pg-node.sh install --non-interactive
REMOTE_EOF
                log_success "Node update command executed."
                read -p "Press [Enter] to continue..."
                ;;
            3)
                log_info "Restarting docker containers on $n_ip..."
                sshpass -e ssh -o StrictHostKeyChecking=no -p "$n_port" "${n_user}@${n_ip}" \
                    "command -v docker >/dev/null && docker restart \$(docker ps -q --filter ancestor=pasarguard) 2>/dev/null || true"
                log_success "Containers restarted."
                read -p "Press [Enter] to continue..."
                ;;
            4)
                read -p "Are you sure you want to delete this node? [y/N]: " CONFIRM_DEL
                if [[ "$CONFIRM_DEL" =~ ^[Yy]$ ]]; then
                    jq "del(.[$n_idx])" "$NODES_FILE" > "$NODES_FILE.tmp" && mv "$NODES_FILE.tmp" "$NODES_FILE"
                    log_warn "Node removed from database."
                    unset SSHPASS
                    sleep 1
                    break
                fi
                ;;
            5)
                unset SSHPASS
                break
                ;;
        esac
        unset SSHPASS
    done
}

manage_nodes() {
    while true; do
        clear
        echo -e "${CLR_CYAN}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
        echo -e "${CLR_CYAN}${CLR_BOLD}|                    SAVED NODES INVENTORY                  |${CLR_RESET}"
        echo -e "${CLR_CYAN}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
        local node_count=$(jq '. | length' "$NODES_FILE")

        if [ "$node_count" -eq 0 ]; then
            echo -e "${CLR_YELLOW}No deployed nodes registered yet.${CLR_RESET}"
            read -p "Press [Enter] to return..."
            break
        else
            for ((n=0; n<node_count; n++)); do
                local nhost=$(jq -r ".[$n].hostname // \"Node-$((n+1))\"" "$NODES_FILE")
                local nip=$(jq -r ".[$n].ip" "$NODES_FILE")
                local nsub=$(jq -r ".[$n].subdomain" "$NODES_FILE")
                echo -e " ${CLR_GREEN}$((n+1)))${CLR_RESET} [${CLR_BOLD}$nhost${CLR_RESET}] ${CLR_YELLOW}$nip${CLR_RESET} | Sub: ${CLR_CYAN}$nsub${CLR_RESET}"
            done
            echo -e "${CLR_CYAN}-------------------------------------------------------------${CLR_RESET}"
            echo -e "Select node number to control or '${CLR_RED}B${CLR_RESET}' to return."
            read -p "Choice: " N_CHOICE

            if [[ "$N_CHOICE" =~ ^[Bb]$ ]]; then
                break
            elif [[ "$N_CHOICE" =~ ^[0-9]+$ ]] && [ "$N_CHOICE" -ge 1 ] && [ "$N_CHOICE" -le "$node_count" ]; then
                node_actions_menu "$((N_CHOICE-1))"
            fi
        fi
    done
}

view_logs() {
    clear
    echo -e "${CLR_BLUE}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
    echo -e "${CLR_BLUE}${CLR_BOLD}|                  DEPLOYMENT ACTIVITY LOGS                |${CLR_RESET}"
    echo -e "${CLR_BLUE}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
    [ -f "$LOG_FILE" ] && tail -n 50 "$LOG_FILE" || echo "No logs found."
    echo -e "${CLR_BLUE}-------------------------------------------------------------${CLR_RESET}"
    read -p "Press [Enter] to return..."
}

renew_and_sync_ssl() {
    clear
    echo -e "${CLR_YELLOW}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
    echo -e "${CLR_YELLOW}${CLR_BOLD}|                RENEW & SYNC CERTIFICATES                  |${CLR_RESET}"
    echo -e "${CLR_YELLOW}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
    echo -e " ${CLR_GREEN}1)${CLR_RESET} Renew certificates locally on master using Certbot"
    echo -e " ${CLR_CYAN}2)${CLR_RESET} Push current certificates to saved nodes"
    echo -e " ${CLR_MAGENTA}3)${CLR_RESET} Full Auto (Renew locally + Sync Master + Push to Nodes)"
    echo -e " ${CLR_GRAY}4)${CLR_RESET} Back"
    echo -e "${CLR_YELLOW}-------------------------------------------------------------${CLR_RESET}"
    read -p "Select option [1-4]: " R_OPT

    case $R_OPT in
        1|3)
            log_info "Running Certbot renew..."
            sudo certbot renew
            
            local count=$(jq '. | length' "$DOMAINS_FILE")
            for ((i=0; i<count; i++)); do
                local d_name=$(jq -r ".[$i].domain" "$DOMAINS_FILE")
                local c_path=$(jq -r ".[$i].cert_path" "$DOMAINS_FILE")
                local k_path=$(jq -r ".[$i].key_path" "$DOMAINS_FILE")
                copy_cert_to_local_master "$d_name" "$c_path" "$k_path"
            done
            [ "$R_OPT" == "1" ] && { read -p "Press [Enter]..."; return; }
            ;;
    esac

    case $R_OPT in
        2|3)
            local node_count=$(jq '. | length' "$NODES_FILE")
            [ "$node_count" -eq 0 ] && { log_error "No saved nodes found!"; read -p "Press [Enter]..."; return; }

            for ((n=0; n<node_count; n++)); do
                local n_host=$(jq -r ".[$n].hostname" "$NODES_FILE")
                local n_ip=$(jq -r ".[$n].ip" "$NODES_FILE")
                local n_port=$(jq -r ".[$n].port" "$NODES_FILE")
                local n_user=$(jq -r ".[$n].user" "$NODES_FILE")
                local n_pass=$(jq -r ".[$n].pass" "$NODES_FILE")
                
                export SSHPASS="$n_pass"
                log_info "Syncing SSL certificates with [$n_host] ($n_ip)..."

                local assigned_domains=($(jq -r ".[$n].domains[]" "$NODES_FILE"))
                for d_name in "${assigned_domains[@]}"; do
                    local c_path=$(jq -r ".[] | select(.domain==\"$d_name\") | .cert_path" "$DOMAINS_FILE")
                    local k_path=$(jq -r ".[] | select(.domain==\"$d_name\") | .key_path" "$DOMAINS_FILE")
                    local dest_dir="${STANDARD_SSL_BASE}/${d_name}"

                    if [ -f "$c_path" ] && [ -f "$k_path" ]; then
                        sshpass -e ssh -o StrictHostKeyChecking=no -p "$n_port" "${n_user}@${n_ip}" "mkdir -p ${dest_dir}"
                        sync_cert_file_remote "$c_path" "${dest_dir}/fullchain.pem" "$n_ip" "$n_port" "$n_user"
                        sync_cert_file_remote "$k_path" "${dest_dir}/privkey.pem" "$n_ip" "$n_port" "$n_user"
                    fi
                done

                sshpass -e ssh -o StrictHostKeyChecking=no -p "$n_port" "${n_user}@${n_ip}" \
                    "command -v docker >/dev/null && docker restart \$(docker ps -q --filter ancestor=pasarguard) 2>/dev/null || true"
                unset SSHPASS
            done
            log_success "All nodes synchronized."
            read -p "Press [Enter] to return..."
            ;;
    esac
}

deploy_node() {
    local count=$(jq '. | length' "$DOMAINS_FILE")
    [ "$count" -eq 0 ] && { log_error "No domain profiles found! Please issue or add a domain profile first."; read -p "Press [Enter]..."; return; }

    clear
    echo -e "${CLR_GREEN}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
    echo -e "${CLR_GREEN}${CLR_BOLD}|               DEPLOY NEW NODE - SELECT DOMAINS            |${CLR_RESET}"
    echo -e "${CLR_GREEN}${CLR_BOLD}+-----------------------------------------------------------+${CLR_RESET}"
    for ((i=0; i<count; i++)); do
        echo -e " ${CLR_CYAN}$((i+1)))${CLR_RESET} $(jq -r ".[$i].domain" "$DOMAINS_FILE")"
    done
    echo -e " ${CLR_YELLOW}A)${CLR_RESET} Select ALL domains"
    echo -e "${CLR_GREEN}-------------------------------------------------------------${CLR_RESET}"
    read -p "Select domain(s) [e.g. 1 or 1,2 or A]: " DOM_CHOICE

    local selected_indices=()
    local selected_domain_names=()

    if [[ "$DOM_CHOICE" =~ ^[Aa]$ ]]; then
        for ((i=0; i<count; i++)); do 
            selected_indices+=("$i")
            selected_domain_names+=($(jq -r ".[$i].domain" "$DOMAINS_FILE"))
        done
    else
        IFS=',' read -ra PARTS <<< "$DOM_CHOICE"
        for p in "${PARTS[@]}"; do
            p=$(echo "$p" | tr -d ' ')
            if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le "$count" ]; then
                selected_indices+=("$((p-1))")
                selected_domain_names+=($(jq -r ".[$((p-1))].domain" "$DOMAINS_FILE"))
            fi
        done
    fi

    [ ${#selected_indices[@]} -eq 0 ] && { log_error "No valid domains selected."; read -p "Press [Enter]..."; return; }

    echo -e "\n${CLR_BOLD}--- Server Access Details ---${CLR_RESET}"
    read -p "Node Hostname label (e.g. de-node-01): " NODE_HOSTNAME
    NODE_HOSTNAME=${NODE_HOSTNAME:-"pg-node-$(date +%s | tail -c 4)"}
    read -p "Node IP Address: " NODE_IP
    read -p "SSH Port [Default 22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    read -p "SSH Username [Default root]: " SSH_USER
    SSH_USER=${SSH_USER:-root}
    read -s -p "SSH Password: " SSH_PASS
    echo ""
    read -p "Node Subdomain prefix ONLY (e.g. de1): " SUBDOMAIN

    echo -e "\n${CLR_BOLD}--- Port Configuration ---${CLR_RESET}"
    read -p "Node Service Port [Default 62050]: " NODE_SERVICE_PORT
    NODE_SERVICE_PORT=${NODE_SERVICE_PORT:-62050}
    read -p "Node API Port [Default 62051]: " NODE_API_PORT
    NODE_API_PORT=${NODE_API_PORT:-62051}

    read -p "Install PasarGuard Node binary automatically? [Y/n]: " AUTO_INSTALL
    AUTO_INSTALL=${AUTO_INSTALL:-Y}

    export SSHPASS="$SSH_PASS"
    log_info "Deploying to $NODE_HOSTNAME ($NODE_IP)..."

    sshpass -e ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" "${SSH_USER}@${NODE_IP}" "hostnamectl set-hostname '$NODE_HOSTNAME' || echo '$NODE_HOSTNAME' > /etc/hostname"

    sshpass -e ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" "${SSH_USER}@${NODE_IP}" bash -s << 'REMOTE_BBR'
        grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
REMOTE_BBR

    sshpass -e ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" "${SSH_USER}@${NODE_IP}" \
        "DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >/dev/null 2>&1"

    for idx in "${selected_indices[@]}"; do
        local dom=$(jq -r ".[$idx].domain" "$DOMAINS_FILE")
        local tok=$(jq -r ".[$idx].cf_token" "$DOMAINS_FILE")
        local zone=$(jq -r ".[$idx].zone_id" "$DOMAINS_FILE")
        local cert=$(jq -r ".[$idx].cert_path" "$DOMAINS_FILE")
        local key=$(jq -r ".[$idx].key_path" "$DOMAINS_FILE")
        local dest_dir="${STANDARD_SSL_BASE}/${dom}"

        [ -n "$tok" ] && [ -n "$zone" ] && add_or_update_dns_record "$tok" "$zone" "${SUBDOMAIN}.${dom}" "$NODE_IP"

        if [ -f "$cert" ] && [ -f "$key" ]; then
            sshpass -e ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" "${SSH_USER}@${NODE_IP}" "mkdir -p ${dest_dir}"
            sync_cert_file_remote "$cert" "${dest_dir}/fullchain.pem" "$NODE_IP" "$SSH_PORT" "$SSH_USER"
            sync_cert_file_remote "$key" "${dest_dir}/privkey.pem" "$NODE_IP" "$SSH_PORT" "$SSH_USER"
        fi
    done

    sshpass -e ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" "${SSH_USER}@${NODE_IP}" \
        "command -v ufw >/dev/null && (sudo ufw allow ${NODE_SERVICE_PORT}/tcp; sudo ufw allow ${NODE_API_PORT}/tcp) || true"

    if [[ "$AUTO_INSTALL" =~ ^[Yy]$ ]]; then
        sshpass -e ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" "${SSH_USER}@${NODE_IP}" \
            "curl -fsSL https://raw.githubusercontent.com/PasarGuard/scripts/main/pg-node.sh -o /tmp/pg-node.sh && sudo bash /tmp/pg-node.sh install --non-interactive || true"
    fi

    local dom_json=$(printf '%s\n' "${selected_domain_names[@]}" | jq -R . | jq -s .)
    local node_entry=$(jq -n \
        --arg host "$NODE_HOSTNAME" \
        --arg ip "$NODE_IP" \
        --arg port "$SSH_PORT" \
        --arg user "$SSH_USER" \
        --arg pass "$SSH_PASS" \
        --arg sub "$SUBDOMAIN" \
        --arg sport "$NODE_SERVICE_PORT" \
        --arg aport "$NODE_API_PORT" \
        --argjson doms "$dom_json" \
        '{hostname: $host, ip: $ip, port: $port, user: $user, pass: $pass, subdomain: $sub, service_port: $sport, api_port: $aport, domains: $doms}')

    jq "del(.[] | select(.ip == \"$NODE_IP\"))" "$NODES_FILE" > "$NODES_FILE.tmp"
    jq ". += [$node_entry]" "$NODES_FILE.tmp" > "$NODES_FILE" && rm -f "$NODES_FILE.tmp"

    unset SSHPASS
    log_success "Node [$NODE_HOSTNAME] deployed successfully!"

    echo -e "\n${CLR_GREEN}${CLR_BOLD}============================================================${CLR_RESET}"
    echo -e " ${CLR_BOLD}NODE DEPLOYMENT SUMMARY FOR PASARGUARD PANEL${CLR_RESET}"
    echo -e "${CLR_GREEN}============================================================${CLR_RESET}"
    echo -e "  - Hostname:     ${CLR_CYAN}${NODE_HOSTNAME}${CLR_RESET}"
    for idx in "${selected_indices[@]}"; do
        local dom=$(jq -r ".[$idx].domain" "$DOMAINS_FILE")
        echo -e "  - Address:      ${CLR_YELLOW}${SUBDOMAIN}.${dom}${CLR_RESET}"
        echo -e "    Cert Path:    ${CLR_GREEN}${STANDARD_SSL_BASE}/${dom}/fullchain.pem${CLR_RESET}"
        echo -e "    Key Path:     ${CLR_GREEN}${STANDARD_SSL_BASE}/${dom}/privkey.pem${CLR_RESET}"
    done
    echo -e "  - Service Port: ${CLR_MAGENTA}${NODE_SERVICE_PORT}${CLR_RESET}"
    echo -e "  - API Port:     ${CLR_MAGENTA}${NODE_API_PORT}${CLR_RESET}"
    echo -e "${CLR_GREEN}============================================================${CLR_RESET}"
    read -p "Press [Enter] to return..."
}

while true; do
    clear
    echo -e "${CLR_CYAN}${CLR_BOLD}+--------------------------------------------------------------------+${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}|                PASARGUARD MULTI-NODE AUTO-DEPLOYER                 |${CLR_RESET}"
    echo -e "${CLR_CYAN}${CLR_BOLD}+--------------------------------------------------------------------+${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_GREEN}${CLR_BOLD}[1]${CLR_RESET} ${CLR_BOLD}Deploy New Node${CLR_RESET}"
    echo -e "      ${CLR_GRAY}> Configure remote node & transfer SSL to standard paths${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_CYAN}${CLR_BOLD}[2]${CLR_RESET} ${CLR_BOLD}Issue Wildcard SSL Certificate${CLR_RESET}"
    echo -e "      ${CLR_GRAY}> Let's Encrypt wildcard via Cloudflare & sync to master${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_BLUE}${CLR_BOLD}[3]${CLR_RESET} ${CLR_BOLD}Sync SSL to Local Master Server${CLR_RESET}"
    echo -e "      ${CLR_GRAY}> Deploy certificates to /etc/ssl/pasarguard/<domain> on Master${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_YELLOW}${CLR_BOLD}[4]${CLR_RESET} ${CLR_BOLD}Manage Saved Nodes${CLR_RESET}"
    echo -e "      ${CLR_GRAY}> Inspect SSL, view exact paths, restart & update nodes${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_MAGENTA}${CLR_BOLD}[5]${CLR_RESET} ${CLR_BOLD}Domain Profiles Manager${CLR_RESET}"
    echo -e "      ${CLR_GRAY}> Add, edit, or delete domains, Cloudflare tokens and zone IDs${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_BLUE}${CLR_BOLD}[6]${CLR_RESET} ${CLR_BOLD}Renew & Synchronize SSL${CLR_RESET}"
    echo -e "      ${CLR_GRAY}> Certbot renew & 1-click push to Master + all Nodes${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_GRAY}${CLR_BOLD}[7]${CLR_RESET} ${CLR_BOLD}View Execution Logs${CLR_RESET}"
    echo -e "      ${CLR_GRAY}> Inspect real-time deployment history and reports${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_RED}${CLR_BOLD}[8]${CLR_RESET} ${CLR_BOLD}Exit${CLR_RESET}"
    echo ""
    echo -e "${CLR_CYAN}----------------------------------------------------------------------${CLR_RESET}"
    read -p "Select an option [1-8]: " CHOICE

    case $CHOICE in
        1) deploy_node ;;
        2) issue_wildcard_ssl ;;
        3) sync_master_local_menu ;;
        4) manage_nodes ;;
        5) manage_domains ;;
        6) renew_and_sync_ssl ;;
        7) view_logs ;;
        8) echo -e "${CLR_GREEN}Exiting. Good luck!${CLR_RESET}"; exit 0 ;;
        *) echo -e "${CLR_RED}Invalid option.${CLR_RESET}"; sleep 1 ;;
    esac
done
