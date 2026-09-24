# 🚀 PasarGuard Multi-Node Auto-Deployer

ابزار خودکار و تعاملی تحت خط فرمان (Bash CLI) برای راه‌اندازی، اتصال، مدیریت گواهی‌های SSL و پیکربندی نودهای توزیع‌شده پلتفرم **PasarGuard**.

---

## ⚡ نصب و اجرای سریع (Quick Install & Run)

برای نصب خودکار این ابزار روی سرور مستر، کافی است دستور تک‌خطی زیر را در ترمینال اجرا کنید:

```bash
bash <(curl -fsSL [https://raw.githubusercontent.com/saeedsk32/pasarguard-deployer/main/install.sh](https://raw.githubusercontent.com/saeedsk32/pasarguard-deployer/main/install.sh))

از این پس در هر کجای سرور، تنها با تایپ دستور زیر منوی مدیریت برای شما باز خواهد شد:Bashpg-deploy
✨ امکانات و قابلیت‌های کلیدیمدیریت گواهی وایلدکارد (Wildcard SSL): صدور گواهی معتبر Let's Encrypt برای دامنه و زیردامنه‌ها (*.domain.com) از طریق اعتبارسنجی خودکار Cloudflare DNS (بدون نیاز به باز بودن پورت ۸۰ یا خاموش کردن پنل).مسیرهای استاندارد SSL: ذخیره و همگام‌سازی ساختاریافته در مسیر /etc/ssl/pasarguard/<domain>/ روی مستر و تمام نودها.انتقال امن بدون سیم‌لینک: رفع مشکل رایج سیم‌لینک‌های لینوکس برای دسترسی کانتینرهای داکر در نودها با پایپ مستقیم داده.پیکربندی هوشمند سرور نود:نام‌گذاری اختصاصی (Custom Hostname) برای تفکیک راحت در پنل.فعال‌سازی خودکار الگوریتم کنترل ازدحام TCP BBR.به‌روزرسانی بسته‌های سیستم‌عامل (apt update && apt upgrade).تنظیم فایروال UFW برای پورت‌های استاندارد پاسارگارد (62050 برای ترافیک و 62051 برای API).نصب خودکار بسته هسته کانتینری نود (pg-node).مدیریت داینامیک DNS کلودفلر: بررسی خودکار پیش از ثبت رکورد؛ ساخت رکورد جدید یا به‌روزرسانی رکورد قبلی در صورت تکراری بودن.کنسول مدیریت نودها (Node Inventory): امکان خواندن و مشاهده کلید عمومی گواهی، ری‌استارت کانتینرها، آپدیت هسته و مانیتورینگ بدون لاگین به نود.تمدید یکپارچه با ۱ کلیک (1-Click Renewal): تمدید خودکار در سرور مستر و ارسال آنی گواهی‌های جدید به تمام سرورهای نود.🖥 راهنمای گزینه‌های منوPlaintext+--------------------------------------------------------------------+
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
🛠 پیش‌نیازها و مشخصات فنیمشخصهتوضیح / مقدارسیستم‌عامل سازگارUbuntu 20.04+, Ubuntu 22.04+, Ubuntu 24.04+, Debian 11+زبان اسکریپتBashپایگاه‌دادهJSON فلت محلی (domains.json و nodes.json)پروتکل‌هاSSH / SCP بر بستر sshpassپورت‌های پیش‌فرضترافیک سرویس: 62050/tcp | پورت API: 62051/tcp📄 لایسنساین پروژه به صورت کدباز و رایگان برای جامعه کاربران لینوکس و پاسارگارد منتشر شده است.
