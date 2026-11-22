#!/usr/bin/env python3
# Перевод Proton-туннеля узла (proton|proton-hy) на сервер страны с «правильным» IPv6/IPv4 для Google/YouTube: python3 proton-geo-move.py IFACE СТРАНА [ПРЕФИКС_ВХОДА]; автооткат, если handshake или гео не совпали
import importlib.util, sys, time, subprocess, re
iface, country = sys.argv[1], sys.argv[2]
prefix = sys.argv[3] if len(sys.argv) > 3 else ""
spec = importlib.util.spec_from_file_location("pp", "/root/antizapret/proton-pick.py"); pp = importlib.util.module_from_spec(spec); spec.loader.exec_module(pp)
cfg = pp.read_kv("/etc/proton-pick.conf"); st = pp.load_state()
servers = pp.server_list(cfg, st)
cur = pp.peer(iface); assert cur, "нет пира"
def v6geo():
    c = subprocess.run(["curl", "-6", "-s", "-m", "10", "--interface", iface, "https://ifconfig.co/country-iso"], capture_output=True, text=True).stdout.strip()
    y = subprocess.run("curl -6 -s -m 12 --interface %s -H 'Accept-Language: en' https://www.youtube.com/ | grep -o '\"GL\":\"[A-Z]*\"' | head -1" % iface, shell=True, capture_output=True, text=True).stdout
    m = re.search(r'"GL":"([A-Z]*)"', y)
    return c, (m.group(1) if m else "")
print("до:", cur["ip"], v6geo())
ranked = [c for c in pp.candidates(servers, cfg, st, country) if c[3]["entry_ip"] != cur["ip"] and (not prefix or c[3]["entry_ip"].startswith(prefix))]
print("кандидатов:", len(ranked))
for _, rtt, s, ep in ranked[:3]:
    k, err = pp.request_key(cfg, {"iface": iface, "entry_ip": cur["ip"], "server": s["name"], "why": "нужен IPv6: гео-страна", "repick": True})
    if not k: print("ключ не выдан:", err); continue
    old_priv = pp.run(["wg", "show", iface, "private-key"]).stdout.strip()
    pp.set_private_key(iface, k["private_key"]); pp.set_peer(iface, k["public_key"], k["entry_ip"], k["port"], cur["allowed"], cur["pub"])
    good = pp.settle(iface, k["public_key"], 30); time.sleep(3)
    c, y = v6geo() if good else ("", "")
    print("пробую", s["name"], k["entry_ip"], "handshake", good, "v6 страна", c, "YouTube", y)
    if good and c == country and y == country:
        pp.persist_private_key(iface, k["private_key"]); pp.persist(iface, s, {"public_key": k["public_key"], "entry_ip": k["entry_ip"]}, k["port"])
        p = pp.peer(iface)
        if p: pp.sync_setup(iface, p)
        pp.confirm(cfg, iface, k["entry_ip"], k, True); print("ОК, оставлен", s["name"]); sys.exit(0)
    if old_priv: pp.set_private_key(iface, old_priv)
    pp.set_peer(iface, cur["pub"], cur["ip"], cur["port"], cur["allowed"], k["public_key"]); pp.settle(iface, cur["pub"], 20)
    pp.confirm(cfg, iface, cur["ip"], k, False); print("откат на прежний")
print("не нашёл подходящий"); sys.exit(1)
