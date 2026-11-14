#!/bin/bash
# ==============================================================================
# PasarGuard Domains & SSL Manager Module (v2.11 - Subdomain Creator & DNS Prompt)
# ==============================================================================

inspect_cert_file() {
    local cert_file="$1"
    if [ ! -f "$cert_file" ]; then
        echo "Unknown|No"
        return
    fi
    local sans
    sans=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -n1 | sed 's/DNS://g; s/ //g')
    local is_wild="No"
    [[ "$sans" == *"*"* ]] && is_wild="Yes"
    echo "${sans:-Unknown}|${is_wild}"
}

extract_token_from_certbot_conf() {
    local dom="$1"
    local conf_file="/etc/letsencrypt/renewal/${dom}.conf"
    
    if [ -f "$conf_file" ]; then
        local cred_path
        cred_path=$(grep "dns_cloudflare_credentials" "$conf_file" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
        if [ -n "$cred_path" ] && [ -f "$cred_path" ]; then
            local tok
            tok=$(grep "dns_cloudflare_api_token" "$cred_path" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
            [ -n "$tok" ] && echo "$tok" && return
        fi
    fi

    local dedicated_ini="/root/.secrets/certbot/cf-${dom}.ini"
    if [ -f "$dedicated_ini" ]; then
        local tok
        tok=$(grep "dns_cloudflare_api_token" "$dedicated_ini" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
        [ -n "$tok" ] && echo "$tok" && return
    fi

    local global_ini="/root/.secrets/certbot/cloudflare.ini"
    if [ -f "$global_ini" ]; then
        local tok
        tok=$(grep "dns_cloudflare_api_token" "$global_ini" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
        [ -n "$tok" ] && echo "$tok" && return
    fi

    echo "None"
}

sync_cf_cred_file() {
    local dom="$1" tok="$2"
    [ -z "$tok" ] || [ "$tok" == "None" ] || [ "$tok" == "null" ] && return 1

    mkdir -p /root/.secrets/certbot
    local cred_file="/root/.secrets/certbot/cf-${dom}.ini"
    echo "dns_cloudflare_api_token = $tok" > "$cred_file"
    chmod 600 "$cred_file"

    local renew_conf="/etc/letsencrypt/renewal/${dom}.conf"
    if [ -f "$renew_conf" ]; then
        if grep -q "dns_cloudflare_credentials" "$renew_conf"; then
            sed -i "s|^dns_cloudflare_credentials.*|dns_cloudflare_credentials = $cred_file|g" "$renew_conf"
        fi
    fi
    echo "$cred_file"
}

list_domain_profiles() {
    local count; count=$(get_domains_count)
    if [ "$count" -eq 0 ]; then
        echo -e "  ${C_YELLOW}No domain profiles registered yet.${RST}"
        return 1
    fi
    echo -e "\n  ${BOLD}${C_CYAN}Registered Domain Profiles:${RST}"
    local i=0
    while IFS= read -r row; do
        ((i++))
        local d z t c_type
        d=$(echo "$row" | jq -r '.domain')
        z=$(echo "$row" | jq -r '.zone_id // "None"')
        t=$(echo "$row" | jq -r '.token // "None"')
        c_type=$(echo "$row" | jq -r '.cert_type // "auto"')

        if [ "$t" == "None" ] || [ -z "$t" ] || [ "$t" == "null" ]; then
            local auto_tok
            auto_tok=$(extract_token_from_certbot_conf "$d")
            if [ "$auto_tok" != "None" ]; then
                t="$auto_tok"
                sync_cf_cred_file "$d" "$t" >/dev/null
            fi
        fi

        local cert_path="/etc/letsencrypt/live/$d/cert.pem"
        local info is_wild sans
        info=$(inspect_cert_file "$cert_path")
        sans="${info%|*}"
        is_wild="${info#*|}"

        local badge=""
        if [ "$is_wild" == "Yes" ] || [ "$c_type" == "wildcard" ]; then
            if [ "$t" != "None" ] && [ -n "$t" ] && [ "$t" != "null" ]; then
                badge="${C_GREEN}[Wildcard | CF-API Linked]${RST}"
            else
                badge="${C_YELLOW}[Wildcard | Missing API]${RST}"
            fi
        else
            badge="${C_BLUE}[HTTP-01 / Standard Subdomain]${RST}"
        fi

        echo -e "    ${C_PURPLE}[$i]${RST} ${BOLD}$d${RST} $badge"
        [ "$sans" != "Unknown" ] && echo -e "        ${C_GRAY}Covers: $sans | Zone: $z${RST}"
    done < <(jq -c '.[]' "$DOMAINS_FILE" 2>/dev/null)
    return 0
}

upsert_cloudflare_dns() {
    local zid="$1" tok="$2" name="$3" ip="$4" comment="$5"
    [ "$zid" == "None" ] || [ -z "$zid" ] && return
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

scan_and_import_certificates() {
    ui_sub_banner
    echo -e "  ${BOLD}${C_CYAN}🔍 SCAN & IMPORT SERVER SSL CERTIFICATES${RST}"
    echo -e "  ${C_GRAY}Deep-scanning /etc/letsencrypt/live/ with auto-token detection...${RST}\n"

    if [ ! -d "/etc/letsencrypt/live" ]; then
        echo -e "  ${C_YELLOW}No Let's Encrypt directory found on this server.${RST}"
        read -rp "Press [ENTER] to return..." < /dev/tty
        return
    fi

    local cert_dirs=("/etc/letsencrypt/live/"*)
    if [ ${#cert_dirs[@]} -eq 0 ] || [ ! -e "${cert_dirs[0]}" ]; then
        echo -e "  ${C_YELLOW}No SSL certificates issued yet.${RST}"
        read -rp "Press [ENTER] to return..." < /dev/tty
        return
    fi

    echo -e "  ${BOLD}Detected Certificates on Server:${RST}"
    local idx=0
    declare -a scanned_names
    declare -a scanned_wild

    for c_path in "${cert_dirs[@]}"; do
        [ -d "$c_path" ] || continue
        [ -f "$c_path/cert.pem" ] || continue
        local c_name; c_name=$(basename "$c_path")
        ((idx++))
        scanned_names[$idx]="$c_name"

        local exp_date info sans is_wild
        exp_date=$(openssl x509 -enddate -noout -in "$c_path/cert.pem" 2>/dev/null | cut -d= -f2)
        info=$(inspect_cert_file "$c_path/cert.pem")
        sans="${info%|*}"
        is_wild="${info#*|}"
        scanned_wild[$idx]="$is_wild"

        local type_tag="${C_BLUE}HTTP-01 / Standard${RST}"
        [ "$is_wild" == "Yes" ] && type_tag="${C_YELLOW}Wildcard (*.domain)${RST}"

        echo -e "    ${C_PURPLE}[$idx]${RST} Cert Name : ${BOLD}$c_name${RST}  [$type_tag]"
        echo -e "        Domains   : ${C_GRAY}$sans${RST}"
        echo -e "        Expires   : ${C_GRAY}$exp_date${RST}\n"
    done

    echo -e "------------------------------------------------------------------------"
    read -rp "$(echo -e "  ${C_PURPLE}▶ Enter certificate number to Import (0 to skip): ${RST}")" IMP_IDX < /dev/tty
    if [[ "$IMP_IDX" =~ ^[0-9]+$ ]] && [ "$IMP_IDX" -ge 1 ] && [ "$IMP_IDX" -le "$idx" ]; then
        local sel_dom="${scanned_names[$IMP_IDX]}"
        local sel_wild="${scanned_wild[$IMP_IDX]}"
        local s_tok="None" s_zid="None" c_type="http"

        if [ "$sel_wild" == "Yes" ]; then
            c_type="wildcard"
            s_tok=$(extract_token_from_certbot_conf "$sel_dom")
            if [ "$s_tok" != "None" ]; then
                echo -e "\n  ${C_GREEN}✔ Cloudflare API Token automatically detected from server configs!${RST}"
            else
                echo -e "\n  ${C_YELLOW}⚡ Wildcard Certificate detected for '$sel_dom'.${RST}"
                read -rp "  ▶ Enter Cloudflare API Token (Enter to skip): " s_tok < /dev/tty
                read -rp "  ▶ Enter Cloudflare Zone ID (Enter to skip): " s_zid < /dev/tty
                [ -z "$s_tok" ] && s_tok="None"
                [ -z "$s_zid" ] && s_zid="None"
            fi
            [ "$s_tok" != "None" ] && sync_cf_cred_file "$sel_dom" "$s_tok" >/dev/null
        else
            echo -e "\n  ${C_CYAN}ℹ Standard HTTP-01 Certificate detected for '$sel_dom'.${RST}"
        fi

        local tmp_f; tmp_f=$(mktemp)
        if jq -e --arg dom "$sel_dom" '.[] | select(.domain == $dom)' "$DOMAINS_FILE" >/dev/null 2>&1; then
            jq --arg d "$sel_dom" --arg t "$s_tok" --arg z "$s_zid" --arg ct "$c_type" \
               'map(if .domain == $d then .token = $t | .zone_id = $z | .cert_type = $ct else . end)' \
               "$DOMAINS_FILE" > "$tmp_f" && mv "$tmp_f" "$DOMAINS_FILE"
            log OK "Updated existing profile '$sel_dom'."
        else
            jq --arg d "$sel_dom" --arg t "$s_tok" --arg z "$s_zid" --arg ct "$c_type" \
               '. += [{"domain": $d, "token": $t, "zone_id": $z, "cert_type": $ct}]' \
               "$DOMAINS_FILE" > "$tmp_f" && mv "$tmp_f" "$DOMAINS_FILE"
            log OK "Imported '$sel_dom' into domain profiles."
        fi
    fi
    read -rp "Press [ENTER] to return..." < /dev/tty
}

# New Subdomain Creator & HTTP-01 Issuer with DNS Reminder
create_and_issue_subdomain() {
    ui_sub_banner
    echo -e "  ${BOLD}${C_CYAN}🌐 CREATE & ISSUE SUBDOMAIN SSL (HTTP-01)${RST}"
    echo -e "  ${C_GRAY}Register subdomain profile and issue standard certificate${RST}\n"

    read -rp "  ▶ Enter Subdomain (e.g. panel.beepbox.site): " sub_dom < /dev/tty
    [ -z "$sub_dom" ] && return

    echo -e "\n  ${C_YELLOW}⚠️ IMPORTANT NOTICE / REMINDER:${RST}"
    echo -e "  Before issuing the SSL certificate, you must create a DNS record"
    echo -e "  (A / AAAA or CNAME) pointing ${BOLD}$sub_dom${RST} to this server's IP address"
    echo -e "  in your DNS provider panel (e.g., Cloudflare).\n"

    read -rp "$(echo -e "  ${C_PURPLE}Have you registered the DNS record for '$sub_dom'? [y/N]: ${RST}")" dns_ready < /dev/tty
    [[ "$dns_ready" =~ ^[yY]$ ]] || { echo -e "  ${C_RED}Aborted. Please register the DNS record first.${RST}"; read -rp "Press [ENTER] to return..." < /dev/tty; return; }

    echo -e "\n  ${BOLD}Select Issuance Method:${RST}"
    echo -e "    [1] Standalone HTTP-01 (Binds to port 80, auto-stops Nginx temporarily)"
    echo -e "    [2] Nginx Plugin (Uses existing Nginx server block)"
    echo -e "    [3] Save Profile Only (Issue certificate later)"
    read -rp "$(echo -e "  ${C_PURPLE}▶ Choose Method [1-3]: ${RST}")" iss_mode < /dev/tty

    case "$iss_mode" in
        1)
            systemctl stop nginx 2>/dev/null || true
            certbot certonly --standalone -d "$sub_dom" --agree-tos --register-unsafely-without-email --non-interactive
            systemctl start nginx 2>/dev/null || true
            log OK "Subdomain SSL issued via Standalone for: $sub_dom"
            ;;
        2)
            certbot certonly --nginx -d "$sub_dom" --agree-tos --register-unsafely-without-email --non-interactive
            log OK "Subdomain SSL issued via Nginx for: $sub_dom"
            ;;
        3)
            log OK "Subdomain profile registered without immediate issuance."
            ;;
    esac

    # Add to domains.json if not present
    if ! jq -e --arg dom "$sub_dom" '.[] | select(.domain == $dom)' "$DOMAINS_FILE" >/dev/null 2>&1; then
        local tmp_f; tmp_f=$(mktemp)
        jq --arg d "$sub_dom" '. += [{"domain": $d, "token": "None", "zone_id": "None", "cert_type": "http"}]' "$DOMAINS_FILE" > "$tmp_f" && mv "$tmp_f" "$DOMAINS_FILE"
        log OK "Subdomain '$sub_dom' added to domain profiles."
    fi
    read -rp "Press [ENTER] to return..." < /dev/tty
}

prepare_all_cf_tokens() {
    while IFS= read -r row; do
        local d t info is_wild
        d=$(echo "$row" | jq -r '.domain')
        t=$(echo "$row" | jq -r '.token // "None"')
        
        if [ "$t" == "None" ] || [ -z "$t" ] || [ "$t" == "null" ]; then
            t=$(extract_token_from_certbot_conf "$d")
        fi

        info=$(inspect_cert_file "/etc/letsencrypt/live/$d/cert.pem")
        is_wild="${info#*|}"

        if [ "$t" != "None" ] && [ -n "$t" ] && [ "$t" != "null" ]; then
            sync_cf_cred_file "$d" "$t" >/dev/null
            echo -e "  ${C_GREEN}✔ Synced CF credential for:${RST} $d"
        elif [ "$is_wild" == "Yes" ]; then
            echo -e "  ${C_YELLOW}⚠️ Warning:${RST} Wildcard '$d' has no API token!"
        fi
    done < <(jq -c '.[]' "$DOMAINS_FILE" 2>/dev/null)
}

issue_or_renew_ssl_menu() {
    ui_sub_banner
    echo -e "  ${BOLD}${C_CYAN}🔐 ISSUE / RENEW SSL CERTIFICATES (WILDCARD & HTTP-01)${RST}"
    echo -e "  ${C_GRAY}Smart auto-token extraction & isolated renewal${RST}\n"

    list_domain_profiles
    local dc; dc=$(get_domains_count)
    if [ "$dc" -eq 0 ]; then
        echo -e "\n  ${C_YELLOW}Tip: Use Option [1], [4] or [5] to add/import domains first.${RST}"
        read -rp "Press [ENTER] to return..." < /dev/tty
        return
    fi

    echo -e "\n    ${C_CYAN}[A]${RST} 🔄 Smart Renew ALL Certificates"
    echo -e "    ${C_CYAN}[T]${RST} 🧪 Test / Dry-Run ALL Certificates (Simulation)"
    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Index [1-$dc], 'A' (Renew All), or 'T' (Dry-Run) [0 to cancel]: ${RST}")" SSL_CHOICE < /dev/tty

    if [[ "$SSL_CHOICE" =~ ^[aA]$ ]]; then
        echo -e "\n  ${C_BLUE}ℹ Auto-extracting CF tokens and running certbot renew...${RST}"
        prepare_all_cf_tokens
        echo ""
        certbot renew
        log OK "Global certificate renewal check completed."
        read -rp "Press [ENTER] to return..." < /dev/tty
        return
    elif [[ "$SSL_CHOICE" =~ ^[tT]$ ]]; then
        echo -e "\n  ${C_BLUE}ℹ Auto-extracting CF tokens and running Dry-Run simulation...${RST}"
        prepare_all_cf_tokens
        echo ""
        certbot renew --dry-run
        log OK "Dry-run renewal test completed."
        read -rp "Press [ENTER] to return..." < /dev/tty
        return
    fi

    if [[ "$SSL_CHOICE" =~ ^[0-9]+$ ]] && [ "$SSL_CHOICE" -ge 1 ] && [ "$SSL_CHOICE" -le "$dc" ]; then
        local target_dom target_tok target_zid
        target_dom=$(jq -r ".[$((SSL_CHOICE - 1))].domain" "$DOMAINS_FILE")
        target_tok=$(jq -r ".[$((SSL_CHOICE - 1))].token // \"None\"" "$DOMAINS_FILE")
        target_zid=$(jq -r ".[$((SSL_CHOICE - 1))].zone_id // \"None\"" "$DOMAINS_FILE")

        if [ "$target_tok" == "None" ] || [ -z "$target_tok" ] || [ "$target_tok" == "null" ]; then
            target_tok=$(extract_token_from_certbot_conf "$target_dom")
        fi

        echo -e "\n  ${BOLD}Selected Profile:${RST} ${C_CYAN}$target_dom${RST}"
        echo -e "    ${C_CYAN}[1]${RST} 🌐 Wildcard SSL via Cloudflare DNS-01"
        echo -e "    ${C_CYAN}[2]${RST} ⚡ Standard SSL via HTTP-01 Challenge"
        read -rp "$(echo -e "  ${C_PURPLE}▶ Select Method [1-2]: ${RST}")" R_METHOD < /dev/tty

        case "$R_METHOD" in
            1)
                if [ "$target_tok" == "None" ] || [ -z "$target_tok" ] || [ "$target_tok" == "null" ]; then
                    echo -e "\n  ${C_YELLOW}⚠️ Cloudflare API Token is required.${RST}"
                    read -rp "  ▶ Enter Cloudflare API Token for $target_dom: " new_tok < /dev/tty
                    if [ -z "$new_tok" ]; then
                        log ERR "Aborted: Wildcard SSL requires API Token."
                        read -rp "Press [ENTER] to return..." < /dev/tty
                        return
                    fi
                    target_tok="$new_tok"
                    sync_cf_cred_file "$target_dom" "$target_tok" >/dev/null
                fi

                local cred_file
                cred_file=$(sync_cf_cred_file "$target_dom" "$target_tok")

                certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$cred_file" \
                    -d "$target_dom" -d "*.$target_dom" --agree-tos --register-unsafely-without-email --non-interactive --force-renewal
                log OK "Wildcard SSL issued/renewed for $target_dom"
                ;;
            2)
                echo -e "\n  ${BOLD}Select HTTP-01 Challenge Mode:${RST}"
                echo -e "    ${C_CYAN}[1]${RST} Renew existing cert by name (--cert-name $target_dom)"
                echo -e "    ${C_CYAN}[2]${RST} Issue/Renew via Nginx plugin (--nginx)"
                echo -e "    ${C_CYAN}[3]${RST} Issue/Renew via Standalone HTTP on Port 80"
                read -rp "$(echo -e "  ${C_PURPLE}▶ Choose HTTP Mode [1-3]: ${RST}")" H_MODE < /dev/tty

                case "$H_MODE" in
                    1)
                        certbot renew --cert-name "$target_dom" --force-renewal
                        log OK "HTTP-01 renewal completed for: $target_dom"
                        ;;
                    2)
                        local dom_arg="$target_dom"
                        [[ "$target_dom" != *.* ]] && read -rp "  ▶ Enter actual subdomain/domain: " dom_arg < /dev/tty
                        certbot certonly --nginx -d "$dom_arg" --cert-name "$target_dom" --agree-tos --register-unsafely-without-email --non-interactive --force-renewal
                        log OK "Nginx HTTP-01 SSL issued/renewed for $dom_arg"
                        ;;
                    3)
                        local dom_arg="$target_dom"
                        [[ "$target_dom" != *.* ]] && read -rp "  ▶ Enter actual subdomain/domain: " dom_arg < /dev/tty
                        systemctl stop nginx 2>/dev/null || true
                        certbot certonly --standalone -d "$dom_arg" --cert-name "$target_dom" --agree-tos --register-unsafely-without-email --non-interactive --force-renewal
                        systemctl start nginx 2>/dev/null || true
                        log OK "Standalone HTTP-01 SSL issued/renewed for $dom_arg"
                        ;;
                esac
                ;;
        esac
    fi
    read -rp "Press [ENTER] to return..." < /dev/tty
}

