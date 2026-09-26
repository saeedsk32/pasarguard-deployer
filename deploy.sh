
manage_node_dns_center() {
    local n_idx="$1"
    local t_host t_bdom
    t_host=$(jq -r ".[$n_idx].hostname" "$NODES_FILE")
    t_bdom=$(jq -r ".[$n_idx].base_domain" "$NODES_FILE")
    local c_tok c_zid
    c_tok=$(jq -r --arg bd "$t_bdom" '.[] | select(.domain == $bd) | .token' "$DOMAINS_FILE")
    c_zid=$(jq -r --arg bd "$t_bdom" '.[] | select(.domain == $bd) | .zone_id' "$DOMAINS_FILE")

    while true; do
            ui_sub_banner
            
            # بررسی زنده لایه شبکه، پورت و هسته کرنل BBR
            local bbr_status="[38;5;244mUnknown[0m"
            local active_cc
            active_cc=$(sshpass -p "$target_pass" ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 "$target_user@$target_ip" "sysctl -n net.ipv4.tcp_congestion_control" 2>/dev/null)
            if [[ "$active_cc" == *"bbr"* ]]; then
                bbr_status="[38;5;48m● Active (BBR + FQ)[0m"
            elif [ -n "$active_cc" ]; then
                bbr_status="[38;5;220m○ Inactive ($active_cc)[0m"
            else
                bbr_status="[38;5;196m✖ Unreachable[0m"
            fi

            # وضعیت ارتباط زنده سرویس با پنل (پاسخگویی پورت API)
            local panel_status="[38;5;48m● Online (API Listening)[0m"
            local port_check
            port_check=$(sshpass -p "$target_pass" ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 "$target_user@$target_ip" "ss -tlpn | grep -q $target_aport && echo OK || echo FAIL" 2>/dev/null)
            if [ "$port_check" != "OK" ]; then
                panel_status="[38;5;220m○ Waiting / Standby[0m"
            fi

            # خواندن ایمن سرتیفیکیت برگشتی
            local _remote_cert _leaf_cert
            _remote_cert=$(sshpass -p "$target_pass" ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 "$target_user@$target_ip" "cat /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || cat /var/lib/pasarguard/ssl/cert.pem 2>/dev/null" 2>/dev/null || true)
            if [ -n "$_remote_cert" ]; then
                _leaf_cert=$(echo "$_remote_cert" | openssl x509 2>/dev/null || echo "$_remote_cert")
            else
                _leaf_cert="(Certificate not found on remote node)"
            fi

            # چاپ مستقیم کارت کامل اتصال بلافاصله پس از انتخاب نود
            echo -e "  [38;5;48m╭────────────────────────────────────────────────────────────────────────╮[0m"
            echo -e "  [38;5;48m│         PASARGUARD PANEL CONNECTION DETAILS                            │[0m"
            echo -e "  [38;5;48m├────────────────────────────────────────────────────────────────────────┤[0m"
            printf "  [38;5;48m│[0m  Node Name            : %-46s [38;5;48m│[0m
" "$target_host"
            printf "  [38;5;48m│[0m  Node Address         : %-46s [38;5;48m│[0m
" "$target_addr"
            printf "  [38;5;48m│[0m  Node Port            : %-46s [38;5;48m│[0m
" "$target_sport"
            printf "  [38;5;48m│[0m  API Port             : %-46s [38;5;48m│[0m
" "$target_aport"
            printf "  [38;5;48m│[0m  Connection Type      : %-46s [38;5;48m│[0m
" "${target_proto^^}"
            printf "  [38;5;48m│[0m  Panel Service Link   : %-55b [38;5;48m│[0m
" "$panel_status"
            printf "  [38;5;48m│[0m  TCP BBR Engine       : %-55b [38;5;48m│[0m
" "$bbr_status"
            printf "  [38;5;48m│[0m  API Key              : %-46s [38;5;48m│[0m
" "${target_token:-Not found}"
            echo -e "  [38;5;48m├────────────────────────────────────────────────────────────────────────┤[0m"
            echo -e "  [38;5;48m│  Cloudflare DNS Records:                                               │[0m"
            while IFS= read -r drec; do
                if [ -n "$drec" ]; then
                    printf "  [38;5;48m│[0m   • %-66s [38;5;48m│[0m
" "$drec"
                fi
            done < <(jq -r ".[$idx_pos].dns_records[]? // empty" "$NODES_FILE" 2>/dev/null)
            echo -e "  [38;5;48m├────────────────────────────────────────────────────────────────────────┤[0m"
            echo -e "  [38;5;48m│  SSL Certificate (Leaf / <2048 chars for Panel):                       │[0m"
            echo -e "  [38;5;48m╰────────────────────────────────────────────────────────────────────────╯[0m"
            echo -e "[38;5;220m$_leaf_cert[0m
"

            # منوی دسته‌بندی‌شده و استاندارد
            echo -e "  [1m[38;5;39m⚡ ORCHESTRATOR & INFRASTRUCTURE ACTIONS:[0m"
            echo -e "    [38;5;141m[1][0m  🔁 1-Click Server IP Migration (Auto CF DNS)"
            echo -e "    [38;5;141m[2][0m  🌐 Cloudflare DNS Center (Add / Edit / Delete Records)"
            echo -e "    [38;5;141m[3][0m  🔐 Inject / Sync Multi-Domain Wildcard SSLs"
            echo -e "    [38;5;141m[4][0m  🚀 Toggle / Tune TCP BBR Congestion Control"

            echo -e "
  [1m[38;5;48m🔧 PG-NODE CORE ACTIONS (Remote Binary Hooks):[0m"
            echo -e "    [38;5;48m[5][0m  ♻️  Restart Node Service"
            echo -e "    [38;5;48m[6][0m  📜 Follow Live Node Logs (Ctrl+C to exit)"
            echo -e "    [38;5;48m[7][0m  ⚡ Switch Protocol (gRPC <-> REST)"
            echo -e "    [38;5;48m[8][0m  ⚙️  Manage Systemd Service"
            echo -e "    [38;5;48m[9][0m  📦 Update / Change Xray-core"
            echo -e "    [38;5;48m[10][0m 🔄 Update PasarGuard Node Software"
            echo -e "    [38;5;48m[11][0m 🗺️  Update GeoFiles (GeoIP & GeoSite)"

            echo -e "
  [1m[38;5;196m🗑️  DELETION & CLEANUP:[0m"
            echo -e "    [38;5;244m[12][0m 🗑️  Delete from Local Inventory Only"
            echo -e "    [38;5;196m[13][0m 💣 Completely Uninstall Node & Clean DNS"
            echo -e "    [38;5;244m[0][0m   🔙 Back to Node List"

            read -rp "$(echo -e "
  [38;5;141m▶ Choose Action [0-13]: [0m")" N_ACT

            case "$N_ACT" in
                1)
                    read -rp "  ▶ Enter NEW Server IPv4: " NEW_NODE_IP
                    if [ -n "$NEW_NODE_IP" ]; then
                        local c_tok c_zid
                        c_tok=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .token' "$DOMAINS_FILE")
                        c_zid=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .zone_id' "$DOMAINS_FILE")
                        upsert_cloudflare_dns "$c_zid" "$c_tok" "$target_addr" "$NEW_NODE_IP" "PG-Node: $target_host | Migrated"
                        local tmp_m; tmp_m=$(mktemp)
                        jq --arg n "$idx_pos" --arg nip "$NEW_NODE_IP" '.[($n|tonumber)].ip = $nip' "$NODES_FILE" > "$tmp_m" && mv "$tmp_m" "$NODES_FILE"
                        target_ip="$NEW_NODE_IP"
                        log OK "Node IP updated to $NEW_NODE_IP on Cloudflare and local database."
                    fi
                    read -rp "  Press [ENTER] to continue..."
                    ;;
                2)
                    manage_node_dns_center "$idx_pos"
                    ;;
                3)
                    list_domain_profiles
                    local dc; dc=$(get_domains_count)
                    read -rp "  ▶ Select Domain profile to inject SSL [1-$dc]: " INJ_D
                    if [[ "$INJ_D" =~ ^[0-9]+$ ]] && [ "$INJ_D" -ge 1 ] && [ "$INJ_D" -le "$dc" ]; then
                        local inj_dom; inj_dom=$(jq -r ".[$((INJ_D - 1))].domain" "$DOMAINS_FILE")
                        if [ -f "/etc/letsencrypt/live/$inj_dom/fullchain.pem" ]; then
                            sshpass -p "$target_pass" ssh -p $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$target_user@$target_ip" "mkdir -p /var/lib/pg-node/certs/$inj_dom"
                            sshpass -p "$target_pass" scp -P $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "/etc/letsencrypt/live/$inj_dom/fullchain.pem" "$target_user@$target_ip:/var/lib/pg-node/certs/$inj_dom/" >/dev/null
                            sshpass -p "$target_pass" scp -P $target_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "/etc/letsencrypt/live/$inj_dom/privkey.pem" "$target_user@$target_ip:/var/lib/pg-node/certs/$inj_dom/" >/dev/null
                            log OK "Injected $inj_dom SSL into remote node."
                        fi
                    fi
                    read -rp "  Press [ENTER] to continue..."
                    ;;
                4)
                    toggle_node_bbr "$target_ip" "$target_port" "$target_user" "$target_pass" "$target_host"
                    read -rp "  Press [ENTER] to continue..."
                    ;;
                5)
                    eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node restart -n 2>/dev/null || true'"
                    log OK "Node service restarted."
                    read -rp "  Press [ENTER] to continue..."
                    ;;
                6)
                    eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node logs'"
                    ;;
                7)
                    local new_proto="rest"
                    [ "$target_proto" == "rest" ] && new_proto="grpc"
                    read -rp "  Switch protocol from $target_proto to $new_proto? [y/N]: " CONF_SW
                    if [[ "$CONF_SW" =~ ^[yY]$ ]]; then
                        local sw_flag="--use-grpc"
                        [ "$new_proto" == "rest" ] && sw_flag="--use-rest"
                        eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node protocol $sw_flag 2>/dev/null || true'"
                        local tmp_p; tmp_p=$(mktemp)
                        jq --arg n "$idx_pos" --arg pr "$new_proto" '.[($n|tonumber)].protocol = $pr' "$NODES_FILE" > "$tmp_p" && mv "$tmp_p" "$NODES_FILE"
                        target_proto="$new_proto"
                        log OK "Protocol switched to $new_proto."
                    fi
                    read -rp "  Press [ENTER] to continue..."
                    ;;
                8)
                    eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node service'"
                    ;;
                9)
                    eval "$ssh_cmd -t 'export PATH=/usr/local/bin:\$PATH; pg-node xray'"
                    ;;
                10)
                    eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node update -n 2>/dev/null || true'"
                    log OK "PasarGuard node software update triggered."
                    read -rp "  Press [ENTER] to continue..."
                    ;;
                11)
                    eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; pg-node geo -n 2>/dev/null || true'"
                    log OK "GeoFiles updated on remote node."
                    read -rp "  Press [ENTER] to continue..."
                    ;;
                12)
                    local tmp_d; tmp_d=$(mktemp)
                    jq "del(.[$idx_pos])" "$NODES_FILE" > "$tmp_d" && mv "$tmp_d" "$NODES_FILE"
                    log OK "Node removed from local inventory."
                    read -rp "  Press [ENTER] to continue..."
                    break
                    ;;
                13)
                    read -rp "  Type 'yes' to completely uninstall node and clean DNS: " PURGE_C
                    if [ "$PURGE_C" == "yes" ]; then
                        eval "$ssh_cmd 'export PATH=/usr/local/bin:\$PATH; echo -e "y
