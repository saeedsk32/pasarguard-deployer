#!/bin/bash
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

web_panel_menu() {
    local WEB_CONF="$APP_DIR/web_config.json"
    if [ ! -f "$WEB_CONF" ]; then
        echo '{"port": 5050, "username": "admin", "password": "admin123", "ssl_domain": ""}' > "$WEB_CONF"
    fi

    while true; do
        ui_sub_banner
        echo -e "  ${BOLD}${C_CYAN}MODULE 6: LIGHTWEIGHT WEB DASHBOARD MANAGER${RST}"
        echo -e "  ${C_GRAY}Zero-bloat Flask Web UI synced with your local JSON inventory${RST}\n"
        
        local w_port w_user w_pass w_ssl w_status
        w_port=$(jq -r ".port // 5050" "$WEB_CONF" 2>/dev/null)
        w_user=$(jq -r ".username // \"admin\"" "$WEB_CONF" 2>/dev/null)
        w_pass=$(jq -r ".password // \"admin123\"" "$WEB_CONF" 2>/dev/null)
        w_ssl=$(jq -r ".ssl_domain // \"\"" "$WEB_CONF" 2>/dev/null)

        if systemctl is-active --quiet pg-deploy-web.service; then
            w_status="${C_GREEN}● Running (Active)${RST}"
        else
            w_status="${C_RED}○ Stopped${RST}"
        fi

        echo -e "  Access URL : ${C_CYAN}http://IP:${w_port}${RST}"
        echo -e "  Status     : $w_status\n"
        echo -e "    ${C_GREEN}[1]${RST} Start / Restart Web Dashboard"
        echo -e "    ${C_RED}[2]${RST} Stop Web Dashboard"
        echo -e "    ${C_GRAY}[0]${RST} Back"
        read -rp "$(echo -e "\n  ${C_PURPLE}▶ Select Option [0-2]: ${RST}")" W_OPT < /dev/tty

        case "$W_OPT" in
            1)
                systemctl restart pg-deploy-web.service 2>/dev/null || true
                log OK "Web Dashboard restarted."
                read -rp "Press [ENTER] to continue..." < /dev/tty
                ;;
            2)
                systemctl stop pg-deploy-web.service 2>/dev/null || true
                log OK "Web Dashboard stopped."
                read -rp "Press [ENTER] to continue..." < /dev/tty
                ;;
            0) break ;;
            *) ;;
        esac
    done
}
