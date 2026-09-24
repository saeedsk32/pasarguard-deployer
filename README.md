# 🚀 PasarGuard Multi-Node Auto-Deployer

<p align="center">
  <img src="https://img.shields.io/badge/Platform-PasarGuard-blue?style=for-the-badge" alt="Platform">
  <img src="https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white" alt="Language">
  <img src="https://img.shields.io/badge/SSL-Let's%20Encrypt%20Wildcard-003A70?style=for-the-badge&logo=letsencrypt&logoColor=white" alt="SSL">
  <img src="https://img.shields.io/badge/DNS-Cloudflare%20API-F38020?style=for-the-badge&logo=cloudflare&logoColor=white" alt="Cloudflare">
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge" alt="License">
</p>

ابزار جامع، ماژولار و تعاملی تحت ترمینال (Bash CLI) جهت خودکارسازی کامل فرآیند پیکربندی سرور، صدور و مدیریت گواهی‌های Wildcard SSL و اتصال امن نودها به سرور مستر در پلتفرم **PasarGuard**.

---

## ⚡ نصب و راه‌اندازی سریع (Quick Install)

روی سرور مستر (Master Server)، دستور تک‌خطی زیر را اجرا کنید:

```bash
bash <(curl -fsSL [https://raw.githubusercontent.com/saeedsk32/pasarguard-deployer/main/install.sh](https://raw.githubusercontent.com/saeedsk32/pasarguard-deployer/main/install.sh))