push_domains_to_services() {
    ui_sub_banner
    echo -e "  ${BOLD}${C_CYAN}🔄 PUSH DOMAINS & CERTIFICATES TO SERVICES${RST}"
    echo -e "  ${C_GRAY}Syncing active certificates with local services${RST}\n"

    list_domain_profiles
    local dc; dc=$(get_domains_count)
    [ "$dc" -eq 0 ] && { read -rp "Press [ENTER] to return..." < /dev/tty; return; }

    read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Domain Index to Push [1-$dc]: ${RST}")" P_IDX < /dev/tty
    if [[ "$P_IDX" =~ ^[0-9]+$ ]] && [ "$P_IDX" -ge 1 ]] && [ "$P_IDX" -le "$dc" ]; then
        local target_dom
        target_dom=$(jq -r ".[$((P_IDX - 1))].domain" "$DOMAINS_FILE")
        local cert_dir="/etc/letsencrypt/live/$target_dom"

        if [ ! -d "$cert_dir" ]; then
            log ERR "Certificate directory $cert_dir not found!"
            read -rp "Press [ENTER] to return..." < /dev/tty
            return
        fi

        echo -e "  ${C_BLUE}ℹ Pushing certificate '$target_dom'...${RST}"
        systemctl reload nginx 2>/dev/null || true
        systemctl restart pg-deploy-web.service 2>/dev/null || true
        log OK "Push and service reload completed for: $target_dom"
    fi
    read -rp "Press [ENTER] to return..." < /dev/tty
}

