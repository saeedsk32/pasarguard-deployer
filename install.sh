#!/bin/bash
set -e
INSTALL_DIR="$HOME/pasarguard-deployer"
echo -e "\e[34m[*] Installing PasarGuard Auto-Deployer...\e[0m"
if [ -d "$INSTALL_DIR/.git" ]; then cd "$INSTALL_DIR" && git pull; else git clone https://github.com/saeedsk32/pasarguard-deployer.git "$INSTALL_DIR"; fi
chmod +x "$INSTALL_DIR/deploy.sh"
sudo ln -sf "$INSTALL_DIR/deploy.sh" /usr/local/bin/pg-deploy
echo -e "\e[32m[✓] Installation completed successfully!\e[0m"
echo -e "You can now run: \e[33mpg-deploy\e[0m from anywhere in your terminal."
