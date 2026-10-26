#!/usr/bin/env python3
import os
import json
import time
import subprocess
import uuid
from functools import wraps
from flask import Flask, request, Response, jsonify, render_template_string, make_response, redirect, url_for

APP_DIR = "/root/pasarguard-deployer"
DOMAINS_FILE = os.path.join(APP_DIR, "domains.json")
NODES_FILE = os.path.join(APP_DIR, "nodes.json")
WEB_CONF_FILE = os.path.join(APP_DIR, "web_config.json")

app = Flask(__name__)

SERVER_CACHE = {"status": {}, "vault": {}}
CACHE_TTL = 60

def load_json(path, default):
    if not os.path.exists(path): return default
    try:
        with open(path, "r", encoding="utf-8") as f: return json.load(f)
    except Exception: return default

def save_json(path, data):
    with open(path, "w", encoding="utf-8") as f: json.dump(data, f, indent=2, ensure_ascii=False)

def get_master_ip():
    try:
        res = subprocess.run(["curl", "-s4", "--max-time", "3", "ifconfig.me"], capture_output=True, text=True)
        if res.returncode == 0 and res.stdout.strip(): return res.stdout.strip()
    except Exception: pass
    try:
        res = subprocess.run(["hostname", "-I"], capture_output=True, text=True)
        return res.stdout.strip().split()[0]
    except Exception: return "127.0.0.1"

def get_web_config():
    conf = load_json(WEB_CONF_FILE, {"port": 5050, "token": ""})
    return conf

def requires_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        conf = get_web_config()
        server_token = conf.get("token", "")
        client_token = request.args.get("token") or request.cookies.get("pg_token")
        
        if not server_token or client_token != server_token:
            return Response("""
            <!DOCTYPE html>
            <html lang="en" class="dark">
            <head><meta charset="UTF-8"><title>Unauthorized Access</title><script src="https://cdn.tailwindcss.com"></script></head>
            <body class="bg-gray-950 text-gray-200 flex items-center justify-center min-h-screen font-mono">
                <div class="bg-gray-900 border border-red-500/40 p-8 rounded-xl shadow-2xl text-center max-w-md">
                    <div class="text-red-400 text-5xl mb-4">⛔</div>
                    <h1 class="text-xl font-bold text-white mb-2">Access Denied / Invalid Token</h1>
                    <p class="text-gray-400 text-xs mb-6">This PasarGuard Web Panel requires a fresh secure one-time token generated from your server terminal.</p>
                    <div class="bg-gray-950 p-3 rounded border border-gray-800 text-cyan-400 text-xs">Run <code class="text-white">pg-deploy</code> -> Module 6 to generate a fresh secure login link.</div>
                </div>
            </body>
            </html>
            """, 403)
        return f(*args, **kwargs)
    return decorated

