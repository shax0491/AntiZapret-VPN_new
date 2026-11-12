#!/bin/bash
# xray-az: прямой выход только IPv4; Meta/Instagram и Anthropic/Claude всегда по IPv4 (и напрямую, и через Proton)
set -u
CFG=/opt/xray-az/config.json
cp -a "$CFG" "$CFG.bak-fix2-$(date +%s)"
python3 - "$CFG" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
DOM = ["domain:instagram.com", "domain:cdninstagram.com", "domain:fbcdn.net", "domain:facebook.com",
       "domain:anthropic.com", "domain:claude.ai", "domain:claude.com"]
outs = c["outbounds"]
for o in outs:
    if o.get("tag") == "direct":
        o.setdefault("settings", {})["domainStrategy"] = "UseIPv4"
prot = next(o for o in outs if o.get("tag") == "proton")
if not any(o.get("tag") == "proton-v4" for o in outs):
    v4 = json.loads(json.dumps(prot))
    v4["tag"] = "proton-v4"
    v4.setdefault("settings", {})["domainStrategy"] = "UseIPv4"
    outs.append(v4)
rules = c["routing"]["rules"]
rules[:] = [r for r in rules if r.get("outboundTag") not in ("proton-v4", "direct-v4") or "domain" not in r]
rules.insert(0, {"type": "field", "inboundTag": ["in-proton"], "domain": DOM, "outboundTag": "proton-v4"})
rules.insert(1, {"type": "field", "inboundTag": ["in-direct"], "domain": DOM, "outboundTag": "direct"})
json.dump(c, open(p, "w"), indent=2, ensure_ascii=False)
PY
/opt/xray-az/xray run -test -config "$CFG" >/dev/null 2>&1 && echo FIX2_OK || { echo XRAY_TEST_FAIL; cp -a "$(ls -t $CFG.bak-fix2-* | head -1)" "$CFG"; exit 1; }
