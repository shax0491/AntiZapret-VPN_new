#!/bin/bash
# Dual-stack для xray-az (VLESS-Proton): выход строго через интерфейс proton + killswitch по метке 0x51.
# Использование: xray_v6.sh <1|0>   (1 — IPv6 внутри proton рабочий, 0 — только IPv4 + killswitch)
set -u
V6OK="${1:-0}"
CFG=/opt/xray-az/config.json
PC=/etc/wireguard/proton.conf
TS=$(date +%s)
cp -a "$CFG" "$CFG.bak-v6dual-$TS"
cp -a "$PC" "$PC.bak-v6dual-$TS"

python3 - "$CFG" "$V6OK" <<'PY'
import json, sys
p, ok = sys.argv[1], sys.argv[2] == "1"
c = json.load(open(p))
for o in c["outbounds"]:
    if o.get("tag") == "proton":
        o.setdefault("settings", {})["domainStrategy"] = "UseIPv4v6" if ok else "UseIPv4"
        so = o.setdefault("streamSettings", {}).setdefault("sockopt", {})
        so["interface"] = "proton"
        so["mark"] = 81
json.dump(c, open(p, "w"), indent=2, ensure_ascii=False)
PY

if [ "$V6OK" = 1 ] && ! grep -q '2a07:b944::2:2' "$PC"; then
  sed -i -e 's#^Address = 10.2.0.2/32#Address = 10.2.0.2/32, 2a07:b944::2:2/128#' \
         -e 's#^AllowedIPs = 0.0.0.0/0$#AllowedIPs = 0.0.0.0/0, ::/0#' \
         -e 's#^\(PostUp = .*\)$#\1; ip -6 route replace default dev proton table 51820; ip -6 rule add oif proton lookup 51820 pref 1000#' \
         -e 's#^\(PostDown = .*\)$#\1; ip -6 rule del oif proton lookup 51820 pref 1000; ip -6 route flush table 51820#' "$PC"
fi
if [ "$V6OK" = 1 ]; then
  ip -6 addr replace 2a07:b944::2:2/128 dev proton 2>/dev/null
  ip -6 route replace default dev proton table 51820
  ip -6 rule show | grep -q 'oif proton lookup 51820' || ip -6 rule add oif proton lookup 51820 pref 1000
fi

# killswitch: сокеты xray с меткой 0x51 не могут выйти никуда, кроме proton
for t in iptables ip6tables; do
  $t -w -C OUTPUT -m mark --mark 0x51 ! -o proton -j DROP 2>/dev/null || $t -w -I OUTPUT 1 -m mark --mark 0x51 ! -o proton -j DROP
done

/opt/xray-az/xray run -test -config "$CFG" >/dev/null 2>&1 || { echo "XRAY_TEST_FAIL, откат"; cp -a "$CFG.bak-v6dual-$TS" "$CFG"; exit 1; }
echo PATCH_OK
