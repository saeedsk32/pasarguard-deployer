<div align="center">

# 🚀 PasarGuard Multi-Node Auto-Deployer

[![Author: Saeed SK](https://img.shields.io/badge/Author-Saeed%20SK%20(@saeedsk32)-blueviolet.svg?style=flat&logo=github)](https://github.com/saeedsk32)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Language-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Ubuntu](https://img.shields.io/badge/OS-Ubuntu%2022.04%20%7C%2024.04-E95420.svg)](https://ubuntu.com/)
[![Cloudflare](https://img.shields.io/badge/Cloudflare-DNS%20v4-F38020.svg)](https://cloudflare.com/)

**Enterprise-grade DevOps CLI toolkit for orchestrating PasarGuard nodes, automated Cloudflare DNS management, multi-IP routing, and zero-config Let's Encrypt Wildcard SSL.**

Developed with ❤️ by **[Saeed SK](https://github.com/saeedsk32)**

[English](#-english-overview) • [راهنمای فارسی](#-راهنمای-فارسی) • [Quick Install](#-quick-install) • [Author](#-author)

</div>

---

<h2 id="-english-overview">🌐 English Overview</h2>

### ✨ Core Features

- 🔐 **Zero-Config Wildcard SSL**: Issues and renews Let's Encrypt Wildcard certificates via Cloudflare DNS plugin with cross-signed .
- 🚀 **Automated Node Provisioning**: Native  CLI orchestration with pre-injected SSL chains, TCP BBR optimization, and dual-protocol support ( & ).
- 🔁 **1-Click Server IP Migration**: Move nodes to new servers/IPs instantly with automated Cloudflare DNS updates and inventory sync.
- ⚡ **Cloudflare DNS Center**:
  - **Round-Robin Clean IPs**: Attach clean IPv4/IPv6 address pools to single or multiple subdomains.
  - **Interactive TUI Table**: Multi-select, bulk comment editing, and batch subdomain renaming.
  - **DNS Templates**: Ready-to-use subdomain presets for rapid scaling.
- 💾 **Full Disaster Recovery**: 1-click database & SSL cert archiving with an instant temporary browser download server ().

---

### ⚡ Quick Install

Run this one-liner on your **Master Server (Ubuntu 20.04/22.04/24.04)**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/saeedsk32/pasarguard-deployer/main/install.sh)"
```

To launch the dashboard anytime:
```bash
pg-deploy
```

---

<div dir="rtl">

<h2 id="-راهنمای-فارسی">🇮🇷 راهنمای فارسی</h2>

ابزار جامع، ماژولار و تعاملی تحت خط فرمان (TUI) توسعه‌داده‌شده توسط **سعید (saeedsk32)** جهت اتصال سریع نودها به پنل مستر پاسارگارد، مدیریت کامل DNS کلودفلر، گواهی‌های Wildcard و بازیابی اضطراری اطلاعات.

### 🌟 قابلیت‌های برجسته

- 🔐 **صدور و اتصال خودکار گواهی Wildcard SSL**: صدور بدون نیاز به باز بودن پورت ۸۰ بر پایه Cloudflare DNS Plugin با پشتیبانی از زنجیره ISRG Root X1.
- 🚀 **دیپلوی خودکار نودها**: هماهنگ با ابزار رسمی `pg-node`، فعال‌سازی کرنل BBR، و امکان انتخاب پروتکل `gRPC` (پیش‌فرض) یا `REST`.
- 🔁 **مهاجرت آنی آی‌پی (1-Click IP Migration)**: تغییر آدرس آی‌پی سرور نود و آپدیت خودکار تمام رکوردهای ساب‌دامین در کلودفلر تنها با یک دستور.
- ⚡ **مرکز مدیریت دی‌ان‌اس و آی‌پی‌های تمیز**:
  - ثبت توزیع‌شده (Round-Robin) ده‌ها IP تمیز کلودفلر روی یک ساب‌دامین.
  - جدول تعاملی با قابلیت انتخاب چندگانه (`all` یا شماره‌ای) جهت حذف، ویرایش کامنت و انتقال دسته‌جمعی ساب‌دامین‌ها.
  - قالب‌های آماده (Presets) برای نام‌گذاری سریع رکوردها در هنگام نصب نود.
- 💾 **مرکز بکاپ و ریستور**: آرشیو کامل پایگاه داده و گواهی‌ها به همراه **لینک مستقیم دانلود در مرورگر** روی پورت موقت `8088`.

### 🏛️ معماری منوها

</div>

```text
╭────────────────────────────────────────────────────────────────────────╮
│  [1] 🚀 Node Management Center     Deploy, 1-Click Migrate, Inbounds   │
│  [2] 🌐 Domains & SSL Manager      Certbot, Wildcards, Multi-SSL Sync  │
│  [3] ⚡ Cloudflare DNS Center      Clean IPs Table, Presets Templates  │
│  [4] 💾 Backup & Restore Center    1-Click Download Link & Recovery    │
│  [5] 📋 Diagnostics & Log Trace    View Live Operations History        │
╰────────────────────────────────────────────────────────────────────────╯
```

---

## 👨‍💻 Author

- **Saeed SK**
  - GitHub: [@saeedsk32](https://github.com/saeedsk32)

---

## 📄 License

This project is licensed under the [MIT License](LICENSE) - Copyright (c) 2026 Saeed SK.
