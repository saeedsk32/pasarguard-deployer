#!/usr/bin/env python3
import os
import json
import time
import subprocess
import re
from functools import wraps
from flask import Flask, request, Response, jsonify, render_template_string, make_response

APP_DIR = "/root/pasarguard-deployer"
DOMAINS_FILE = os.path.join(APP_DIR, "domains.json")
NODES_FILE = os.path.join(APP_DIR, "nodes.json")
WEB_CONF_FILE = os.path.join(APP_DIR, "web_config.json")

app = Flask(__name__)

# Server-side in-memory cache for fast response
SERVER_CACHE = {
    "status": {},
    "vault": {}
}
CACHE_TTL = 60  # seconds

def load_json(path, default):
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default

def save_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def get_master_ip():
    try:
        res = subprocess.run(["curl", "-s4", "--max-time", "3", "ifconfig.me"], capture_output=True, text=True)
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
    except Exception:
        pass
    try:
        res = subprocess.run(["hostname", "-I"], capture_output=True, text=True)
        return res.stdout.strip().split()[0]
    except Exception:
        return "127.0.0.1"

def get_web_config():
    return load_json(WEB_CONF_FILE, {
        "mode": "ip",
        "port": 5050,
        "username": "admin",
        "password": "admin123",
        "ssl_domain": "",
        "panel_fqdn": "",
        "panel_ip": ""
    })

def check_auth(username, password):
    conf = get_web_config()
    return username == conf.get("username", "admin") and password == conf.get("password", "admin123")

def authenticate():
    return Response(
        "Authentication Required", 401,
        {"WWW-Authenticate": 'Basic realm="PasarGuard Deployer Web"'}
    )

def requires_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.authorization
        if not auth or not check_auth(auth.username, auth.password):
            return authenticate()
        return f(*args, **kwargs)
    return decorated

def cf_upsert_record(zone_id, token, fqdn, ip, comment="PG-Deployer Web Panel"):
    rec_type = "AAAA" if ":" in ip else "A"
    get_cmd = [
        "curl", "-s", "-X", "GET",
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?name={fqdn}&type={rec_type}",
        "-H", f"Authorization: Bearer {token}", "-H", "Content-Type: application/json"
    ]
    res = subprocess.run(get_cmd, capture_output=True, text=True)
    rec_id = ""
    try:
        items = json.loads(res.stdout).get("result", [])
        if items:
            rec_id = items[0].get("id", "")
    except Exception:
        pass

    payload = json.dumps({
        "type": rec_type,
        "name": fqdn,
        "content": ip,
        "ttl": 1,
        "proxied": False,
        "comment": comment
    })

    if rec_id:
        put_cmd = [
            "curl", "-s", "-X", "PUT",
            f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{rec_id}",
            "-H", f"Authorization: Bearer {token}", "-H", "Content-Type: application/json",
            "--data", payload
        ]
        subprocess.run(put_cmd, capture_output=True)
    else:
        post_cmd = [
            "curl", "-s", "-X", "POST",
            f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records",
            "-H", f"Authorization: Bearer {token}", "-H", "Content-Type: application/json",
            "--data", payload
        ]
        subprocess.run(post_cmd, capture_output=True)
    return True

def cf_delete_record_by_name(zone_id, token, fqdn):
    if not fqdn or not zone_id or not token:
        return 0
    get_cmd = [
        "curl", "-s", "-X", "GET",
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?name={fqdn}",
        "-H", f"Authorization: Bearer {token}", "-H", "Content-Type: application/json"
    ]
    res = subprocess.run(get_cmd, capture_output=True, text=True)
    deleted_count = 0
    try:
        items = json.loads(res.stdout).get("result", [])
        for it in items:
            rid = it.get("id")
            if rid:
                del_cmd = [
                    "curl", "-s", "-X", "DELETE",
                    f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{rid}",
                    "-H", f"Authorization: Bearer {token}", "-H", "Content-Type: application/json"
                ]
                subprocess.run(del_cmd, capture_output=True)
                deleted_count += 1
    except Exception:
        pass
    return deleted_count

