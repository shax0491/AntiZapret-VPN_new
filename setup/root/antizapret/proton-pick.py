#!/usr/bin/env python3
"""Автоподбор сервера Proton VPN для WireGuard-туннелей узла.

Ключ Proton (PrivateKey из профиля) действует на любом сервере Proton, поэтому для смены
сервера достаточно поменять у пира PublicKey и Endpoint. Скрипт:
  - раз в 30 минут (таймер) проверяет каждый Proton-туннель: свежий handshake, открывается
    https-сайт, а раз в 6 часов ещё и страну выхода глазами YouTube/Cloudflare (Google считает
    часть адресов Proton российскими - тогда YouTube на узле "RU");
  - при поломке или раз в 6 часов берёт список серверов (его публикует DE3), оставляет страну
    VPS (затем соседние), меряет пинг до входных адресов и выбирает лучший по пингу и нагрузке;
  - переключает живой интерфейс (wg set), проверяет новый выход и при неудаче откатывает;
  - сохраняет выбор в /etc/wireguard/<iface>.conf и в /root/antizapret/setup (PROTON_*),
    чтобы перезапуск антизапрета и ночное переподключение WARP поднимали тот же сервер.

Туннели: warp-antizapret и warp-vpn (AntiZapret с WARP_PROVIDER=proton) или proton
(узлы только с VLESS). Через тот же интерфейс ходит и xray-вариант «VLESS Proton».

Настройки (необязательно): /etc/proton-pick.conf, строки KEY=VALUE:
  COUNTRIES=DE,NL        страны по порядку (по умолчанию страна VPS и соседние)
  TIERS=Plus             уровни серверов (Plus, Free; через запятую)
  LIST_URL=https://...   откуда брать список серверов
  INTERFACES=warp-vpn    какие туннели обслуживать (по умолчанию все найденные)

Запуск: proton-pick.py [--force] [--dry-run] [--install] [--status]
"""
from __future__ import annotations

import argparse
import concurrent.futures
import fcntl
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

LIST_URL = "https://<your-server>/lists/<secret>/proton-servers.json"
CONF = "/etc/proton-pick.conf"
STATE_DIR = "/var/lib/proton-pick"
STATE = STATE_DIR + "/state.json"
SETUP = "/root/antizapret/setup"
SETUP_PREFIX = {"warp-antizapret": "PROTON_ANTIZAPRET", "warp-vpn": "PROTON_VPN"}
OPTIMIZE_EVERY = 6 * 3600      # полный пересмотр выбора
GEO_EVERY = 6 * 3600           # проверка страны выхода у работающего туннеля
BAD_EXIT_TTL = 7 * 86400       # адрес выхода, который Google считает российским, не берём неделю
BAD_GEO = {"RU", "BY"}
CANDIDATES = 6                 # сколько лучших по пингу пробовать при переключении
MAX_COUNTRIES = 3              # своя страна и две соседние
FAIL_BACKOFF = 2 * 3600        # после неудачного подбора следующий не раньше чем через 2 часа
# Соседние страны: если в своей стране нет рабочего сервера Proton
NEIGHBORS = {
    "DE": ["DE", "NL", "AT", "CH", "PL", "CZ", "DK"],
    "NL": ["NL", "DE", "BE", "LU", "GB"],
    "FI": ["FI", "SE", "EE", "NO", "DK"],
    "LV": ["LV", "LT", "EE", "FI", "PL", "SE"],
    "FR": ["FR", "BE", "CH", "LU", "DE"],
    "PL": ["PL", "CZ", "DE", "LT"],
}
UNIT = """[Unit]
Description=Proton VPN server auto-pick (proton-pick)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 {exe}
TimeoutStartSec=900
"""
TIMER = """[Unit]
Description=Proton VPN server check every 30 minutes (proton-pick)

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
"""


def log(msg: str) -> None:
    print(time.strftime("%F %T"), msg, flush=True)


def run(cmd: list[str], timeout: float = 20) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def read_kv(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"^\s*([A-Z0-9_]+)=(.*?)\s*$", line)
                if m:
                    out[m.group(1)] = m.group(2).strip().strip("'\"")
    except OSError:
        pass
    return out


def load_state() -> dict:
    try:
        with open(STATE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(st: dict) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=1)
    os.replace(tmp, STATE)


