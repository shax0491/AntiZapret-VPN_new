#!/usr/bin/env python3
"""Hysteria2 через Proton: интерфейс proton-hy (свой ключ) + второй экземпляр hysteria на порту HY_PORT, выход через proton-hy."""
import json, os, re, subprocess, sys, urllib.request, shutil
HY_PORT = int(os.environ.get("HY_PORT", "8444"))
def sh(*a, **k): return subprocess.run(a, capture_output=True, text=True, **k)
cfg = dict(l.strip().split("=", 1) for l in open("/etc/proton-pick.conf") if "=" in l and not l.startswith("#"))
W = "/etc/wireguard/proton-hy.conf"
if not os.path.exists(W):
    ep = sh("wg", "show", "proton", "endpoints").stdout.split()[-1].rsplit(":", 1)[0]
    req = urllib.request.Request(cfg["REKEY_URL"], data=json.dumps({"iface": "proton-hy", "entry_ip": ep}).encode(),
                                 headers={"X-Rekey-Token": cfg["REKEY_TOKEN"], "Content-Type": "application/json"})
    k = json.load(urllib.request.urlopen(req, timeout=170))
    open(W, "w").write(f"""# Proton VPN {k['server']} - отдельный ключ Hysteria2 (выход hysteria-proton через интерфейс proton-hy)
[Interface]
PrivateKey = {k['private_key']}
Address = 10.2.0.2/32, 2a07:b944::2:2/128
MTU = 1280
Table = off
PostUp = ip route replace default dev proton-hy table 51821; ip rule add oif proton-hy lookup 51821 pref 1001; ip -6 route replace default dev proton-hy table 51821; ip -6 rule add oif proton-hy lookup 51821 pref 1001
PostDown = ip rule del oif proton-hy lookup 51821 pref 1001; ip route flush table 51821; ip -6 rule del oif proton-hy lookup 51821 pref 1001; ip -6 route flush table 51821

[Peer]
PublicKey = {k['public_key']}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {k['entry_ip']}:{k['port']}
PersistentKeepalive = 25
""")
    os.chmod(W, 0o600)
    sh("systemctl", "enable", "--now", "wg-quick@proton-hy")
    print("ключ", k["server"], k["device"])
    c = urllib.request.Request(cfg["REKEY_URL"], data=json.dumps({"iface": "proton-hy", "entry_ip": k["entry_ip"], "confirm": k["device"], "ok": True}).encode(),
                               headers={"X-Rekey-Token": cfg["REKEY_TOKEN"], "Content-Type": "application/json"})
    urllib.request.urlopen(c, timeout=60).read()
y = open("/etc/hysteria/config.yaml").read()
y = re.sub(r"^listen: .*$", f"listen: :{HY_PORT}", y, flags=re.M)
y = y.replace("    - direct(all)", "    - proton(all)")
y += "\noutbounds:\n  - name: proton\n    type: direct\n    direct:\n      mode: auto\n      bindDevice: proton-hy\n"
open("/etc/hysteria/config-proton.yaml", "w").write(y)
os.chmod("/etc/hysteria/config-proton.yaml", 0o640); shutil.chown("/etc/hysteria/config-proton.yaml", group="hysteria")
u = open("/etc/systemd/system/hysteria-server.service").read()
u = u.replace("config.yaml", "config-proton.yaml").replace("Hysteria2 server (", "Hysteria2 server через Proton (").replace("NoNewPrivileges=true", "NoNewPrivileges=true\nAmbientCapabilities=CAP_NET_RAW\nCapabilityBoundingSet=CAP_NET_RAW")
open("/etc/systemd/system/hysteria-proton.service", "w").write(u)
sh("systemctl", "daemon-reload"); sh("systemctl", "enable", "--now", "hysteria-proton")
import time; time.sleep(3)
print("wg:", sh("wg", "show", "proton-hy").stdout.replace("\n", " | ")[-260:])
print("hy:", sh("systemctl", "is-active", "hysteria-proton").stdout.strip(), sh("ss", "-ulnp").stdout.count(f":{HY_PORT} "))