manage_domain_profiles_crud() {
    while true; do
        ui_sub_banner
        echo -e "  ${BOLD}${C_CYAN}⚙️ DOMAIN PROFILES CRUD (EDIT / DELETE)${RST}\n"
        list_domain_profiles
        local dc; dc=$(get_domains_count)
        [ "$dc" -eq 0 ] && { read -rp "Press [ENTER] to return..." < /dev/tty; return; }

        echo -e "\n    ${C_CYAN}[1]${RST} Edit Profile"
        echo -e "    ${C_RED}[2]${RST} Delete Profile"
        echo -e "    ${C_GRAY}[0]${RST} Back"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Choose Action [0-2]: ${RST}")" CRUD_OPT < /dev/tty

        case "$CRUD_OPT" in
            1)
                read -rp "  ▶ Select Domain Index [1-$dc]: " E_IDX < /dev/tty
                if [[ "$E_IDX" =~ ^[0-9]+$ ]] && [ "$E_IDX" -ge 1 ] && [ "$E_IDX" -le "$dc" ]; then
                    local cur_dom cur_tok cur_zid
                    cur_dom=$(jq -r ".[$((E_IDX - 1))].domain" "$DOMAINS_FILE")
                    cur_tok=$(jq -r ".[$((E_IDX - 1))].token // \"None\"" "$DOMAINS_FILE")
                    cur_zid=$(jq -r ".[$((E_IDX - 1))].zone_id // \"None\"" "$DOMAINS_FILE")

                    echo -e "  Editing: ${BOLD}$cur_dom${RST}"
                    read -rp "  New Domain [Enter to keep]: " new_d < /dev/tty
                    read -rp "  New Token [Enter to keep]: " new_t < /dev/tty
                    read -rp "  New Zone ID [Enter to keep]: " new_z < /dev/tty

                    [ -z "$new_d" ] && new_d="$cur_dom"
                    [ -z "$new_t" ] && new_t="$cur_tok"
                    [ -z "$new_z" ] && new_z="$cur_zid"

                    [ "$new_t" != "None" ] && sync_cf_cred_file "$new_d" "$new_t" >/dev/null

                    local tmp_f; tmp_f=$(mktemp)
                    jq --arg idx "$((E_IDX - 1))" --arg d "$new_d" --arg t "$new_t" --arg z "$new_z" \
                       '.[$idx|tonumber].domain = $d | .[$idx|tonumber].token = $t | .[$idx|tonumber].zone_id = $z' \
                       "$DOMAINS_FILE" > "$tmp_f" && mv "$tmp_f" "$DOMAINS_FILE"
                    log OK "Profile updated."
                fi
                read -rp "Press [ENTER] to continue..." < /dev/tty
                ;;
            2)
                read -rp "  ▶ Select Domain Index [1-$dc]: " D_IDX < /dev/tty
                if [[ "$D_IDX" =~ ^[0-9]+$ ]] && [ "$D_IDX" -ge 1 ] && [ "$D_IDX" -le "$dc" ]; then
                    local target_d
                    target_d=$(jq -r ".[$((D_IDX - 1))].domain" "$DOMAINS_FILE")
                    read -rp "  ⚠️ Delete '$target_d'? [y/N]: " CONF_DEL < /dev/tty
                    if [[ "$CONF_DEL" =~ ^[yY]$ ]]; then
                        local tmp_f; tmp_f=$(mktemp)
                        jq "del(.[$((D_IDX - 1))])" "$DOMAINS_FILE" > "$tmp_f" && mv "$tmp_f" "$DOMAINS_FILE"
                        rm -f "/root/.secrets/certbot/cf-${target_d}.ini"
                        log OK "Deleted."
                    fi
                fi
                read -rp "Press [ENTER] to continue..." < /dev/tty
                ;;
            0) break ;;
        esac
    done
}