def run_ssh(node, cmd, timeout=15):
    ip = node.get("ip")
    port = str(node.get("ssh_port", 22))
    user = node.get("ssh_user", "root")
    pw = node.get("ssh_pass", "")
    ssh_cmd = [
        "sshpass", "-p", pw,
        "ssh", "-p", port,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-o", f"ConnectTimeout={timeout}",
        f"{user}@{ip}", cmd
    ]
    try:
        res = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=timeout+5)
        return res.returncode == 0, res.stdout.strip(), res.stderr.strip()
    except Exception as e:
        return False, "", str(e)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en" class="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PasarGuard Deployer — Web Control Center v9.3</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        body { background-color: #0b0f19; color: #e2e8f0; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
        .card { background-color: #111827; border: 1px solid #1f2937; border-left: 4px solid #10b981; }
        .btn { transition: all 0.15s ease; }
        .btn:active { transform: scale(0.96); }
        pre { white-space: pre-wrap; word-break: break-all; }
    </style>
</head>
<body class="min-h-screen p-4 md:p-8">
    <div class="max-w-7xl mx-auto">
        <!-- Header -->
        <div class="flex flex-col lg:flex-row justify-between items-start lg:items-center bg-gray-900 border border-cyan-500/40 rounded-lg p-5 mb-6 shadow-lg gap-4">
            <div>
                <div class="flex flex-wrap items-center gap-3">
                    <span class="text-2xl font-bold text-cyan-400">⚡ PasarGuard Deployer</span>
                    <span class="bg-emerald-500/20 text-emerald-400 text-xs px-2.5 py-1 rounded border border-emerald-500/40">v9.3 Instant-Cache</span>
                    {% if web_conf.mode == 'domain' and web_conf.panel_fqdn %}
                    <span class="bg-purple-500/20 text-purple-300 text-xs px-2.5 py-1 rounded border border-purple-500/40">🔒 Domain Mode ({{ web_conf.panel_fqdn }})</span>
                    {% else %}
                    <span class="bg-amber-500/20 text-amber-300 text-xs px-2.5 py-1 rounded border border-amber-500/40">🖥️ IP Mode ({{ master_ip }})</span>
                    {% endif %}
                </div>
                <p class="text-gray-400 text-xs mt-1">Automated Multi-Node & Multi-SSL Orchestrator by Saeed SK (@saeedsk32)</p>
            </div>
            <div class="flex flex-wrap gap-2 text-xs">
                <button onclick="openModeModal()" class="bg-purple-600 hover:bg-purple-500 text-white px-3.5 py-2 rounded font-bold btn">🌐 Access Mode (IP / Domain)</button>
                <button onclick="forceRefreshAll()" class="bg-cyan-600 hover:bg-cyan-500 text-white px-3.5 py-2 rounded font-bold btn">🔄 Force Refresh</button>
            </div>
        </div>

        <!-- Toast Notification -->
        <div id="toast" class="fixed bottom-5 right-5 hidden bg-emerald-600 text-white px-5 py-3 rounded-lg shadow-xl font-bold z-50"></div>

        <!-- Registered Domains Bar -->
        <div class="bg-gray-900/80 border border-gray-800 rounded-lg p-4 mb-6 flex flex-col sm:flex-row justify-between items-start sm:items-center gap-3">
            <div>
                <h2 class="text-xs font-bold text-cyan-400 mb-2">🌐 REGISTERED CLOUDFLARE DOMAINS & WILDCARDS</h2>
                <div class="flex flex-wrap gap-2">
                    {% for d in domains %}
                    <div class="bg-gray-800 border border-gray-700 px-3 py-1 rounded text-xs flex items-center gap-2">
                        <span class="text-emerald-400">●</span>
                        <span class="font-bold text-white">{{ d.domain }}</span>
                        <span class="text-gray-500">(Zone: {{ d.zone_id[:8] }}...)</span>
                    </div>
                    {% else %}
                    <span class="text-gray-500 text-xs">No domains registered yet.</span>
                    {% endfor %}
                </div>
            </div>
            <div class="text-right text-[11px] text-gray-400">
                <div>Browser Cache: <span id="cache-indicator" class="text-emerald-400 font-bold">⚡ Active</span></div>
                <div>Master IP: <span class="text-white">{{ master_ip }}</span></div>
            </div>
        </div>

        <!-- Nodes Grid -->
        <div class="grid grid-cols-1 gap-6">
            {% for n in nodes %}
            {% set idx = loop.index0 %}
            <div class="card rounded-lg p-6 shadow-lg" id="node-card-{{ idx }}">
                <div class="flex flex-col lg:flex-row justify-between items-start lg:items-center border-b border-gray-800 pb-4 mb-4 gap-4">
                    <div>
                        <div class="flex items-center gap-3">
                            <span class="text-xl font-bold text-white">{{ n.hostname }}</span>
                            <span class="text-xs bg-purple-500/20 text-purple-300 px-2.5 py-0.5 rounded border border-purple-500/30 uppercase">{{ n.protocol }}</span>
                            <span id="status-badge-{{ idx }}" class="text-xs bg-gray-800 text-gray-400 px-2.5 py-0.5 rounded">Checking...</span>
                        </div>
                        <p class="text-gray-400 text-xs mt-1">Primary IP: <span class="text-cyan-300">{{ n.ip }}</span> │ Master Address: <span class="text-emerald-300">{{ n.address }}</span></p>
                    </div>
                    <div class="flex flex-wrap gap-2">
                        <button onclick="openVaultModal({{ idx }}, '{{ n.hostname }}')" class="bg-emerald-600 hover:bg-emerald-500 text-white text-xs px-3 py-2 rounded font-bold btn">🔐 Multi-SSL Vault & Keys</button>
                        <button onclick="nodeAction({{ idx }}, 'restart')" class="bg-blue-600 hover:bg-blue-500 text-white text-xs px-3 py-2 rounded font-bold btn">♻️ Restart</button>
                        <button onclick="nodeAction({{ idx }}, 'update_xray')" class="bg-indigo-600 hover:bg-indigo-500 text-white text-xs px-3 py-2 rounded font-bold btn">📦 Update Xray</button>
                        <button onclick="nodeAction({{ idx }}, 'bbr_toggle')" class="bg-amber-600 hover:bg-amber-500 text-white text-xs px-3 py-2 rounded font-bold btn">🚀 Toggle BBR</button>
                        <button onclick="migrateIpPrompt({{ idx }}, '{{ n.hostname }}', '{{ n.ip }}')" class="bg-purple-600 hover:bg-purple-500 text-white text-xs px-3 py-2 rounded font-bold btn">🔁 Migrate IP</button>
                        <button onclick="purgeNodePrompt({{ idx }}, '{{ n.hostname }}')" class="bg-red-600 hover:bg-red-500 text-white text-xs px-3 py-2 rounded font-bold btn">💣 Uninstall & Clean DNS</button>
                    </div>
                </div>

                <!-- Details Grid -->
                <div class="grid grid-cols-1 md:grid-cols-3 gap-4 text-xs mb-4">
                    <div class="bg-gray-900 p-3.5 rounded border border-gray-800">
                        <div class="text-gray-400 mb-1">Panel Connection Info</div>
                        <div class="flex justify-between py-1 border-b border-gray-800/80"><span>Node Address:</span> <button onclick="copyText('{{ n.address }}')" class="text-cyan-400 hover:underline font-bold">{{ n.address }} 📋</button></div>
                        <div class="flex justify-between py-1 border-b border-gray-800/80"><span>Service / API Port:</span> <span class="text-white font-bold">{{ n.service_port }} / {{ n.api_port }}</span></div>
                        <div class="flex justify-between py-1"><span>API Key UUID:</span> <button onclick="copyText('{{ n.api_token }}')" class="text-amber-400 hover:underline font-bold">Copy UUID 📋</button></div>
                    </div>

                    <div class="bg-gray-900 p-3.5 rounded border border-gray-800">
                        <div class="text-gray-400 mb-1">Live Telemetry & Disk Paths (Option A)</div>
                        <div class="flex justify-between py-1 border-b border-gray-800/80"><span>TCP BBR Engine:</span> <span id="bbr-{{ idx }}" class="text-gray-400">...</span></div>
                        <div class="flex justify-between py-1 border-b border-gray-800/80"><span>Active Xray-Core:</span> <span id="xray-{{ idx }}" class="text-gray-400">...</span></div>
                        <div class="flex justify-between py-1">
                            <span>Default Paths:</span>
                            <div class="flex gap-2">
                                <button onclick="copyText('/var/lib/pg-node/certs/{{ n.base_domain }}/fullchain.pem')" class="text-emerald-400 hover:underline">Cert Path 📋</button>
                                <button onclick="copyText('/var/lib/pg-node/certs/{{ n.base_domain }}/privkey.pem')" class="text-rose-400 hover:underline">Key Path 📋</button>
                            </div>
                        </div>
                    </div>

                    <div class="bg-gray-900 p-3.5 rounded border border-gray-800">
                        <div class="text-gray-400 mb-1">Cloudflare DNS Records ({{ n.dns_records|length }})</div>
                        <div class="max-h-20 overflow-y-auto space-y-1 pr-1">
                            {% for r in n.dns_records %}
                            <div class="text-gray-300 truncate">• {{ r }}</div>
                            {% endfor %}
                        </div>
                    </div>
                </div>

                <!-- Quick Copy Leaf Cert Bar -->
                <div class="bg-gray-950 border border-gray-800 rounded p-3 flex flex-col sm:flex-row justify-between items-start sm:items-center gap-2 text-xs">
                    <span class="text-gray-400">🔒 Active Master Panel SSL Certificate (Leaf &lt;2048 chars):</span>
                    <div class="flex gap-2">
                        <button onclick="copyNodeLeaf({{ idx }})" class="bg-emerald-700 hover:bg-emerald-600 text-white px-3 py-1.5 rounded font-bold btn">📋 Copy Active Leaf Cert</button>
                    </div>
                </div>
                <textarea id="leaf-store-{{ idx }}" class="hidden"></textarea>
            </div>
            {% else %}
            <div class="bg-gray-900 border border-gray-800 rounded-lg p-12 text-center text-gray-400">
                No active nodes deployed yet. Use <code class="text-cyan-400">pg-deploy</code> in terminal to deploy your first node.
            </div>
            {% endfor %}
        </div>
    </div>

    <!-- Web Panel Mode Switcher Modal (IP vs Domain + Cloudflare Auto DNS) -->
    <div id="mode-modal" class="fixed inset-0 bg-black/80 hidden items-center justify-center p-4 z-40">
        <div class="bg-gray-900 border border-purple-500/50 rounded-lg max-w-xl w-full p-6 shadow-2xl text-xs">
            <div class="flex justify-between items-center border-b border-gray-800 pb-3 mb-4">
                <h3 class="text-base font-bold text-purple-400">🌐 Web Panel Access Mode (IP vs Domain)</h3>
                <button onclick="closeModeModal()" class="text-gray-400 hover:text-white text-lg font-bold">✕</button>
            </div>

            <div class="bg-gray-950 border border-gray-800 rounded p-3.5 mb-4 space-y-1">
                <div>Current Mode: <span class="font-bold text-emerald-400 uppercase">{{ web_conf.mode }}</span></div>
                <div>Master Server IP: <span class="text-cyan-300">{{ master_ip }}</span></div>
                <div>Active Domain FQDN: <span class="text-purple-300">{{ web_conf.panel_fqdn or 'None (Raw IP Mode)' }}</span></div>
                <div>Port: <span class="text-white">{{ web_conf.port }}</span></div>
            </div>

            <!-- Switch to Domain Mode Box -->
            <div class="bg-gray-800/60 border border-purple-500/30 rounded p-4 mb-4">
                <h4 class="font-bold text-purple-300 mb-2">🔒 Option 1: Switch to Domain Mode (HTTPS + Auto Cloudflare DNS)</h4>
                <p class="text-gray-400 mb-3">Automatically creates an unproxied A record in Cloudflare pointing to <code class="text-white">{{ master_ip }}</code> and activates Let's Encrypt Wildcard HTTPS.</p>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 mb-3">
                    <div>
                        <label class="block text-gray-400 mb-1">Subdomain Prefix:</label>
                        <input id="inp-sub-prefix" type="text" placeholder="e.g. panel or deploy" value="panel" class="w-full bg-gray-900 border border-gray-700 rounded px-3 py-1.5 text-white">
                    </div>
                    <div>
                        <label class="block text-gray-400 mb-1">Select Base Domain:</label>
                        <select id="inp-base-dom" class="w-full bg-gray-900 border border-gray-700 rounded px-3 py-1.5 text-white">
                            {% for d in domains %}
                            <option value="{{ d.domain }}">{{ d.domain }}</option>
                            {% endfor %}
                        </select>
                    </div>
                </div>
                <button onclick="switchPanelMode('domain')" class="w-full bg-purple-600 hover:bg-purple-500 text-white py-2 rounded font-bold btn">🚀 Setup Cloudflare Record & Switch to Domain Mode</button>
            </div>

            <!-- Switch to IP Mode Box -->
            <div class="bg-gray-800/60 border border-amber-500/30 rounded p-4">
                <h4 class="font-bold text-amber-300 mb-2">🖥️ Option 2: Switch to Raw IP Mode (HTTP + Purge Cloudflare Record)</h4>
                <p class="text-gray-400 mb-3">Switches panel back to <code class="text-white">http://{{ master_ip }}:{{ web_conf.port }}</code> and <b>automatically deletes</b> the panel's subdomain record from Cloudflare.</p>
                <button onclick="switchPanelMode('ip')" class="w-full bg-amber-600 hover:bg-amber-500 text-white py-2 rounded font-bold btn">🗑️ Delete Cloudflare Record & Revert to IP Mode</button>
            </div>
        </div>
    </div>

    <!-- Multi-SSL Vault Modal -->
    <div id="vault-modal" class="fixed inset-0 bg-black/80 hidden items-center justify-center p-4 z-40">
        <div class="bg-gray-900 border border-cyan-500/50 rounded-lg max-w-4xl w-full max-h-[90vh] flex flex-col shadow-2xl">
            <div class="flex justify-between items-center p-4 border-b border-gray-800">
                <div class="flex items-center gap-3">
                    <h3 class="text-lg font-bold text-cyan-400" id="vault-modal-title">🔐 Multi-SSL Vault Explorer</h3>
                    <button id="vault-refresh-btn" class="bg-gray-800 hover:bg-gray-700 text-cyan-300 text-xs px-2.5 py-1 rounded border border-gray-700">🔄 Refresh Vault</button>
                </div>
                <button onclick="closeVaultModal()" class="text-gray-400 hover:text-white text-xl font-bold">✕</button>
            </div>
            <div id="vault-modal-body" class="p-6 overflow-y-auto space-y-6 text-xs">
                Loading vault profiles...
            </div>
        </div>
    </div>

    <script>
        const CACHE_PREFIX = 'pg_deploy_v93_';

        function showToast(msg, isErr=false) {
            const t = document.getElementById('toast');
            t.textContent = msg;
            t.className = `fixed bottom-5 right-5 px-5 py-3 rounded-lg shadow-xl font-bold z-50 ${isErr ? 'bg-red-600' : 'bg-emerald-600'} text-white`;
            t.classList.remove('hidden');
            setTimeout(() => t.classList.add('hidden'), 3200);
        }

        function setCache(key, data) {
            try {
                localStorage.setItem(CACHE_PREFIX + key, JSON.stringify({ts: Date.now(), data}));
            } catch (e) {}
        }

        function getCache(key, maxAgeMs = 300000) {
            try {
                const raw = localStorage.getItem(CACHE_PREFIX + key);
                if (!raw) return null;
                const parsed = JSON.parse(raw);
                if (Date.now() - parsed.ts > maxAgeMs) return null;
                return parsed.data;
            } catch (e) {
                return null;
            }
        }

        function applyStatusToDom(idx, data) {
            const badge = document.getElementById(`status-badge-${idx}`);
            if (!badge) return;
            if (data.online) {
                badge.textContent = '● Online (API Listening)';
                badge.className = 'text-xs bg-emerald-500/20 text-emerald-400 px-2.5 py-0.5 rounded border border-emerald-500/30';
            } else {
                badge.textContent = '○ Standby / Unreachable';
                badge.className = 'text-xs bg-amber-500/20 text-amber-400 px-2.5 py-0.5 rounded border border-amber-500/30';
            }
            document.getElementById(`bbr-${idx}`).textContent = data.bbr;
            document.getElementById(`xray-${idx}`).textContent = data.xray;
            document.getElementById(`leaf-store-${idx}`).value = data.leaf_cert || '';
        }

        async function loadNodeStatus(idx, force=false) {
            const cacheKey = `node_status_${idx}`;
            if (!force) {
                const cached = getCache(cacheKey);
                if (cached) {
                    applyStatusToDom(idx, cached);
                }
            }
            try {
                const res = await fetch(`/api/node/${idx}/status${force ? '?force=1' : ''}`);
                const data = await res.json();
                setCache(cacheKey, data);
                applyStatusToDom(idx, data);
            } catch (e) {
                console.error(e);
            }
        }

        function forceRefreshAll() {
            localStorage.clear();
            showToast('⚡ Clearing cache & fetching live node states...');
            const count = {{ nodes|length }};
            for (let i = 0; i < count; i++) {
                loadNodeStatus(i, true);
            }
        }

        function copyText(text) {
            if (navigator.clipboard && window.isSecureContext) {
                navigator.clipboard.writeText(text).then(() => showToast('✔ Copied to clipboard!'));
            } else {
                const ta = document.createElement('textarea');
                ta.value = text;
                ta.style.position = 'fixed';
                ta.style.left = '-9999px';
                document.body.appendChild(ta);
                ta.select();
                document.execCommand('copy');
                document.body.removeChild(ta);
                showToast('✔ Copied to clipboard!');
            }
        }

        function copyNodeLeaf(idx) {
            const val = document.getElementById(`leaf-store-${idx}`).value;
            if (!val) return showToast('Certificate still loading or unavailable', true);
            copyText(val);
        }

        async function nodeAction(idx, action, extra={}) {
            showToast(`⏳ Executing ${action}...`);
            try {
                const res = await fetch(`/api/node/${idx}/action`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({action, ...extra})
                });
                const data = await res.json();
                if (data.ok) {
                    showToast(`✔ ${data.message}`);
                    localStorage.removeItem(CACHE_PREFIX + `node_status_${idx}`);
                    localStorage.removeItem(CACHE_PREFIX + `node_vault_${idx}`);
                    if (action === 'purge_node' || action === 'migrate_ip') {
                        setTimeout(() => location.reload(), 1000);
                    } else {
                        loadNodeStatus(idx, true);
                    }
                } else {
                    showToast(`✖ ${data.message}`, true);
                }
            } catch (e) {
                showToast('✖ Action failed', true);
            }
        }

        function migrateIpPrompt(idx, host, oldIp) {
            const newIp = prompt(`Enter NEW Server IPv4 for ${host} (Current: ${oldIp}):`);
            if (newIp && newIp.trim() !== '') {
                nodeAction(idx, 'migrate_ip', {new_ip: newIp.trim()});
            }
        }

        function purgeNodePrompt(idx, host) {
            if (confirm(`Are you sure you want to completely uninstall ${host} and delete all its Cloudflare DNS records?`)) {
                nodeAction(idx, 'purge_node');
            }
        }

        function renderVaultProfiles(profiles) {
            const body = document.getElementById('vault-modal-body');
            if (!profiles || profiles.length === 0) {
                body.innerHTML = '<div class="text-red-400">No certificates found on remote node.</div>';
                return;
            }
            let html = '';
            profiles.forEach((p, i) => {
                const encLeaf = encodeURIComponent(p.leaf_cert);
                const encFull = encodeURIComponent(p.fullchain);
                const encKey = encodeURIComponent(p.privkey);
                html += `
                <div class="bg-gray-950 border ${p.active ? 'border-emerald-500' : 'border-gray-800'} rounded-lg p-4">
                    <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center border-b border-gray-800 pb-3 mb-3 gap-2">
                        <div>
                            <span class="font-bold text-emerald-400">[PROFILE ${i+1}] ${p.cert_path}</span>
                            <div class="text-gray-400 mt-0.5">${p.active ? '● ACTIVE PANEL SERVICE SSL' : '○ Stored Inbound Vault'} │ Subject: <span class="text-white">${p.subject}</span> │ Chain: ${p.levels} Level(s)</div>
                        </div>
                        <div class="flex flex-wrap gap-2">
                            <button onclick="copyText(decodeURIComponent('${encLeaf}'))" class="bg-emerald-600 hover:bg-emerald-500 text-white px-3 py-1.5 rounded font-bold">📋 Copy Leaf Cert</button>
                            <button onclick="copyText(decodeURIComponent('${encKey}'))" class="bg-rose-600 hover:bg-rose-500 text-white px-3 py-1.5 rounded font-bold">🔑 Copy Private Key</button>
                            <button onclick="copyText(decodeURIComponent('${encFull}'))" class="bg-cyan-700 hover:bg-cyan-600 text-white px-3 py-1.5 rounded font-bold">📜 Copy FullChain</button>
                        </div>
                    </div>
                    <div class="grid grid-cols-1 md:grid-cols-2 gap-2 bg-gray-900 p-2.5 rounded border border-gray-800 mb-3">
                        <div class="flex justify-between items-center">
                            <span class="text-gray-400">Cert Path: <code class="text-cyan-300">${p.cert_path}</code></span>
                            <button onclick="copyText('${p.cert_path}')" class="text-cyan-400 hover:underline font-bold">Copy 📋</button>
                        </div>
                        <div class="flex justify-between items-center">
                            <span class="text-gray-400">Key Path: <code class="text-cyan-300">${p.key_path}</code></span>
                            <button onclick="copyText('${p.key_path}')" class="text-cyan-400 hover:underline font-bold">Copy 📋</button>
                        </div>
                    </div>
                    <details class="text-gray-400">
                        <summary class="cursor-pointer hover:text-white font-bold">👁️ View Raw Certificate & Key Boxes</summary>
                        <div class="grid grid-cols-1 md:grid-cols-2 gap-3 mt-3">
                            <div>
                                <div class="text-emerald-400 font-bold mb-1">1. LEAF CERTIFICATE CONTENT:</div>
                                <pre class="bg-black p-2 rounded border border-gray-800 text-[10px] text-emerald-300 max-h-48 overflow-y-auto">${p.leaf_cert}</pre>
                            </div>
                            <div>
                                <div class="text-rose-400 font-bold mb-1">2. KEY CONTENT BOX:</div>
                                <pre class="bg-black p-2 rounded border border-gray-800 text-[10px] text-rose-300 max-h-48 overflow-y-auto">${p.privkey}</pre>
                            </div>
                        </div>
                    </details>
                </div>`;
            });
            body.innerHTML = html;
        }

        async function openVaultModal(idx, host, force=false) {
            const modal = document.getElementById('vault-modal');
            const body = document.getElementById('vault-modal-body');
            document.getElementById('vault-modal-title').textContent = `🔐 Multi-SSL Vault & Dossier — ${host}`;
            document.getElementById('vault-refresh-btn').onclick = () => openVaultModal(idx, host, true);
            modal.classList.remove('hidden');
            modal.classList.add('flex');

            const cacheKey = `node_vault_${idx}`;
            if (!force) {
                const cached = getCache(cacheKey, 600000);
                if (cached) {
                    renderVaultProfiles(cached);
                    return;
                }
            }

            body.innerHTML = '<div class="text-center py-8 text-cyan-400">Scanning remote /var/lib/pg-node/certs/...</div>';
            try {
                const res = await fetch(`/api/node/${idx}/vault${force ? '?force=1' : ''}`);
                const data = await res.json();
                setCache(cacheKey, data.profiles || []);
                renderVaultProfiles(data.profiles || []);
            } catch (e) {
                body.innerHTML = '<div class="text-red-400">Failed to load vault details.</div>';
            }
        }

        function closeVaultModal() {
            const modal = document.getElementById('vault-modal');
            modal.classList.add('hidden');
            modal.classList.remove('flex');
        }

        function openModeModal() {
            const modal = document.getElementById('mode-modal');
            modal.classList.remove('hidden');
            modal.classList.add('flex');
        }

        function closeModeModal() {
            const modal = document.getElementById('mode-modal');
            modal.classList.add('hidden');
            modal.classList.remove('flex');
        }

        async function switchPanelMode(targetMode) {
            const subPrefix = document.getElementById('inp-sub-prefix')?.value || 'panel';
            const baseDom = document.getElementById('inp-base-dom')?.value || '';
            showToast(`⏳ Switching panel to ${targetMode.toUpperCase()} mode...`);
            try {
                const res = await fetch('/api/panel/mode', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({
                        mode: targetMode,
                        sub_prefix: subPrefix.trim(),
                        base_domain: baseDom.trim()
                    })
                });
                const data = await res.json();
                if (data.ok) {
                    showToast(`✔ ${data.message}`);
                    setTimeout(() => {
                        window.location.href = data.redirect_url;
                    }, 2000);
                } else {
                    showToast(`✖ ${data.message}`, true);
                }
            } catch (e) {
                showToast('✖ Failed to switch mode', true);
            }
        }

        document.addEventListener('DOMContentLoaded', () => {
            const count = {{ nodes|length }};
            for (let i = 0; i < count; i++) {
                loadNodeStatus(i, false);
            }
        });
    </script>
