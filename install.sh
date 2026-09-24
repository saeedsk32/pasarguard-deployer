#!/bin/bash
set -e
INSTALL_DIR="$HOME/pasarguard-deployer"
if [ -d "$INSTALL_DIR/.git" ]; then cd "$INSTALL_DIR" && git pull; else git clone https://github.com/saeedsk32/pasarguard-deployer.git "$INSTALL_DIR"; fi
chmod +x "$INSTALL_DIR/deploy.sh"
sudo ln -sf "$INSTALL_DIR/deploy.sh" /usr/local/bin/pg-deploy
echo "Installation completed! Run: pg-deploy"
