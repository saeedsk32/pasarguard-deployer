#!/bin/bash
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
                log INFO "DNS Presets management active."
                read -rp "Press [ENTER] to return..." < /dev/tty
                ;;
            0) break ;;
            *) ;;
        esac
    done
}
