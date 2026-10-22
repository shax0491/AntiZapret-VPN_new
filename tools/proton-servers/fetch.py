#!/usr/bin/env python3
"""Список серверов Proton VPN для proton-pick на узлах (DE3, таймер раз в 6 часов).

Берёт серверы через protonvpn-wg-confgen по сохранённой сессии аккаунта (/root/.protonvpn-session.json,
продлевается сама; первый вход - вручную: /opt/proton-auto/login.sh) и кладёт сокращённый список
в /var/www/az-lists/proton-servers.json (отдаётся nginx по секретному пути вместе с az-lists).
Если сессия умерла - одно сообщение в Telegram через очередь router_watch, узлы тем временем
работают по последнему списку.
"""
import json
import os
import subprocess
import time

BIN = "/opt/proton-auto/bin/protonvpn-wg-confgen"
ENV = "/opt/proton-auto/env"
OUT = os.environ.get("PROTON_LIST_OUT", "/var/www/az-lists/proton-servers.json")  # каталог, который отдаёт веб-сервер
STATE = "/var/lib/proton-auto.json"
QF = "/var/lib/router_watch_q.json"   # очередь уведомлений router_watch, если он есть (отправляет раз в минуту)


def env():
    out = {}
    try:
        for line in open(ENV, encoding="utf-8"):
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1)
                out[k] = v.strip("'\"")
    except OSError:
        pass
    return out


def notify(text):
    print(text)
    if not os.path.exists(QF):
        return
    try:
        q = json.load(open(QF, encoding="utf-8"))
    except (OSError, ValueError):
        q = []
    q.append({"t": time.time(), "text": text})
    tmp = QF + ".tmp"
    json.dump(q, open(tmp, "w", encoding="utf-8"), ensure_ascii=False)
    os.replace(tmp, QF)


def main():
    try:
        st = json.load(open(STATE, encoding="utf-8"))
    except (OSError, ValueError):
        st = {}
    user = env().get("PROTON_USER", "")
    err = ""
    servers = []
    if not user:
        err = "не задан PROTON_USER в /opt/proton-auto/env"
    else:
        r = subprocess.run([BIN, "--username", user, "--list-servers", "--json", "--p2p-only=false", "--password-stdin"],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180,
                           env={**os.environ, "HOME": "/root"})
        out = r.stdout
        i = out.find("\n[")
        start = 0 if out.startswith("[") else (i + 1 if i >= 0 else -1)
        try:
            servers = json.loads(out[start:]) if start >= 0 else []
        except ValueError:
            servers = []
        if r.returncode != 0 or len(servers) < 100:
            err = (r.stderr.strip() or out.strip())[-300:] or f"код {r.returncode}, серверов {len(servers)}"
    if err and not user:
        print("ошибка:", err)   # вход ещё не выполнен - не сбой, оповещать не о чем
    elif err:
        st["fail"] = st.get("fail", 0) + 1
        print("ошибка:", err)
        if st["fail"] == 2:   # одно сообщение после двух неудач подряд (12 часов)
            notify("⚠️ Proton: не удалось обновить список серверов для автоподбора (" + err[:200] +
                   "). Узлы работают по прежнему списку. Если сессия истекла - войти заново: /opt/proton-auto/login.sh")
    else:
        slim = [{k: s.get(k) for k in ("name", "country", "entry_country", "city", "tier", "load", "score", "features", "endpoints")}
                for s in servers]
        tmp = OUT + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(slim, f, ensure_ascii=False, separators=(",", ":"))
        os.chmod(tmp, 0o644)
        os.replace(tmp, OUT)
        if st.get("fail", 0) >= 2:
            notify("✅ Proton: список серверов для автоподбора снова обновляется")
        st.update(fail=0, ok_t=time.strftime("%F %T"), count=len(slim))
        print("серверов:", len(slim))
    json.dump(st, open(STATE, "w", encoding="utf-8"))


if __name__ == "__main__":
    main()
