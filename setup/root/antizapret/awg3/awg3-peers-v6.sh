#!/bin/bash
# Существующим пирам awg1 (AWG 3.0) добавляет IPv6-адрес в AllowedIPs: 10.9.0.N -> fd29:7::N/128, 10.9.1.N -> fd28:7::N/128 (N в hex, как в панели); пирам 10.9.0.N ещё и fd29:7:N::/64.
# Нужен для Dual-Stack: без этого сервер не маршрутизирует ответы на fd29:7::N обратно в туннель. Применяется и в awg1.conf, и на живом интерфейсе.
set -eu
python3 - <<'PY'
import re, subprocess
F = "/etc/amnezia/amneziawg3/awg1.conf"
s = open(F).read(); out = []; n = 0
for b in re.split(r"(?m)^(?=\[Peer\])", s):
    k = re.search(r"(?m)^PublicKey\s*=\s*(\S+)", b); a = re.search(r"(?m)^AllowedIPs\s*=\s*(.+)$", b)
    if k and a:
        ips = [x.strip() for x in a.group(1).split(",")]
        add = None
        for x in ips:
            m = re.fullmatch(r"10\.9\.([01])\.(\d+)/32", x)
            if m:
                add = ["fd%s:7::%x/128" % ("29" if m.group(1) == "0" else "28", int(m.group(2)))]
                if m.group(1) == "0":  # персональный /64 для LAN за роутером (Netcraze: «IPv6-префикс /64»): fd29:7:N::/64
                    add.append("fd29:7:%x::/64" % int(m.group(2)))
        missing = [x for x in (add or []) if x not in ips]
        if missing:
            ips.extend(missing)
            b = b.replace(a.group(0), "AllowedIPs = " + ", ".join(ips)); n += 1
            subprocess.run(["awg", "set", "awg1", "peer", k.group(1), "allowed-ips", ",".join(ips)], check=True)
    out.append(b)
open(F, "w").write("".join(out)); print("peers updated:", n)
PY