domains_ssl_menu() {
    while true; do
        ui_sub_banner
        echo -e "  ${BOLD}${C_CYAN}MODULE 2: DOMAINS & SSL MANAGER${RST}"
        echo -e "  ${C_GRAY}Manage Cloudflare/HTTP-01 domains & certificates${RST}\n"
        echo -e "  ${C_CYAN}[1]${RST} 🌐 List & Add Domain Profiles"
        echo -e "  ${C_CYAN}[2]${RST} ⚙️ Edit / Delete Profiles"
        echo -e "  ${C_CYAN}[3]${RST} 🔐 Issue / Renew SSL Certificates"
        echo -e "  ${C_CYAN}[4]${RST} 🔍 Scan & Import Server Certificates"
        echo -e "  ${C_CYAN}[5]${RST} 🌐 Create & Issue Subdomain SSL"
        echo -e "  ${C_CYAN}[6]${RST} 🔄 Push Certificates to Services"
        echo -e "  ${C_GRAY}[0]  Back to Main Dashboard${RST}"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-6]: ${RST}")" DM_OPT < /dev/tty
        case "$DM_OPT" in
            1)
                list_domain_profiles
                read -rp "$(echo -e "\n  ${C_PURPLE}Add new domain profile? [y/N]: ${RST}")" ADD_D < /dev/tty
                if [[ "$ADD_D" =~ ^[yY]$ ]]; then
                    read -rp "  ▶ Domain / Subdomain: " NEW_DOM < /dev/tty
                    read -rp "  ▶ Cloudflare API Token (Optional): " NEW_TOK < /dev/tty
                    read -rp "  ▶ Cloudflare Zone ID (Optional): " NEW_ZID < /dev/tty
                    if [ -n "$NEW_DOM" ]; then
                        [ -n "$NEW_TOK" ] && [ "$NEW_TOK" != "None" ] && sync_cf_cred_file "$NEW_DOM" "$NEW_TOK" >/dev/null
                        local tmp_d; tmp_d=$(mktemp)
                        jq --arg d "$NEW_DOM" --arg t "${NEW_TOK:-None}" --arg z "${NEW_ZID:-None}" \
                           '. += [{"domain": $d, "token": $t, "zone_id": $z}]' "$DOMAINS_FILE" > "$tmp_d" && mv "$tmp_d" "$DOMAINS_FILE"
                        log OK "Domain added."
                    fi
                fi
                read -rp "Press [ENTER] to return..." < /dev/tty
                ;;
            2)
                manage_domain_profiles_crud
                ;;
            3)
                issue_or_renew_ssl_menu
                ;;
            4)
                scan_and_import_certificates
                ;;
            5)
                create_and_issue_subdomain
                ;;
            6)
                push_domains_to_services
                ;;
            0) break ;;
        esac
    done
}
