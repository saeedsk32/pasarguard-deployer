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

پس از اتمام نصب، در هر مسیر از ترمینال تنها با تایپ دستور زیر منوی تعاملی اجرا می‌شود:

Bash
pg-deploy

🌟 قابلیت‌های برجسته (Key Features)
صدور هوشمند گواهی‌های Wildcard SSL:

دریافت گواهی از Let's Encrypt برای دامنه اصلی و کلیه ساب‌دامنه‌ها (*.domain.com).

اعتبارسنجی خودکار از طریق API کلودفلر (DNS Challenge) بدون نیاز به اشغال پورت ۸۰ یا خاموش کردن وب‌سرور/پنل.

ساختار مسیردهی استاندارد در مستر و نودها:

انتقال و همگام‌سازی مستقیم در مسیر اختصاصی:

مسیر گواهی: /etc/ssl/pasarguard/<domain>/fullchain.pem

مسیر کلید خصوصی: /etc/ssl/pasarguard/<domain>/privkey.pem

حل ریشه‌ای معضل سیم‌لینک‌های لینوکس برای دسترسی روان کانتینرهای داکر نود.

اتوماسیون کامل پیکربندی نودها (Automated Provisioning):

تنظیم نام هاست‌نیم اختصاصی جهت تفکیک دقیق در پنل.

فعال‌سازی الگوریتم شتاب‌دهنده هسته لینوکس TCP BBR.

به‌روزرسانی بسته‌های امنیتی سیستم‌عامل به‌صورت کاملاً بی‌صدا.

باز کردن پورت‌های ارتباطی پاسارگارد (62050/tcp و 62051/tcp) در فایروال UFW.

امکان نصب خودکار بسته باینری نود پاسارگارد (pg-node).

مدیریت داینامیک DNS کلودفلر:

استعلام لحظه‌ای پیش از ثبت؛ تشخیص خودکار و ویرایش رکورد (Update) در صورت وجود، یا ایجاد رکورد جدید (Create).

مرکز کنترل نودها و مدیریت پروفایل‌ها:

ذخیره‌سازی محلی دیتابیس در فایل‌های سبک JSON (domains.json و nodes.json).

مشاهده محتوای گواهی عمومی، ری‌استارت کانتینرها، تمدید یک‌کلیکه (1-Click SSL Sync) و ارتقای هسته نود از راه دور.

🖥 نمای منوی مدیریت (CLI Preview)
Plaintext
+--------------------------------------------------------------------+
|                PASARGUARD MULTI-NODE AUTO-DEPLOYER                 |
+--------------------------------------------------------------------+

  [1] Deploy New Node
      > Configure remote node & transfer SSL to standard paths

  [2] Issue Wildcard SSL Certificate
      > Let's Encrypt wildcard via Cloudflare & sync to master

  [3] Sync SSL to Local Master Server
      > Deploy certificates to /etc/ssl/pasarguard/<domain> on Master

  [4] Manage Saved Nodes
      > Inspect SSL, view exact paths, restart & update nodes

  [5] Domain Profiles Manager
      > Add, edit, or delete domains, Cloudflare tokens and zone IDs

  [6] Renew & Synchronize SSL
      > Certbot renew & 1-click push to Master + all Nodes

  [7] View Execution Logs
      > Inspect real-time deployment history and reports

  [8] Exit

📋 نیازمندی‌ها و مشخصات فنی (Technical Specifications)مشخصه فنیشرح / مقدارسیستم‌عامل سازگارUbuntu 20.04 / 22.04 / 24.04 LTS, Debian 11 / 12زبان و پوستهPOSIX Bashپیش‌نیازهای نرم‌افزاریcurl, jq, sshpass, certbot, python3-certbot-dns-cloudflare (نصب خودکار)موتور ذخیره‌سازی محلیدیتابیس تخت JSON با کارایی بالاپورت‌های پیش‌فرض ارتباطیترافیک سرویس: 62050/tcp | ارتباط API: 62051/tcp

📄 لایسنس (License)
این پروژه تحت لایسنس MIT به صورت متن‌باز منتشر شده است.