# ── Туннели ────────────────────────────────────────────────────

def interfaces(cfg: dict[str, str]) -> list[str]:
    if cfg.get("INTERFACES"):
        names = [x.strip() for x in cfg["INTERFACES"].split(",") if x.strip()]
    else:
        names = []
        if os.path.exists("/etc/wireguard/proton.conf"):
            names.append("proton")
        setup = read_kv(SETUP)
        if setup.get("WARP_PROVIDER") == "proton":
            if setup.get("ANTIZAPRET_WARP", "1") != "1":
                names.append("warp-antizapret")
            if setup.get("VPN_WARP", "1") != "1":
                names.append("warp-vpn")
    return [n for n in names if os.path.exists(f"/etc/wireguard/{n}.conf") and
            run(["ip", "link", "show", "dev", n]).returncode == 0]


def peer(iface: str) -> dict | None:
    """Текущий (единственный) пир: ключ, адрес входа, AllowedIPs, возраст handshake."""
    r = run(["wg", "show", iface, "dump"])
    lines = r.stdout.strip().splitlines()[1:] if r.returncode == 0 else []
    if not lines:
        return None
    f = lines[0].split("\t")
    hs = int(f[4]) if f[4].isdigit() else 0
    return {"pub": f[0], "endpoint": f[2], "ip": f[2].rsplit(":", 1)[0], "port": f[2].rsplit(":", 1)[-1],
            "allowed": f[3], "hs_age": int(time.time()) - hs if hs else 10 ** 9}


def curl(iface: str | None, url: str, timeout: int = 10, body: bool = True) -> tuple[int, str]:
    cmd = ["curl", "-s", "-m", str(timeout), "-A", "Mozilla/5.0 (X11; Linux x86_64) Chrome/130.0 Safari/537.36",
           "-H", "Accept-Language: en-US,en;q=0.8", "-w", "\n%{http_code}"]
    if iface:
        cmd += ["--interface", iface]
    if not body:
        cmd += ["-o", "/dev/null"]
    try:
        r = run(cmd + [url], timeout=timeout + 5)
    except subprocess.TimeoutExpired:
        return 0, ""
    text, _, code = r.stdout.rpartition("\n")
    return (int(code) if code.isdigit() else 0), text


def healthy(iface: str) -> bool:
    for _ in range(2):
        code, _ = curl(iface, "https://www.gstatic.com/generate_204", 8, body=False)
        if code == 204:
            return True
    return False


def geo(iface: str) -> dict:
    """Страна выхода: Cloudflare (loc) и YouTube (GL, его видит Google)."""
    out = {"cf": "", "yt": "", "ip": ""}
    code, text = curl(iface, "https://www.cloudflare.com/cdn-cgi/trace", 8)
    for line in text.splitlines():
        if line.startswith("loc="):
            out["cf"] = line[4:]
        elif line.startswith("ip="):
            out["ip"] = line[3:]
    code, text = curl(iface, "https://www.youtube.com/", 15)
    m = re.search(r'"GL":"([A-Z]{2})"', text)
    out["yt"] = m.group(1) if m else ""
    return out


def geo_ok(g: dict) -> bool:
    return bool(g["cf"]) and g["cf"] not in BAD_GEO and g["yt"] not in BAD_GEO


def wait_handshake(iface: str, pub: str, timeout: int = 12) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        curl(iface, "https://www.gstatic.com/generate_204", 3, body=False)
        p = peer(iface)
        if p and p["pub"] == pub and p["hs_age"] < 30:
            return True
        time.sleep(1)
    return False


def settle(iface: str, pub: str, timeout: int = 25) -> bool:
    """После смены сервера: handshake проходит сразу, но незнакомый ключ сервер Proton принимает
    через несколько секунд (до этого трафик не идёт) - ждём рабочий https."""
    if not wait_handshake(iface, pub):
        return False
    end = time.time() + timeout
    while time.time() < end:
        code, _ = curl(iface, "https://www.gstatic.com/generate_204", 5, body=False)
        if code == 204:
            return True
        time.sleep(2)
    return False


def set_peer(iface: str, pub: str, ip: str, port: str, allowed: str, old_pub: str | None) -> None:
    run(["wg", "set", iface, "peer", pub, "endpoint", f"{ip}:{port}", "allowed-ips", allowed,
         "persistent-keepalive", "15"])
    if old_pub and old_pub != pub:
        run(["wg", "set", iface, "peer", old_pub, "remove"])


