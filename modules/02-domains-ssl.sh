#!/bin/bash
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