y" | pg-node uninstall 2>/dev/null || true; rm -rf /opt/pg-node /var/lib/pg-node; ufw delete allow $target_sport/tcp 2>/dev/null || true'"
                        local c_tok c_zid
                        c_tok=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .token' "$DOMAINS_FILE")
                        c_zid=$(jq -r --arg bd "$target_bdom" '.[] | select(.domain == $bd) | .zone_id' "$DOMAINS_FILE")
                        if [ -n "$c_tok" ] && [ -n "$c_zid" ]; then
                            jq -r ".[$idx_pos].dns_records[]? // empty" "$NODES_FILE" | while read -r r_to_del; do
                                local clean_name; clean_name=$(echo "$r_to_del" | awk '{print $1}')
                                local rec_id
                                rec_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records?name=$clean_name"                                      -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
                                [ -n "$rec_id" ] && curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$c_zid/dns_records/$rec_id" -H "Authorization: Bearer $c_tok" -H "Content-Type: application/json" >/dev/null
                            done
                        fi
                        local tmp_del; tmp_del=$(mktemp)
                        jq "del(.[$idx_pos])" "$NODES_FILE" > "$tmp_del" && mv "$tmp_del" "$NODES_FILE"
                        log OK "Node uninstalled and DNS cleaned."
                    fi
                    read -rp "  Press [ENTER] to continue..."
                    break
                    ;;
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
                            echo ""
            echo -e "  [38;5;141mPress [ENTER] to return to node menu...[0m"
            read -r _dummy < /dev/tty
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
    active_nodes_count=0; active_domains_count=0
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