# ── Сохранение выбора ──────────────────────────────────────────

def persist(iface: str, srv: dict, ep: dict, port: str) -> None:
    path = f"/etc/wireguard/{iface}.conf"
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    out, in_peer = [], False
    for line in lines:
        s = line.strip()
        if s.startswith("["):
            in_peer = s.lower() == "[peer]"
            out.append(line)
            if in_peer:
                out.append(f"# Proton {srv['name']} ({srv.get('city') or srv['country']}) - proton-pick {time.strftime('%F %T')}")
            continue
        if in_peer and (s.startswith("# Proton ") or s.startswith("#Proton ")):
            continue
        if in_peer and re.match(r"^PublicKey\s*=", s):
            out.append(f"PublicKey = {ep['public_key']}")
            continue
        if in_peer and re.match(r"^Endpoint\s*=", s):
            out.append(f"Endpoint = {ep['entry_ip']}:{port}")
            continue
        out.append(line)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    prefix = SETUP_PREFIX.get(iface)
    if prefix and os.path.exists(SETUP):
        with open(SETUP, encoding="utf-8") as f:
            text = f.read()
        for key, val in ((f"{prefix}_PUBLIC_KEY", ep["public_key"]), (f"{prefix}_ENDPOINT_HOST", ep["entry_ip"])):
            if re.search(rf"^{key}=.*$", text, re.M):
                text = re.sub(rf"^{key}=.*$", f"{key}={val}", text, flags=re.M)
            else:
                text = text.rstrip("\n") + f"\n{key}={val}\n"
        tmp = SETUP + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, os.stat(SETUP).st_mode & 0o777)
        os.replace(tmp, SETUP)


def sync_setup(iface: str, cur: dict) -> None:
    """Рабочий пир, сменённый вручную (wg set) или старой версией, а в setup прежний сервер -
    перезапуск антизапрета вернул бы старый. Записываем живой пир."""
    prefix = SETUP_PREFIX.get(iface)
    if not prefix or not os.path.exists(SETUP):
        return
    setup = read_kv(SETUP)
    r = run(["wg", "show", iface, "private-key"])
    priv = r.stdout.strip() if r.returncode == 0 else ""
    want = {f"{prefix}_PUBLIC_KEY": cur["pub"], f"{prefix}_ENDPOINT_HOST": cur["ip"]}
    if priv:
        # ключ, сменённый только в .conf, setup.sh --update заменил бы старым из setup
        want[f"{prefix}_PRIVATE_KEY"] = priv
    if all(setup.get(k) == v for k, v in want.items()):
        return
    with open(SETUP, encoding="utf-8") as f:
        text = f.read()
    for key, val in want.items():
        if re.search(rf"^{key}=.*$", text, re.M):
            text = re.sub(rf"^{key}=.*$", f"{key}={val}", text, flags=re.M)
    tmp = SETUP + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, os.stat(SETUP).st_mode & 0o777)
    os.replace(tmp, SETUP)
    log(f"{iface}: setup приведён к работающему туннелю ({', '.join(k for k in want if setup.get(k) != want[k])})")


# ── Список серверов и выбор ────────────────────────────────────