def run_ssh(node, cmd, timeout=15):
    ip, port, user, pw = node.get("ip"), str(node.get("ssh_port", 22)), node.get("ssh_user", "root"), node.get("ssh_pass", "")
    ssh_cmd = ["sshpass", "-p", pw, "ssh", "-p", port, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", f"ConnectTimeout={timeout}", f"{user}@{ip}", cmd]
    try:
        res = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=timeout+5)
        return res.returncode == 0, res.stdout.strip(), res.stderr.strip()
    except Exception as e: return False, "", str(e)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en" class="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PasarGuard Deployer — Enterprise Dashboard v1.0</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        body { background-color: #07090e; color: #e2e8f0; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
        .glass-card { background: rgba(17, 24, 39, 0.75); backdrop-filter: blur(12px); border: 1px solid rgba(31, 41, 55, 0.8); }
        .btn-action { transition: all 0.2s ease; }
        .btn-action:hover { transform: translateY(-1px); filter: brightness(1.1); }
        .btn-action:active { transform: translateY(0px); }
        pre { white-space: pre-wrap; word-break: break-all; }
    </style>
</head>
<body class="min-h-screen p-4 md:p-8">
    <div class="max-w-7xl mx-auto">
        <!-- Top Navigation / Header -->
        <div class="glass-card rounded-2xl p-6 mb-8 shadow-2xl flex flex-col lg:flex-row justify-between items-start lg:items-center gap-4">
            <div>
                <div class="flex items-center gap-3">
                    <div class="bg-cyan-500/10 border border-cyan-500/30 p-2.5 rounded-xl text-cyan-400 text-xl font-bold">⚡</div>
                    <div>
                        <h1 class="text-2xl font-black tracking-wider text-white">PASARGUARD <span class="text-cyan-400">DEPLOYER</span></h1>
                        <p class="text-gray-400 text-xs">Secure Token-Authenticated DevOps & Multi-Node Orchestrator</p>
                    </div>
                </div>
            </div>
            <div class="flex flex-wrap items-center gap-3">
                <div class="bg-gray-900/90 border border-gray-800 px-4 py-2 rounded-xl text-xs flex items-center gap-3">
                    <div>Nodes: <span class="text-white font-bold">{{ nodes|length }}</span></div>
                    <div class="text-gray-600">│</div>
                    <div>Domains: <span class="text-cyan-400 font-bold">{{ domains|length }}</span></div>
                </div>
                <button onclick="openDeployModal()" class="bg-gradient-to-r from-cyan-600 to-blue-600 hover:from-cyan-500 hover:to-blue-500 text-white px-4 py-2.5 rounded-xl text-xs font-bold btn-action shadow-lg shadow-cyan-900/30 flex items-center gap-2">
                    <span>🚀 Deploy New Node</span>
                </button>
                <button onclick="forceRefreshAll()" class="bg-gray-800 hover:bg-gray-700 text-cyan-300 px-4 py-2.5 rounded-xl text-xs font-bold btn-action border border-gray-700">
                    🔄 Refresh
                </button>
            </div>
        </div>

        <!-- Toast Notification -->
        <div id="toast" class="fixed bottom-6 right-6 hidden bg-emerald-600 text-white px-5 py-3 rounded-xl shadow-2xl font-bold z-50 text-xs border border-emerald-400/40"></div>

        <!-- Domains Bar -->
        <div class="glass-card rounded-2xl p-5 mb-8">
            <h2 class="text-xs font-bold tracking-widest text-cyan-400 mb-3 uppercase">🌐 Registered Cloudflare Domains & Wildcards</h2>
            <div class="flex flex-wrap gap-2.5">
                {% for d in domains %}
                <div class="bg-gray-900/90 border border-gray-800 px-3.5 py-2 rounded-xl text-xs flex items-center gap-2.5">
                    <span class="text-emerald-400">●</span>
                    <span class="font-bold text-white">{{ d.domain }}</span>
                    <span class="text-gray-500 text-[10px]">(Zone: {{ d.zone_id[:8] }}...)</span>
                </div>
                {% else %}
                <span class="text-gray-500 text-xs">No domains registered yet. Add a domain via terminal `pg-deploy`.</span>
                {% endfor %}
            </div>
        </div>

        <!-- Nodes List -->
        <div class="space-y-6">
            {% for n in nodes %}
            {% set idx = loop.index0 %}
            <div class="glass-card rounded-2xl p-6 shadow-xl border-l-4 border-l-emerald-500" id="node-card-{{ idx }}">
                <div class="flex flex-col lg:flex-row justify-between items-start lg:items-center border-b border-gray-800/80 pb-5 mb-5 gap-4">
                    <div>
                        <div class="flex items-center gap-3">
                            <span class="text-xl font-black text-white">{{ n.hostname }}</span>
                            <span class="text-[10px] bg-purple-500/10 text-purple-300 px-2.5 py-1 rounded-lg border border-purple-500/30 uppercase font-bold">{{ n.protocol }}</span>
                            <span id="status-badge-{{ idx }}" class="text-[10px] bg-gray-800 text-gray-400 px-2.5 py-1 rounded-lg font-bold">Checking...</span>
                        </div>
                        <p class="text-gray-400 text-xs mt-1.5 flex flex-wrap gap-3">
                            <span>IP: <strong class="text-cyan-300">{{ n.ip }}</strong></span>
                            <span class="text-gray-600">•</span>
                            <span>Master Link: <strong class="text-emerald-300">{{ n.address }}</strong></span>
                        </p>
                    </div>
                    <div class="flex flex-wrap gap-2">
                        <button onclick="openVaultModal({{ idx }}, '{{ n.hostname }}')" class="bg-emerald-600/90 hover:bg-emerald-500 text-white text-xs px-3.5 py-2 rounded-xl font-bold btn-action shadow-md">🔐 Multi-SSL Vault</button>
                        <button onclick="nodeAction({{ idx }}, 'restart')" class="bg-blue-600/90 hover:bg-blue-500 text-white text-xs px-3.5 py-2 rounded-xl font-bold btn-action shadow-md">♻️ Restart</button>
                        <button onclick="nodeAction({{ idx }}, 'update_xray')" class="bg-indigo-600/90 hover:bg-indigo-500 text-white text-xs px-3.5 py-2 rounded-xl font-bold btn-action shadow-md">📦 Update Xray</button>
                        <button onclick="nodeAction({{ idx }}, 'bbr_toggle')" class="bg-amber-600/90 hover:bg-amber-500 text-white text-xs px-3.5 py-2 rounded-xl font-bold btn-action shadow-md">🚀 BBR</button>
                        <button onclick="purgeNodePrompt({{ idx }}, '{{ n.hostname }}')" class="bg-red-600/90 hover:bg-red-500 text-white text-xs px-3.5 py-2 rounded-xl font-bold btn-action shadow-md">💣 Uninstall</button>
                    </div>
                </div>

                <!-- Node Grid -->
                <div class="grid grid-cols-1 md:grid-cols-3 gap-4 text-xs mb-4">
                    <div class="bg-gray-900/80 p-4 rounded-xl border border-gray-800/80">
                        <div class="text-gray-400 font-bold mb-2 uppercase text-[10px] tracking-wider text-cyan-400">Connection Info</div>
                        <div class="flex justify-between py-1.5 border-b border-gray-800"><span>Address:</span> <button onclick="copyText('{{ n.address }}')" class="text-cyan-400 font-bold hover:underline">Copy 📋</button></div>
                        <div class="flex justify-between py-1.5 border-b border-gray-800"><span>Ports (Service/API):</span> <span class="text-white font-bold">{{ n.service_port }} / {{ n.api_port }}</span></div>
                        <div class="flex justify-between py-1.5"><span>API Key UUID:</span> <button onclick="copyText('{{ n.api_token }}')" class="text-amber-400 font-bold hover:underline">Copy UUID 📋</button></div>
                    </div>

                    <div class="bg-gray-900/80 p-4 rounded-xl border border-gray-800/80">
                        <div class="text-gray-400 font-bold mb-2 uppercase text-[10px] tracking-wider text-cyan-400">Telemetry & Disk Paths</div>
                        <div class="flex justify-between py-1.5 border-b border-gray-800"><span>TCP BBR:</span> <span id="bbr-{{ idx }}" class="text-gray-400">...</span></div>
                        <div class="flex justify-between py-1.5 border-b border-gray-800"><span>Xray Core:</span> <span id="xray-{{ idx }}" class="text-gray-400">...</span></div>
                        <div class="flex justify-between py-1.5">
                            <span>Default Cert Paths:</span>
                            <div class="flex gap-2">
                                <button onclick="copyText('/var/lib/pg-node/certs/{{ n.base_domain }}/fullchain.pem')" class="text-emerald-400 font-bold hover:underline">Cert 📋</button>
                                <button onclick="copyText('/var/lib/pg-node/certs/{{ n.base_domain }}/privkey.pem')" class="text-rose-400 font-bold hover:underline">Key 📋</button>
                            </div>
                        </div>
                    </div>

                    <div class="bg-gray-900/80 p-4 rounded-xl border border-gray-800/80">
                        <div class="text-gray-400 font-bold mb-2 uppercase text-[10px] tracking-wider text-cyan-400">Cloudflare DNS Records ({{ n.dns_records|length }})</div>
                        <div class="max-h-24 overflow-y-auto space-y-1.5 pr-1 text-[11px]">
                            {% for r in n.dns_records %}
                            <div class="text-gray-300 truncate">• {{ r }}</div>
                            {% endfor %}
                        </div>
                    </div>
                </div>

                <!-- Leaf Cert Bar -->
                <div class="bg-gray-950/90 border border-gray-800 rounded-xl p-3.5 flex flex-col sm:flex-row justify-between items-start sm:items-center gap-3 text-xs">
                    <span class="text-gray-400">🔒 Active Master Panel SSL Certificate (Leaf &lt;2048 chars):</span>
                    <button onclick="copyNodeLeaf({{ idx }})" class="bg-emerald-600 hover:bg-emerald-500 text-white px-4 py-2 rounded-xl font-bold btn-action shadow">📋 Copy Active Leaf Cert</button>
                </div>
                <textarea id="leaf-store-{{ idx }}" class="hidden"></textarea>
            </div>
            {% else %}
            <div class="glass-card rounded-2xl p-16 text-center text-gray-400">
                <div class="text-4xl mb-3">🛰️</div>
                <div class="text-base font-bold text-white mb-1">No Active Nodes Deployed Yet</div>
                <p class="text-xs text-gray-500 mb-4">You can deploy new nodes instantly using the top right button or via terminal.</p>
                <button onclick="openDeployModal()" class="bg-cyan-600 hover:bg-cyan-500 text-white px-5 py-2.5 rounded-xl text-xs font-bold btn-action shadow-lg">Deploy First Node Now</button>
            </div>
            {% endfor %}
        </div>
    </div>

    <!-- Deploy Node Modal -->
    <div id="deploy-modal" class="fixed inset-0 bg-black/80 backdrop-blur-sm hidden items-center justify-center p-4 z-50">
        <div class="bg-gray-900 border border-cyan-500/40 rounded-2xl max-w-xl w-full p-6 shadow-2xl text-xs max-h-[90vh] overflow-y-auto">
            <div class="flex justify-between items-center border-b border-gray-800 pb-3 mb-4">
                <h3 class="text-sm font-bold text-cyan-400">🚀 Deploy New PasarGuard Node</h3>
                <button onclick="closeDeployModal()" class="text-gray-400 hover:text-white text-base font-bold">✕</button>
            </div>
            <form id="deploy-form" onsubmit="submitDeploy(event)" class="space-y-3">
                <div>
                    <label class="block text-gray-400 mb-1">Select Domain Profile:</label>
                    <select id="d-dom" class="w-full bg-gray-950 border border-gray-800 rounded-xl px-3.5 py-2 text-white">
                        {% for d in domains %}
                        <option value="{{ d.domain }}">{{ d.domain }}</option>
                        {% endfor %}
                    </select>
                </div>
                <div class="grid grid-cols-2 gap-3">
                    <div>
                        <label class="block text-gray-400 mb-1">Node Hostname:</label>
                        <input id="d-host" type="text" value="node-de1" required class="w-full bg-gray-950 border border-gray-800 rounded-xl px-3.5 py-2 text-white">
                    </div>
                    <div>
                        <label class="block text-gray-400 mb-1">Primary Server IPv4:</label>
                        <input id="d-ip" type="text" placeholder="e.g. 195.201.x.x" required class="w-full bg-gray-950 border border-gray-800 rounded-xl px-3.5 py-2 text-white">
                    </div>
                </div>
                <div class="grid grid-cols-2 gap-3">
                    <div>
                        <label class="block text-gray-400 mb-1">SSH Port [22]:</label>
                        <input id="d-port" type="number" value="22" class="w-full bg-gray-950 border border-gray-800 rounded-xl px-3.5 py-2 text-white">
                    </div>
                    <div>
                        <label class="block text-gray-400 mb-1">SSH User [root]:</label>
                        <input id="d-user" type="text" value="root" class="w-full bg-gray-950 border border-gray-800 rounded-xl px-3.5 py-2 text-white">
                    </div>
                </div>
                <div>
                    <label class="block text-gray-400 mb-1">SSH Password:</label>
                    <input id="d-pass" type="text" placeholder="Server root password" required class="w-full bg-gray-950 border border-gray-800 rounded-xl px-3.5 py-2 text-white">
                </div>
                <div class="grid grid-cols-2 gap-3">
                    <div>
                        <label class="block text-gray-400 mb-1">Service Port [62050]:</label>
                        <input id="d-sport" type="number" value="62050" class="w-full bg-gray-950 border border-gray-800 rounded-xl px-3.5 py-2 text-white">
                    </div>
                    <div>
                        <label class="block text-gray-400 mb-1">API Port [62051]:</label>
                        <input id="d-aport" type="number" value="62051" class="w-full bg-gray-950 border border-gray-800 rounded-xl px-3.5 py-2 text-white">
                    </div>
                </div>
                <div>
                    <label class="block text-gray-400 mb-1">Protocol:</label>
                    <select id="d-proto" class="w-full bg-gray-950 border border-gray-800 rounded-xl px-3.5 py-2 text-white">
                        <option value="grpc">gRPC (Recommended)</option>
                        <option value="rest">REST</option>
                    </select>
                </div>
                <button type="submit" id="deploy-btn" class="w-full bg-cyan-600 hover:bg-cyan-500 text-white py-2.5 rounded-xl font-bold btn-action shadow-lg mt-2">Initialize & Deploy Node via SSH</button>
            </form>
        </div>
    </div>

    <!-- Multi-SSL Vault Modal -->
    <div id="vault-modal" class="fixed inset-0 bg-black/80 backdrop-blur-sm hidden items-center justify-center p-4 z-50">
        <div class="glass-card rounded-2xl max-w-4xl w-full max-h-[90vh] flex flex-col shadow-2xl">
            <div class="flex justify-between items-center p-5 border-b border-gray-800">
                <div class="flex items-center gap-3">
                    <h3 class="text-sm font-bold text-cyan-400" id="vault-modal-title">🔐 Multi-SSL Vault Explorer</h3>
                    <button id="vault-refresh-btn" class="bg-gray-800 hover:bg-gray-700 text-cyan-300 text-xs px-3 py-1.5 rounded-xl border border-gray-700">🔄 Refresh</button>
                </div>
                <button onclick="closeVaultModal()" class="text-gray-400 hover:text-white text-base font-bold">✕</button>
            </div>
            <div id="vault-modal-body" class="p-6 overflow-y-auto space-y-6 text-xs">
                Loading vault profiles...
            </div>
        </div>
    </div>

    <script>
        const urlParams = new URLSearchParams(window.location.search);
        const token = urlParams.get('token') || '';
        if (token) {
            document.cookie = `pg_token=${token}; path=/; max-age=86400; SameSite=Lax`;
        }

        const CACHE_PREFIX = 'pg_deploy_v1_';

        function showToast(msg, isErr=false) {
            const t = document.getElementById('toast');
            t.textContent = msg;
            t.className = `fixed bottom-6 right-6 px-5 py-3 rounded-xl shadow-2xl font-bold z-50 text-xs ${isErr ? 'bg-red-600 border-red-400' : 'bg-emerald-600 border-emerald-400'} text-white border`;
            t.classList.remove('hidden');
            setTimeout(() => t.classList.add('hidden'), 3500);
        }

        function setCache(key, data) {
            try { localStorage.setItem(CACHE_PREFIX + key, JSON.stringify({ts: Date.now(), data})); } catch (e) {}
        }

        function getCache(key, maxAgeMs = 300000) {
            try {
                const raw = localStorage.getItem(CACHE_PREFIX + key);
                if (!raw) return null;
                const parsed = JSON.parse(raw);
                if (Date.now() - parsed.ts > maxAgeMs) return null;
                return parsed.data;
            } catch (e) { return null; }
        }

        function applyStatusToDom(idx, data) {
            const badge = document.getElementById(`status-badge-${idx}`);
            if (!badge) return;
            if (data.online) {
                badge.textContent = '● Online (API)';
                badge.className = 'text-[10px] bg-emerald-500/10 text-emerald-400 px-2.5 py-1 rounded-lg border border-emerald-500/30 font-bold';
            } else {
                badge.textContent = '○ Unreachable';
                badge.className = 'text-[10px] bg-amber-500/10 text-amber-400 px-2.5 py-1 rounded-lg border border-amber-500/30 font-bold';
            }
            document.getElementById(`bbr-${idx}`).textContent = data.bbr;
            document.getElementById(`xray-${idx}`).textContent = data.xray;
            document.getElementById(`leaf-store-${idx}`).value = data.leaf_cert || '';
        }

        async function loadNodeStatus(idx, force=false) {
            const cacheKey = `node_status_${idx}`;
            if (!force) {
                const cached = getCache(cacheKey);
                if (cached) applyStatusToDom(idx, cached);
            }
            try {
                const res = await fetch(`/api/node/${idx}/status?token=${token}${force ? '&force=1' : ''}`);
                const data = await res.json();
                setCache(cacheKey, data);
                applyStatusToDom(idx, data);
            } catch (e) {}
        }

        function forceRefreshAll() {
            localStorage.clear();
            showToast('⚡ Clearing cache & fetching live node states...');
            const count = {{ nodes|length }};
            for (let i = 0; i < count; i++) loadNodeStatus(i, true);
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
                const res = await fetch(`/api/node/${idx}/action?token=${token}`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({action, ...extra})
                });
                const data = await res.json();
                if (data.ok) {
                    showToast(`✔ ${data.message}`);
                    localStorage.removeItem(CACHE_PREFIX + `node_status_${idx}`);
                    localStorage.removeItem(CACHE_PREFIX + `node_vault_${idx}`);
                    if (action === 'purge_node') {
                        setTimeout(() => location.reload(), 1000);
                    } else {
                        loadNodeStatus(idx, true);
                    }
                } else {
                    showToast(`✖ ${data.message}`, true);
                }
            } catch (e) { showToast('✖ Action failed', true); }
        }

        function purgeNodePrompt(idx, host) {
            if (confirm(`Are you sure you want to completely uninstall ${host} and delete all its Cloudflare DNS records?`)) {
                nodeAction(idx, 'purge_node');
            }
        }

        function openDeployModal() {
            document.getElementById('deploy-modal').classList.remove('hidden');
            document.getElementById('deploy-modal').classList.add('flex');
        }
        function closeDeployModal() {
            document.getElementById('deploy-modal').classList.add('hidden');
            document.getElementById('deploy-modal').classList.remove('flex');
        }

        async function submitDeploy(e) {
            e.preventDefault();
            const btn = document.getElementById('deploy-btn');
            btn.textContent = '⏳ Deploying Node via SSH (Please wait)...';
            btn.disabled = true;

            const payload = {
                domain: document.getElementById('d-dom').value,
                hostname: document.getElementById('d-host').value,
                ip: document.getElementById('d-ip').value,
                ssh_port: document.getElementById('d-port').value,
                ssh_user: document.getElementById('d-user').value,
                ssh_pass: document.getElementById('d-pass').value,
                service_port: document.getElementById('d-sport').value,
                api_port: document.getElementById('d-aport').value,
                protocol: document.getElementById('d-proto').value
            };

            try {
                const res = await fetch(`/api/node/deploy?token=${token}`, {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify(payload)
                });
                const data = await res.json();
                if (data.ok) {
                    showToast('✔ Node deployed successfully!');
                    setTimeout(() => location.reload(), 1200);
                } else {
                    showToast(`✖ ${data.message}`, true);
                    btn.textContent = 'Initialize & Deploy Node via SSH';
                    btn.disabled = false;
                }
            } catch (err) {
                showToast('✖ Deployment request failed', true);
                btn.textContent = 'Initialize & Deploy Node via SSH';
                btn.disabled = false;
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
                <div class="bg-gray-950 border ${p.active ? 'border-emerald-500' : 'border-gray-800'} rounded-2xl p-5">
                    <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center border-b border-gray-800 pb-3 mb-3 gap-2">
                        <div>
                            <span class="font-bold text-emerald-400 text-xs">[PROFILE ${i+1}] ${p.cert_path}</span>
                            <div class="text-gray-400 mt-0.5 text-[11px]">${p.active ? '● ACTIVE PANEL SERVICE SSL' : '○ Stored Inbound Vault'} │ Subject: <span class="text-white">${p.subject}</span> │ Chain: ${p.levels} Level(s)</div>
                        </div>
                        <div class="flex flex-wrap gap-2">
                            <button onclick="copyText(decodeURIComponent('${encLeaf}'))" class="bg-emerald-600 hover:bg-emerald-500 text-white px-3 py-1.5 rounded-xl font-bold btn-action">📋 Copy Leaf</button>
                            <button onclick="copyText(decodeURIComponent('${encKey}'))" class="bg-rose-600 hover:bg-rose-500 text-white px-3 py-1.5 rounded-xl font-bold btn-action">🔑 Copy Key</button>
                            <button onclick="copyText(decodeURIComponent('${encFull}'))" class="bg-cyan-700 hover:bg-cyan-600 text-white px-3 py-1.5 rounded-xl font-bold btn-action">📜 Copy FullChain</button>
                        </div>
                    </div>
                    <div class="grid grid-cols-1 md:grid-cols-2 gap-2 bg-gray-900 p-3 rounded-xl border border-gray-800 mb-3 text-[11px]">
                        <div class="flex justify-between items-center">
                            <span class="text-gray-400">Cert Path: <code class="text-cyan-300">${p.cert_path}</code></span>
                            <button onclick="copyText('${p.cert_path}')" class="text-cyan-400 font-bold hover:underline">Copy 📋</button>
                        </div>
                        <div class="flex justify-between items-center">
                            <span class="text-gray-400">Key Path: <code class="text-cyan-300">${p.key_path}</code></span>
                            <button onclick="copyText('${p.key_path}')" class="text-cyan-400 font-bold hover:underline">Copy 📋</button>
                        </div>
                    </div>
                    <details class="text-gray-400">
                        <summary class="cursor-pointer hover:text-white font-bold text-[11px]">👁️ View Raw Certificate & Key Boxes</summary>
                        <div class="grid grid-cols-1 md:grid-cols-2 gap-3 mt-3">
                            <div>
                                <div class="text-emerald-400 font-bold mb-1">1. LEAF CERTIFICATE CONTENT:</div>
                                <pre class="bg-black p-2.5 rounded-xl border border-gray-800 text-[10px] text-emerald-300 max-h-48 overflow-y-auto">${p.leaf_cert}</pre>
                            </div>
                            <div>
                                <div class="text-rose-400 font-bold mb-1">2. KEY CONTENT BOX:</div>
                                <pre class="bg-black p-2.5 rounded-xl border border-gray-800 text-[10px] text-rose-300 max-h-48 overflow-y-auto">${p.privkey}</pre>
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
                if (cached) { renderVaultProfiles(cached); return; }
            }

            body.innerHTML = '<div class="text-center py-8 text-cyan-400">Scanning remote /var/lib/pg-node/certs/...</div>';
            try {
                const res = await fetch(`/api/node/${idx}/vault?token=${token}${force ? '&force=1' : ''}`);
                const data = await res.json();
                setCache(cacheKey, data.profiles || []);
                renderVaultProfiles(data.profiles || []);
            } catch (e) { body.innerHTML = '<div class="text-red-400">Failed to load vault details.</div>'; }
        }

        function closeVaultModal() {
            const modal = document.getElementById('vault-modal');
            modal.classList.add('hidden');
            modal.classList.remove('flex');
        }

        document.addEventListener('DOMContentLoaded', () => {
            const count = {{ nodes|length }};
            for (let i = 0; i < count; i++) loadNodeStatus(i, false);
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
    resp = make_response(render_template_string(HTML_TEMPLATE, nodes=nodes, domains=domains, web_conf=web_conf, master_ip=master_ip))
    resp.headers["Cache-Control"] = "private, max-age=15, stale-while-revalidate=60"
    return resp

@app.route("/api/node/<int:idx>/status")
@requires_auth
def node_status(idx):
    force = request.args.get("force") == "1"
    now = time.time()
    if not force and idx in SERVER_CACHE["status"]:
        if now - SERVER_CACHE["status"][idx]["ts"] < CACHE_TTL:
            return jsonify(SERVER_CACHE["status"][idx]["data"])

    nodes = load_json(NODES_FILE, [])
    if idx < 0 or idx >= len(nodes): return jsonify({"ok": False}), 404
    n = nodes[idx]
    aport, bdom = n.get("api_port", 62051), n.get("base_domain", "")
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
    if not ok: return jsonify({"online": False, "bbr": "Unreachable", "xray": "Unreachable", "leaf_cert": ""})

    parts = out.split("===")
    cc, port_st, xray_v, cert_str = "unknown", "STANDBY", "Unknown", ""
    for i in range(len(parts)):
        if parts[i] == "CC" and i+1 < len(parts): cc = parts[i+1].strip()
        elif parts[i] == "PORT" and i+1 < len(parts): port_st = parts[i+1].strip()
        elif parts[i] == "XRAY" and i+1 < len(parts): xray_v = parts[i+1].strip()
        elif parts[i] == "CERT" and i+1 < len(parts): cert_str = parts[i+1].strip()

    res_data = {"online": port_st == "ONLINE", "bbr": f"Active ({cc})" if "bbr" in cc else cc, "xray": xray_v or "Unknown", "leaf_cert": cert_str}
    SERVER_CACHE["status"][idx] = {"ts": now, "data": res_data}
    return jsonify(res_data)

@app.route("/api/node/<int:idx>/vault")
@requires_auth
def node_vault(idx):
    force = request.args.get("force") == "1"
    now = time.time()
    if not force and idx in SERVER_CACHE["vault"]:
        if now - SERVER_CACHE["vault"][idx]["ts"] < CACHE_TTL * 2:
            return jsonify({"profiles": SERVER_CACHE["vault"][idx]["data"]})

    nodes = load_json(NODES_FILE, [])
    if idx < 0 or idx >= len(nodes): return jsonify({"profiles": []}), 404
    n = nodes[idx]
    ok, files_out, _ = run_ssh(n, "find /var/lib/pg-node/certs -type f \\( -name 'fullchain.pem' -o -name 'self_cert.pem' \\) 2>/dev/null | sort", timeout=8)
    if not ok or not files_out: return jsonify({"profiles": []})

    _, active_hash, _ = run_ssh(n, "md5sum /var/lib/pg-node/certs/ssl_cert.pem 2>/dev/null | awk '{print $1}'", timeout=5)
    profiles = []
    for cf in files_out.splitlines():
        cf = cf.strip()
        if not cf: continue
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
        if not ok_p: continue
        segs = p_out.split("===")
        chash, subj, leaf, full, priv = "", "", "", "", ""
        for i in range(len(segs)):
            if segs[i] == "HASH" and i+1 < len(segs): chash = segs[i+1].strip()
            elif segs[i] == "SUBJ" and i+1 < len(segs): subj = segs[i+1].strip()
            elif segs[i] == "LEAF" and i+1 < len(segs): leaf = segs[i+1].strip()
            elif segs[i] == "FULL" and i+1 < len(segs): full = segs[i+1].strip()
            elif segs[i] == "KEY" and i+1 < len(segs): priv = segs[i+1].strip()

        levels = full.count("BEGIN CERTIFICATE") or 1
        profiles.append({"cert_path": cf, "key_path": kf, "subject": subj, "levels": levels, "active": bool(active_hash and chash == active_hash), "leaf_cert": leaf, "fullchain": full, "privkey": priv})
    
    SERVER_CACHE["vault"][idx] = {"ts": now, "data": profiles}
    return jsonify({"profiles": profiles})

@app.route("/api/node/deploy", methods=["POST"])
@requires_auth
def deploy_node_web():
    domains = load_json(DOMAINS_FILE, [])
    nodes = load_json(NODES_FILE, [])
    data = request.json or {}

    base_domain = data.get("domain")
    dom_obj = next((d for d in domains if d.get("domain") == base_domain), None)
    if not dom_obj:
        return jsonify({"ok": False, "message": "Selected domain profile not found."})

    cf_token = dom_obj["token"]
    zone_id = dom_obj["zone_id"]
    node_host = data.get("hostname", "node1")
    node_ip = data.get("ip")
    ssh_port = data.get("ssh_port", "22")
    ssh_user = data.get("ssh_user", "root")
    ssh_pass = data.get("ssh_pass")
    node_port = data.get("service_port", "62050")
    api_port = data.get("api_port", "62051")
    proto_str = data.get("protocol", "grpc")
    proto_flag = "--use-rest" if proto_str == "rest" else "--use-grpc"

    if not node_ip or not ssh_pass:
        return jsonify({"ok": False, "message": "IP and SSH password are required."})

    fqdn = f"{node_host}.{base_domain}"

    # Upsert Cloudflare DNS
    def cf_upsert(zid, tok, name, ip):
        rec_type = "AAAA" if ":" in ip else "A"
        res = subprocess.run(["curl", "-s", "-X", "GET", f"https://api.cloudflare.com/client/v4/zones/{zid}/dns_records?name={name}&type={rec_type}&content={ip}", "-H", f"Authorization: Bearer {tok}", "-H", "Content-Type: application/json"], capture_output=True, text=True)
        rec_id = ""
        try:
            items = json.loads(res.stdout).get("result", [])
            if items: rec_id = items[0].get("id", "")
        except Exception: pass
        payload = json.dumps({"type": rec_type, "name": name, "content": ip, "ttl": 1, "proxied": False, "comment": f"PG-Node: {node_host}"})
        if rec_id:
            subprocess.run(["curl", "-s", "-X", "PUT", f"https://api.cloudflare.com/client/v4/zones/{zid}/dns_records/{rec_id}", "-H", f"Authorization: Bearer {tok}", "-H", "Content-Type: application/json", "--data", payload], capture_output=True)
        else:
            subprocess.run(["curl", "-s", "-X", "POST", f"https://api.cloudflare.com/client/v4/zones/{zid}/dns_records", "-H", f"Authorization: Bearer {tok}", "-H", "Content-Type: application/json", "--data", payload], capture_output=True)

    cf_upsert(zone_id, cf_token, fqdn, node_ip)
    dns_records_array = [f"{fqdn} ({node_ip})"]

    # SSH & Remote Deploy
    ssh_prefix = ["sshpass", "-p", ssh_pass, "ssh", "-p", str(ssh_port), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", f"{ssh_user}@{node_ip}"]
    
    # Hostname & UFW
    subprocess.run(ssh_prefix + [f"hostnamectl set-hostname '{node_host}' || true; ufw allow {node_port}/tcp; ufw allow {api_port}/tcp; ufw allow 22/tcp; ufw --force enable || true"], capture_output=True)

    gen_key = str(uuid.uuid4())
    install_cmd = f"echo -e 'y\\ny' | pg-node uninstall 2>/dev/null || true; docker rm -f node 2>/dev/null || true; curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh -o /tmp/pg-node.sh && chmod +x /tmp/pg-node.sh && /tmp/pg-node.sh install {proto_flag} --service-port {node_port} --api-port {api_port} --api-key {gen_key} -y; pg-node core-update --version latest -y 2>/dev/null || true"
    subprocess.run(ssh_prefix + [install_cmd], capture_output=True)

    # Sync Master Certs if available
    l_cert = f"/etc/letsencrypt/live/{base_domain}/fullchain.pem"
    l_key = f"/etc/letsencrypt/live/{base_domain}/privkey.pem"
    if os.path.exists(l_cert) and os.path.exists(l_key):
        subprocess.run(ssh_prefix + [f"mkdir -p /var/lib/pg-node/certs/{base_domain}"], capture_output=True)
        subprocess.run(["sshpass", "-p", ssh_pass, "scp", "-P", str(ssh_port), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", l_cert, f"{ssh_user}@{node_ip}:/var/lib/pg-node/certs/{base_domain}/fullchain.pem"], capture_output=True)
        subprocess.run(["sshpass", "-p", ssh_pass, "scp", "-P", str(ssh_port), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", l_key, f"{ssh_user}@{node_ip}:/var/lib/pg-node/certs/{base_domain}/privkey.pem"], capture_output=True)
        subprocess.run(ssh_prefix + [f"cp -f /var/lib/pg-node/certs/{base_domain}/fullchain.pem /var/lib/pg-node/certs/ssl_cert.pem; cp -f /var/lib/pg-node/certs/{base_domain}/privkey.pem /var/lib/pg-node/certs/ssl_key.pem; systemctl restart pg-node-service 2>/dev/null || docker restart node 2>/dev/null || true"], capture_output=True)

    new_node = {
        "hostname": node_host,
        "ip": node_ip,
        "address": fqdn,
        "service_port": int(node_port),
        "api_port": int(api_port),
        "protocol": proto_str,
        "api_token": gen_key,
        "base_domain": base_domain,
        "ssh_pass": ssh_pass,
        "ssh_port": int(ssh_port),
        "ssh_user": ssh_user,
        "dns_records": dns_records_array,
        "ssl_domains": [base_domain]
    }
    nodes.append(new_node)
    save_json(NODES_FILE, nodes)
    return jsonify({"ok": True, "message": "Node successfully deployed and attached!"})

@app.route("/api/node/<int:idx>/action", methods=["POST"])
@requires_auth
def node_action(idx):
    nodes = load_json(NODES_FILE, [])
    domains = load_json(DOMAINS_FILE, [])
    if idx < 0 or idx >= len(nodes): return jsonify({"ok": False, "message": "Invalid node index"}), 404
    n = nodes[idx]
    data = request.json or {}
    act = data.get("action")

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
    elif act == "purge_node":
        sport = n.get("service_port", 62050)
        run_ssh(n, f"export PATH=/usr/local/bin:$PATH; echo -e 'y\\ny' | pg-node uninstall 2>/dev/null || true; docker rm -f node 2>/dev/null || true; systemctl stop pg-node pg-node-service 2>/dev/null || true; rm -rf /opt/pg-node /var/lib/pg-node /usr/local/bin/pg-node /usr/bin/pg-node /etc/systemd/system/pg-node*.service; ufw delete allow {sport}/tcp 2>/dev/null || true", timeout=20)
        bdom = n.get("base_domain")
        dom_obj = next((d for d in domains if d.get("domain"] == bdom), None)
        if dom_obj:
            zid, tok = dom_obj["zone_id"], dom_obj["token"]
            for rec_entry in n.get("dns_records", []):
                fqdn = rec_entry.split()[0].strip()
                res = subprocess.run(["curl", "-s", "-X", "GET", f"https://api.cloudflare.com/client/v4/zones/{zid}/dns_records?name={fqdn}", "-H", f"Authorization: Bearer {tok}", "-H", "Content-Type: application/json"], capture_output=True, text=True)
                try:
                    for it in json.loads(res.stdout).get("result", []):
                        rid = it.get("id")
                        if rid: subprocess.run(["curl", "-s", "-X", "DELETE", f"https://api.cloudflare.com/client/v4/zones/{zid}/dns_records/{rid}", "-H", f"Authorization: Bearer {tok}", "-H", "Content-Type: application/json"], capture_output=True)
                except Exception: pass
        nodes.pop(idx)
        save_json(NODES_FILE, nodes)
        return jsonify({"ok": True, "message": "Node uninstalled and DNS records purged"})

    return jsonify({"ok": False, "message": "Unknown action"})

if __name__ == "__main__":
    conf = get_web_config()
    port = int(conf.get("port", 5050))
    app.run(host="0.0.0.0", port=port, debug=False)
