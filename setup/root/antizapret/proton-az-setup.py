#!/usr/bin/env python3
"""Proton-туннель АнтиЗапрета (az) или полного VPN (vpn): свой ключ, запись в setup, режим 2. Перезапуск antizapret - снаружи."""
import json, re, subprocess, sys, urllib.request
kind = sys.argv[1]
iface, pre, mode = {"az": ("warp-antizapret", "PROTON_ANTIZAPRET", "ANTIZAPRET_WARP"), "vpn": ("warp-vpn", "PROTON_VPN", "VPN_WARP")}[kind]
sh = lambda *a: subprocess.run(a, capture_output=True, text=True)
cfg = dict(l.strip().split("=", 1) for l in open("/etc/proton-pick.conf") if "=" in l and not l.startswith("#"))
ep = sh("wg", "show", "proton", "endpoints").stdout.split()[-1].rsplit(":", 1)[0]
req = urllib.request.Request(cfg["REKEY_URL"], data=json.dumps({"iface": iface, "entry_ip": ep}).encode(),
                             headers={"X-Rekey-Token": cfg["REKEY_TOKEN"], "Content-Type": "application/json"})
k = json.load(urllib.request.urlopen(req, timeout=170))
S = "/root/antizapret/setup"; t = open(S).read()
for key, val in {"WARP_PROVIDER": "proton", mode: "2", pre + "_PRIVATE_KEY": k["private_key"], pre + "_PUBLIC_KEY": k["public_key"],
                 pre + "_ADDRESS": "10.2.0.2", pre + "_ENDPOINT_HOST": k["entry_ip"], pre + "_ENDPOINT_PORT": k["port"]}.items():
    t = re.sub(rf"^{key}=.*$", f"{key}={val}", t, flags=re.M) if re.search(rf"^{key}=", t, re.M) else t.rstrip("\n") + f"\n{key}={val}\n"
open(S, "w").write(t)
print(kind, k["server"], k["device"], k["entry_ip"])
json.dump({"iface": iface, "entry_ip": k["entry_ip"], "device": k["device"]}, open(f"/tmp/azsetup-{kind}.json", "w"))