</body>
</html>
"""

@app.route("/")
@requires_auth
def index():
    nodes = load_json(NODES_FILE, [])
    domains = load_json(DOMAINS_FILE, [])
    web_conf = get_web_config()
    master_ip = get_master_ip()
    resp = make_response(render_template_string(
        HTML_TEMPLATE,
        nodes=nodes,
        domains=domains,
        web_conf=web_conf,
        master_ip=master_ip
    ))
    resp.headers["Cache-Control"] = "private, max-age=15, stale-while-revalidate=60"
    return resp

@app.route("/api/panel/mode", methods=["POST"])
@requires_auth
def switch_panel_mode():
    conf = get_web_config()
    domains = load_json(DOMAINS_FILE, [])
    data = request.json or {}
    target_mode = data.get("mode", "ip")
    port = conf.get("port", 5050)
    master_ip = get_master_ip()

    if target_mode == "domain":
        base_dom = data.get("base_domain", "").strip()
        sub_prefix = data.get("sub_prefix", "panel").strip()
        if not base_dom or not sub_prefix:
            return jsonify({"ok": False, "message": "Domain and subdomain prefix are required."})

        dom_obj = next((d for d in domains if d.get("domain") == base_dom), None)
        if not dom_obj:
            return jsonify({"ok": False, "message": f"Domain {base_dom} not found in registered domains."})

        # If a previous different panel_fqdn existed, clean it first
        old_fqdn = conf.get("panel_fqdn", "")
        old_dom = conf.get("ssl_domain", "")
        fqdn = f"{sub_prefix}.{base_dom}"
        if old_fqdn and old_fqdn != fqdn and old_dom:
            old_obj = next((d for d in domains if d.get("domain") == old_dom), None)
            if old_obj:
                cf_delete_record_by_name(old_obj["zone_id"], old_obj["token"], old_fqdn)

        cf_upsert_record(dom_obj["zone_id"], dom_obj["token"], fqdn, master_ip, "PG-Deployer Web Panel")

        conf["mode"] = "domain"
        conf["ssl_domain"] = base_dom
        conf["panel_fqdn"] = fqdn
        conf["panel_ip"] = master_ip
        save_json(WEB_CONF_FILE, conf)

        # Restart service in background after 1 second
        subprocess.Popen(["bash", "-c", "sleep 1 && systemctl restart pg-deploy-web.service"])
        proto = "https" if os.path.exists(f"/etc/letsencrypt/live/{base_dom}/fullchain.pem") else "http"
        return jsonify({
            "ok": True,
            "message": f"Created Cloudflare DNS {fqdn} -> {master_ip} & enabled {proto.upper()}!",
            "redirect_url": f"{proto}://{fqdn}:{port}"
        })

    else:
        # Switch to IP mode & delete Cloudflare DNS record
        old_fqdn = conf.get("panel_fqdn", "")
        old_dom = conf.get("ssl_domain", "")
        if old_fqdn and old_dom:
            old_obj = next((d for d in domains if d.get("domain") == old_dom), None)
            if old_obj:
                cf_delete_record_by_name(old_obj["zone_id"], old_obj["token"], old_fqdn)

        conf["mode"] = "ip"
        conf["ssl_domain"] = ""
        conf["panel_fqdn"] = ""
        conf["panel_ip"] = master_ip
        save_json(WEB_CONF_FILE, conf)

        subprocess.Popen(["bash", "-c", "sleep 1 && systemctl restart pg-deploy-web.service"])
        return jsonify({
            "ok": True,
            "message": f"Deleted {old_fqdn or 'domain'} from Cloudflare & switched to IP Mode!",
            "redirect_url": f"http://{master_ip}:{port}"
        })

@app.route("/api/node/<int:idx>/status")
@requires_auth
def node_status(idx):
    force = request.args.get("force") == "1"
    now = time.time()
    if not force and idx in SERVER_CACHE["status"]:
        cached_entry = SERVER_CACHE["status"][idx]
        if now - cached_entry["ts"] < CACHE_TTL:
            resp = make_response(jsonify(cached_entry["data"]))
            resp.headers["Cache-Control"] = "private, max-age=30"
            return resp

    nodes = load_json(NODES_FILE, [])
    if idx < 0 or idx >= len(nodes):
        return jsonify({"ok": False}), 404
    n = nodes[idx]
    aport = n.get("api_port", 62051)
    bdom = n.get("base_domain", "")
    cmd = f"""
    export PATH=/usr/local/bin:$PATH
    echo "===CC==="
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown"
    echo "===PORT==="
    ss -tlpn 2>/dev/null | grep -q {aport} && echo "ONLINE" || echo "STANDBY"
    echo "===XRAY==="
    pg-node 2>/dev/null | grep -A1 'Current Xray-core version:' | tail -n1 | tr -d ' \\r'
    echo "===CERT==="
    openssl x509 -in /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null || openssl x509 -in /var/lib/pg-node/certs/{bdom}/fullchain.pem 2>/dev/null || true
    """
    ok, out, _ = run_ssh(n, cmd, timeout=6)
    if not ok:
        res_data = {"online": False, "bbr": "Unreachable", "xray": "Unreachable", "leaf_cert": ""}
        return jsonify(res_data)

    parts = out.split("===")
    cc, port_st, xray_v, cert_str = "unknown", "STANDBY", "Unknown", ""
    for i in range(len(parts)):
        if parts[i] == "CC" and i+1 < len(parts):
            cc = parts[i+1].strip()
        elif parts[i] == "PORT" and i+1 < len(parts):
            port_st = parts[i+1].strip()
        elif parts[i] == "XRAY" and i+1 < len(parts):
            xray_v = parts[i+1].strip()
        elif parts[i] == "CERT" and i+1 < len(parts):
            cert_str = parts[i+1].strip()

    res_data = {
        "online": port_st == "ONLINE",
        "bbr": f"Active ({cc})" if "bbr" in cc else cc,
        "xray": xray_v or "Unknown",
        "leaf_cert": cert_str
    }
    SERVER_CACHE["status"][idx] = {"ts": now, "data": res_data}
    resp = make_response(jsonify(res_data))
    resp.headers["Cache-Control"] = "private, max-age=30"
    return resp

@app.route("/api/node/<int:idx>/vault")
@requires_auth
def node_vault(idx):
    force = request.args.get("force") == "1"
    now = time.time()
    if not force and idx in SERVER_CACHE["vault"]:
        cached_entry = SERVER_CACHE["vault"][idx]
        if now - cached_entry["ts"] < CACHE_TTL * 2:
            resp = make_response(jsonify({"profiles": cached_entry["data"]}))
            resp.headers["Cache-Control"] = "private, max-age=60"
            return resp

    nodes = load_json(NODES_FILE, [])
    if idx < 0 or idx >= len(nodes):
        return jsonify({"profiles": []}), 404
    n = nodes[idx]
    ok, files_out, _ = run_ssh(n, "find /var/lib/pg-node/certs -type f \\( -name 'fullchain.pem' -o -name 'self_cert.pem' \\) 2>/dev/null | sort", timeout=8)
    if not ok or not files_out:
        return jsonify({"profiles": []})

    _, active_hash, _ = run_ssh(n, "md5sum /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null | awk '{print $1}'", timeout=5)
    profiles = []
    for cf in files_out.splitlines():
        cf = cf.strip()
        if not cf:
            continue
        kf = os.path.join(os.path.dirname(cf), "self_key.pem" if "self_cert.pem" in cf else "privkey.pem")
        cmd = f"""
        echo "===HASH==="
        md5sum "{cf}" 2>/dev/null | awk '{{print $1}}'
        echo "===SUBJ==="
        openssl x509 -in "{cf}" -noout -subject 2>/dev/null | sed 's/subject=//;s/^[ \\t]*//'
        echo "===LEAF==="
        openssl x509 -in "{cf}" 2>/dev/null
        echo "===FULL==="
        cat "{cf}" 2>/dev/null
        echo "===KEY==="
        cat "{kf}" 2>/dev/null
        """
        ok_p, p_out, _ = run_ssh(n, cmd, timeout=8)
        if not ok_p:
            continue
        segs = p_out.split("===")
        chash, subj, leaf, full, priv = "", "", "", "", ""
        for i in range(len(segs)):
            if segs[i] == "HASH" and i+1 < len(segs): chash = segs[i+1].strip()
            elif segs[i] == "SUBJ" and i+1 < len(segs): subj = segs[i+1].strip()
            elif segs[i] == "LEAF" and i+1 < len(segs): leaf = segs[i+1].strip()
            elif segs[i] == "FULL" and i+1 < len(segs): full = segs[i+1].strip()
            elif segs[i] == "KEY" and i+1 < len(segs): priv = segs[i+1].strip()

        levels = full.count("BEGIN CERTIFICATE") or 1
        profiles.append({
            "cert_path": cf,
            "key_path": kf,
            "subject": subj,
            "levels": levels,
            "active": bool(active_hash and chash == active_hash),
            "leaf_cert": leaf,
            "fullchain": full,
            "privkey": priv
        })
    SERVER_CACHE["vault"][idx] = {"ts": now, "data": profiles}
    resp = make_response(jsonify({"profiles": profiles}))
    resp.headers["Cache-Control"] = "private, max-age=60"
    return resp

@app.route("/api/node/<int:idx>/action", methods=["POST"])
@requires_auth
def node_action(idx):
    nodes = load_json(NODES_FILE, [])
    domains = load_json(DOMAINS_FILE, [])
    if idx < 0 or idx >= len(nodes):
        return jsonify({"ok": False, "message": "Invalid node index"}), 404
    n = nodes[idx]
    data = request.json or {}
    act = data.get("action")

    # Invalidate server cache for this node
    SERVER_CACHE["status"].pop(idx, None)
    SERVER_CACHE["vault"].pop(idx, None)

    if act == "restart":
        ok, _, _ = run_ssh(n, "export PATH=/usr/local/bin:$PATH; pg-node restart -y 2>/dev/null || docker restart node 2>/dev/null || true")
        return jsonify({"ok": ok, "message": "Node service restarted"})

    elif act == "update_xray":
        ok, _, _ = run_ssh(n, "export PATH=/usr/local/bin:$PATH; pg-node core-update --version latest -y 2>/dev/null || true", timeout=35)
        return jsonify({"ok": ok, "message": "Xray-core updated to latest version"})

    elif act == "bbr_toggle":
        _, cc, _ = run_ssh(n, "sysctl -n net.ipv4.tcp_congestion_control")
        if "bbr" in cc:
            run_ssh(n, "echo 'net.core.default_qdisc=pfifo_fast' > /etc/sysctl.d/99-bbr.conf; echo 'net.ipv4.tcp_congestion_control=cubic' >> /etc/sysctl.d/99-bbr.conf; sysctl --system >/dev/null 2>&1")
            return jsonify({"ok": True, "message": "TCP BBR disabled (reverted to cubic)"})
        else:
            run_ssh(n, "modprobe tcp_bbr 2>/dev/null || true; echo 'net.core.default_qdisc=fq' > /etc/sysctl.d/99-bbr.conf; echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.d/99-bbr.conf; sysctl --system >/dev/null 2>&1")
            return jsonify({"ok": True, "message": "TCP BBR enabled (fq + bbr)"})

    elif act == "migrate_ip":
        new_ip = data.get("new_ip", "").strip()
        if not new_ip:
            return jsonify({"ok": False, "message": "New IP required"})
        bdom = n.get("base_domain")
        dom_obj = next((d for d in domains if d.get("domain") == bdom), None)
        if dom_obj:
            cf_upsert_record(dom_obj["zone_id"], dom_obj["token"], n.get("address"), new_ip, f"PG-Node: {n.get('hostname')} | Migrated")
        nodes[idx]["ip"] = new_ip
        save_json(NODES_FILE, nodes)
        return jsonify({"ok": True, "message": f"Migrated node IP to {new_ip}"})

    elif act == "purge_node":
        sport = n.get("service_port", 62050)
        run_ssh(n, f"export PATH=/usr/local/bin:$PATH; echo -e 'y\\ny' | pg-node uninstall 2>/dev/null || true; docker rm -f node 2>/dev/null || true; systemctl stop pg-node pg-node-service 2>/dev/null || true; rm -rf /opt/pg-node /var/lib/pg-node /usr/local/bin/pg-node /usr/bin/pg-node /etc/systemd/system/pg-node*.service; ufw delete allow {sport}/tcp 2>/dev/null || true", timeout=20)
        bdom = n.get("base_domain")
        dom_obj = next((d for d in domains if d.get("domain") == bdom), None)
        if dom_obj:
            zid = dom_obj["zone_id"]
            tok = dom_obj["token"]
            for rec_entry in n.get("dns_records", []):
                fqdn = rec_entry.split()[0].strip()
                cf_delete_record_by_name(zid, tok, fqdn)
        nodes.pop(idx)
        save_json(NODES_FILE, nodes)
        return jsonify({"ok": True, "message": "Node uninstalled and DNS records purged"})

    return jsonify({"ok": False, "message": "Unknown action"})

if __name__ == "__main__":
    conf = get_web_config()
    port = int(conf.get("port", 5050))
    mode = conf.get("mode", "ip")
    ssl_dom = conf.get("ssl_domain", "").strip()
    cert_f = f"/etc/letsencrypt/live/{ssl_dom}/fullchain.pem"
    key_f = f"/etc/letsencrypt/live/{ssl_dom}/privkey.pem"
    if mode == "domain" and ssl_dom and os.path.exists(cert_f) and os.path.exists(key_f):
        app.run(host="0.0.0.0", port=port, ssl_context=(cert_f, key_f))
    else:
        app.run(host="0.0.0.0", port=port)