def server_list(cfg: dict[str, str], st: dict) -> list[dict]:
    url = cfg.get("LIST_URL", LIST_URL)
    cache = STATE_DIR + "/servers.json"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "proton-pick"}), timeout=30) as r:
            data = json.loads(r.read())
        if isinstance(data, dict):
            data = data.get("servers", [])
        if len(data) > 100:
            os.makedirs(STATE_DIR, exist_ok=True)
            with open(cache, "w", encoding="utf-8") as f:
                json.dump(data, f)
            return data
    except Exception as e:  # noqa: BLE001 - нет связи с DE3: работаем по прошлому списку
        log(f"server list: {e}; using cache")
    try:
        with open(cache, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def own_country(st: dict) -> str:
    if st.get("own_country"):
        return st["own_country"]
    _, text = curl(None, "https://www.cloudflare.com/cdn-cgi/trace", 8)
    m = re.search(r"^loc=([A-Z]{2})$", text, re.M)
    if m:
        st["own_country"] = m.group(1)
    return st.get("own_country", "")


def countries(cfg: dict[str, str], st: dict) -> list[str]:
    if cfg.get("COUNTRIES"):
        return [c.strip().upper() for c in cfg["COUNTRIES"].split(",") if c.strip()]
    own = own_country(st)
    return NEIGHBORS.get(own, [own] if own else ["DE", "NL"])


def ping(ip: str) -> float | None:
    try:
        r = run(["ping", "-n", "-q", "-c", "3", "-i", "0.2", "-W", "1", ip], timeout=8)
    except subprocess.TimeoutExpired:
        return None
    m = re.search(r"= [\d.]+/([\d.]+)/", r.stdout)
    return float(m.group(1)) if m else None


def candidates(servers: list[dict], cfg: dict[str, str], st: dict, country: str) -> list[tuple]:
    tiers = {t.strip().lower() for t in cfg.get("TIERS", "Plus").split(",")}
    bad = {ip for ip, t in st.get("bad_exits", {}).items() if time.time() - t < BAD_EXIT_TTL}
    items = []
    for s in servers:
        if s.get("country") != country or str(s.get("tier", "")).lower() not in tiers:
            continue
        feats = {f.lower() for f in s.get("features", [])}
        if feats & {"securecore", "secure_core", "secure-core", "tor"} or s.get("entry_country", country) != country:
            continue
        for ep in s.get("endpoints", []):
            if ep.get("online") and ep.get("public_key") and ep.get("entry_ip") and ep.get("exit_ip") not in bad:
                items.append((s, ep))
    pings: dict[str, float | None] = {}
    ips = sorted({ep["entry_ip"] for _, ep in items})
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
        for ip, rtt in zip(ips, ex.map(ping, ips)):
            pings[ip] = rtt
    ranked = []
    for s, ep in items:
        rtt = pings.get(ep["entry_ip"])
        if rtt is not None:
            ranked.append((rtt + 0.2 * int(s.get("load", 50)), rtt, s, ep))
    ranked.sort(key=lambda x: x[0])
    return ranked


def find_server(servers: list[dict], pub: str) -> tuple[dict | None, dict | None]:
    for s in servers:
        for ep in s.get("endpoints", []):
            if ep.get("public_key") == pub:
                return s, ep
    return None, None


def handle(iface: str, servers: list[dict], cfg: dict[str, str], st: dict, force: bool, dry: bool) -> str:
    ist = st.setdefault("ifaces", {}).setdefault(iface, {})
    cur = peer(iface)
    if not cur:
        return "no peer"
    now = time.time()
    ok = cur["hs_age"] < 180 and healthy(iface)
    reason = "" if ok else "туннель не работает"
    if ok and (force or now - ist.get("geo_t", 0) > GEO_EVERY):
        g = geo(iface)
        ist.update(geo_t=now, geo=g)
        if not geo_ok(g):
            reason = f"выход {g['ip']} определяется как {g['yt'] or g['cf']} (YouTube {g['yt'] or '?'}, Cloudflare {g['cf'] or '?'})"
            if g["ip"]:
                st.setdefault("bad_exits", {})[g["ip"]] = now
    if ok:
        sync_setup(iface, cur)
    optimize = force or now - ist.get("opt_t", 0) > OPTIMIZE_EVERY
    if not reason and not optimize:
        return "ok"
    # Всё перепробовано и не подошло (например, ключ отозван) - не перебираем каждые 30 минут
    if reason and not force and now - ist.get("fail_t", 0) < FAIL_BACKOFF:
        return f"{reason}; следующая попытка подбора после {time.strftime('%H:%M', time.localtime(ist['fail_t'] + FAIL_BACKOFF))}"
    ist["opt_t"] = now
    cur_srv, _ = find_server(servers, cur["pub"])
    cur_rtt = ping(cur["ip"])
    cur_score = (cur_rtt + 0.2 * int(cur_srv.get("load", 50))) if (cur_rtt is not None and cur_srv) else None
    for country in countries(cfg, st)[:MAX_COUNTRIES]:
        ranked = candidates(servers, cfg, st, country)
        if not ranked:
            continue
        if not reason:
            best = ranked[0]
            # Без поломки переключаемся только на заметно лучший (на 5 мс и 20%)
            if cur_score is not None and not (best[0] < cur_score - max(5.0, 0.2 * cur_score)):
                return f"ok, текущий {cur_srv['name'] if cur_srv else cur['ip']} {cur_rtt:.0f} мс - лучше нет"
        tried = 0
        for score, rtt, s, ep in ranked:
            if ep["public_key"] == cur["pub"]:
                continue
            if tried >= CANDIDATES:
                break
            tried += 1
            if dry:
                return f"dry-run: {reason or 'оптимизация'} -> {s['name']} {ep['entry_ip']} {rtt:.0f} мс, нагрузка {s.get('load')}%"
            log(f"{iface}: {reason or 'оптимизация'}; пробую {s['name']} {ep['entry_ip']} ({rtt:.0f} мс, нагрузка {s.get('load')}%)")
            set_peer(iface, ep["public_key"], ep["entry_ip"], cur["port"], cur["allowed"], cur["pub"])
            good = settle(iface, ep["public_key"])
            g = geo(iface) if good else {"cf": "", "yt": "", "ip": ""}
            if good and geo_ok(g):
                persist(iface, s, ep, cur["port"])
                ist.update(server=s["name"], entry=ep["entry_ip"], exit=g["ip"], geo=g, geo_t=time.time(),
                           switched=time.strftime("%F %T"), rtt=round(rtt, 1), fail_t=0)
                return f"переключён на {s['name']} ({ep['entry_ip']}, выход {g['ip']}, YouTube {g['yt']}, {rtt:.0f} мс)" + (f"; причина: {reason}" if reason else "")
            if good and g["ip"]:
                st.setdefault("bad_exits", {})[g["ip"]] = time.time()
            log(f"{iface}: {s['name']} не подошёл (работает={good}, YouTube {g['yt'] or '?'}, Cloudflare {g['cf'] or '?'})")
            set_peer(iface, cur["pub"], cur["ip"], cur["port"], cur["allowed"], ep["public_key"])
            settle(iface, cur["pub"], 15)
        if tried and reason:
            continue  # в этой стране ничего не подошло - следующая страна
        if tried:
            break
    if reason:
        ist["fail_t"] = now
        return f"оставлен прежний ({reason}): ни один сервер не подошёл"
    return "ok"


def install() -> None:
    exe = os.path.realpath(sys.argv[0])
    with open("/etc/systemd/system/proton-pick.service", "w", encoding="utf-8") as f:
        f.write(UNIT.format(exe=exe))
    with open("/etc/systemd/system/proton-pick.timer", "w", encoding="utf-8") as f:
        f.write(TIMER)
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", "--now", "proton-pick.timer"])
    print("proton-pick.timer installed for", exe)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true", help="проверить страну выхода и пересмотреть выбор сейчас")
    ap.add_argument("--dry-run", action="store_true", help="только показать, что было бы выбрано")
    ap.add_argument("--install", action="store_true", help="установить systemd-таймер")
    ap.add_argument("--status", action="store_true", help="показать сохранённое состояние")
    a = ap.parse_args()
    if a.install:
        install()
        return 0
    if a.status:
        print(json.dumps(load_state(), ensure_ascii=False, indent=1))
        return 0
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(STATE_DIR + "/lock", "w") as lk:
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            log("уже запущен")
            return 0
        cfg = read_kv(CONF)
        st = load_state()
        names = interfaces(cfg)
        if not names:
            log("Proton-туннелей нет")
            return 0
        servers = server_list(cfg, st)
        if not servers:
            log("список серверов Proton недоступен - только проверка")
        for iface in names:
            try:
                res = handle(iface, servers, cfg, st, a.force, a.dry_run) if servers else ("ok" if healthy(iface) else "не работает, списка серверов нет")
            except Exception as e:  # noqa: BLE001 - один туннель не должен ронять остальные
                res = f"ошибка: {e}"
            st.setdefault("ifaces", {}).setdefault(iface, {}).update(last=res, last_t=time.strftime("%F %T"))
            log(f"{iface}: {res}")
        st["bad_exits"] = {ip: t for ip, t in st.get("bad_exits", {}).items() if time.time() - t < BAD_EXIT_TTL}
        if not a.dry_run:
            save_state(st)
    return 0


if __name__ == "__main__":
    sys.exit(main())
