#!/bin/bash
# xray-az: direct и proton при рабочем IPv6 предпочитают IPv6 (UseIPv6v4); Meta/Instagram и Anthropic/Claude всегда по IPv4
# (и напрямую, и через Proton). Если нативный IPv6 узла получает 403 от Gemini - эти домены в direct тоже идут по IPv4.
set -u
CFG=/opt/xray-az/config.json
cp -a "$CFG" "$CFG.bak-fix2-$(date +%s)"
python3 - "$CFG" <<'PY'
import copy, json, subprocess, sys
p = sys.argv[1]
c = json.load(open(p))
DOM = ["domain:instagram.com", "domain:cdninstagram.com", "domain:fbcdn.net", "domain:facebook.com",
       "domain:anthropic.com", "domain:claude.ai", "domain:claude.com"]
GEMINI = ["domain:gemini.google.com", "domain:aistudio.google.com", "domain:generativelanguage.googleapis.com",
          "domain:alkalimakersuite-pa.clients6.google.com", "domain:makersuite.google.com"]

def curl_code(url, fam):
    r = subprocess.run(["curl", "-" + fam, "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "10", url], capture_output=True, text=True)
    return r.stdout.strip() or "000"

native6 = curl_code("https://www.google.com/", "6") == "200"
gemini_v6_blocked = native6 and curl_code("https://gemini.google.com/app", "6") == "403"
outs = c["outbounds"]
direct = next(o for o in outs if o.get("tag") == "direct")
direct.setdefault("settings", {})["domainStrategy"] = "UseIPv6v4" if native6 else "UseIPv4"
outs[:] = [o for o in outs if o.get("tag") not in ("direct-v4", "proton-v4")]
d4 = copy.deepcopy(direct)
d4["tag"] = "direct-v4"
d4["settings"]["domainStrategy"] = "UseIPv4"
outs.append(d4)
prot = next(o for o in outs if o.get("tag") == "proton")
v4 = copy.deepcopy(prot)
v4["tag"] = "proton-v4"
v4.setdefault("settings", {})["domainStrategy"] = "UseIPv4"
outs.append(v4)
# mihomo (sniffer без override-destination, dns normal) отдаёт на узел чистый IP: домен видим только для роутинга (routeOnly),
# стек пакета (IPv4/IPv6) сохраняется
for i in c["inbounds"]:
    if i.get("tag") in ("in-direct", "in-proton"):
        i["sniffing"] = {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": True}
    elif i.get("tag") == "in-direct2":   # дополнительный вход (QUIC): без routeOnly xray сам резолвит домен и IPv4-запрос уходит по IPv6 (FR1, 14.11)
        i.setdefault("sniffing", {"enabled": True, "destOverride": ["http", "tls", "quic"]})["routeOnly"] = True
rules = c["routing"]["rules"]
rules[:] = [r for r in rules if r.get("outboundTag") not in ("proton-v4", "direct-v4") or "domain" not in r]
# Meta/Anthropic по IPv6-адресу (mihomo отдаёт чистый IP): сбрасываем, клиент сразу переходит на IPv4
if not any(o.get("tag") == "block" for o in outs):
    outs.append({"tag": "block", "protocol": "blackhole"})
rules[:] = [r for r in rules if not (r.get("outboundTag") == "block" and r.get("ip") == ["::/0"])]
rules.insert(0, {"type": "field", "inboundTag": ["in-proton"], "domain": DOM, "outboundTag": "proton-v4"})
rules.insert(1, {"type": "field", "inboundTag": ["in-direct"], "domain": DOM + (GEMINI if gemini_v6_blocked else []), "outboundTag": "direct-v4"})
rules.insert(0, {"type": "field", "inboundTag": ["in-direct", "in-proton"], "domain": DOM, "ip": ["::/0"], "outboundTag": "block"})
# режим «Приоритет IPv6» (mihomo): дополнительные входы с routeOnly=false - xray по sniffнутому SNI сам резолвит домен (UseIPv6v4),
# поэтому IPv4-запрос Dual-Stack сайта уходит по IPv6, а сайты без AAAA (github) остаются на IPv4
for src_tags, new_tag, port in ((("in-direct2", "in-direct"), "in-direct-v6", 8449), (("in-proton",), "in-proton-v6", 8450)):
    src = next((i for t in src_tags for i in c["inbounds"] if i.get("tag") == t), None)
    if not src or any(i.get("tag") == new_tag for i in c["inbounds"]) or any(i.get("port") == port for i in c["inbounds"]):
        continue
    n = copy.deepcopy(src)
    n["tag"], n["port"] = new_tag, port
    n["sniffing"] = {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": False}
    c["inbounds"].append(n)
for r in rules:
    tg = r.get("inboundTag", [])
    for old, new in (("in-direct", "in-direct-v6"), ("in-direct2", "in-direct-v6"), ("in-proton", "in-proton-v6")):
        if old in tg and new not in tg and any(i.get("tag") == new for i in c["inbounds"]):
            tg.append(new)
json.dump(c, open(p, "w"), indent=2, ensure_ascii=False)
print("native6=%s gemini_v6_blocked=%s" % (native6, gemini_v6_blocked))
PY
/opt/xray-az/xray run -test -config "$CFG" >/dev/null 2>&1 && echo FIX2_OK || { echo XRAY_TEST_FAIL; cp -a "$(ls -t $CFG.bak-fix2-* | head -1)" "$CFG"; exit 1; }
