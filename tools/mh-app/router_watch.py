#!/usr/bin/env python3
# Сторож домашнего роутера (systemd timer, раз в минуту): YouTube, AWG-туннель, сам роутер + необязательное автопереключение AWG.
# Состояние берёт у rtctl по ограниченному SSH-ключу. Сообщения шлёт в Телеграм НАПРЯМУЮ с проверкой доставки: если Телеграм недоступен
# (например, упал тот самый AWG, через который он ходит), сообщение ждёт в очереди и уйдёт при первой возможности с пометкой времени.
import json, os, subprocess, time, urllib.parse, urllib.request
ST = "/var/lib/router_watch.json"
QF = "/var/lib/router_watch_q.json"
TG = json.load(open("/opt/arr-stack/scripts/tg_notify.json"))
KEY, KNOWN = "/opt/mh-app/ssh/router_key", "/opt/mh-app/ssh/known_hosts"
FAIL_FILE = "/opt/mh-app/auto_failover.json"
COOLDOWN = 600                      # автопереключение не чаще раза в 10 минут
LIMIT = {"rt": 3, "yt": 2, "awg": 2, "mh": 2}  # сколько проверок подряд считаем сбоем
MAX_AGE = 6 * 3600                  # старше - из очереди выбрасываем


def load(p, default):
    try:
        return json.load(open(p))
    except Exception:
        return default


def save(p, v):
    tmp = p + ".tmp"
    json.dump(v, open(tmp, "w")); os.replace(tmp, p)


def _send(tg, text, timeout):
    p = {"chat_id": tg["chat"], "text": text, "parse_mode": "HTML", "disable_web_page_preview": "true"}
    if tg.get("thread"):
        p["message_thread_id"] = tg["thread"]
    data = urllib.parse.urlencode(p).encode()
    r = urllib.request.urlopen("https://api.telegram.org/bot%s/sendMessage" % tg["token"], data, timeout=timeout)
    return json.loads(r.read()).get("ok") is True


def tg_send(text):
    """Группа (tg_group.json: бот @inform_bot_kld_bot, тема); не вышло - личка от основного бота, потом запасной (бот панели)."""
    grp = load("/opt/arr-stack/scripts/tg_group.json", None)
    if grp:
        try:
            if _send(grp, text, 8):
                return True
        except Exception:
            pass
    try:
        if _send(TG, text, 8):
            return True
    except Exception:
        pass
    fb = load("/opt/arr-stack/scripts/tg_fallback.json", None)
    return bool(fb) and _send(fb, text + " <i>(через запасной бот)</i>", 12)


def flush():
    """Отправить всё из очереди по порядку; остановиться на первой неудаче."""
    q = load(QF, [])
    left = []
    for i, m in enumerate(q):
        if time.time() - m["t"] > MAX_AGE:
            continue
        late = time.time() - m["t"] > 90
        try:
            ok = tg_send(("<i>(%s)</i> " % time.strftime("%H:%M", time.localtime(m["t"])) if late else "") + m["text"])
        except Exception:
            ok = False
        if not ok:
            left = q[i:]
            break
    save(QF, left)


def notify(text):
    q = load(QF, []); q.append({"t": time.time(), "text": "🏠 " + text}); save(QF, q)
    flush()


def rt(cmd, timeout=40):
    r = subprocess.run(["ssh", "-p", "12222", "-i", KEY, "-o", "UserKnownHostsFile=" + KNOWN, "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes",
                        "-o", "ConnectTimeout=8", "root@127.0.0.1", cmd], capture_output=True, text=True, timeout=timeout)
    return r.stdout if r.returncode == 0 else None


def status():
    out = rt("status")
    if out is None:
        return None
    d = {}
    for ln in out.splitlines():
        if "=" in ln:
            k, v = ln.split("=", 1); d[k] = v.strip()
    return d


def ms(v):
    try:
        return "%d мс" % round(float(str(v).split()[0]))
    except Exception:
        return str(v)


def failover(st, d):
    """Автопереключение AWG: активный узел молчит -> следующий по порядку, который отвечает на пинг."""
    cfg = load(FAIL_FILE, {})
    if not cfg.get("on") or time.time() - st.get("fo_t", 0) < COOLDOWN:
        return False
    cur = d.get("awg", "none"); awgs = [x for x in d.get("awg_list", "").split(",") if x]
    order = [x for x in cfg.get("order", []) if x in awgs] + [x for x in awgs if x not in cfg.get("order", [])]
    cands = [x for x in order if x != cur][:3]
    if not cands:
        return False
    notify("⚠️ %s не отвечает на пинг → переключаю на %s" % (cur, cands[0]))
    for c in cands:
        rt("awg " + c, timeout=60)
        d2 = status() or {}
        if d2.get("awg") == c and d2.get("awg_ping", "fail") != "fail":
            st["fo_t"] = time.time(); st["awg_n"] = 0; st["awg_down"] = False
            notify("✅ %s включён, пинг %s" % (c, ms(d2.get("awg_ping"))))
            return True
        if c != cands[-1]:
            notify("⚠️ %s тоже не отвечает → пробую %s" % (c, cands[cands.index(c) + 1]))
    st["fo_t"] = time.time()
    notify("❌ Ни один узел не отвечает (пробовал %s)" % ", ".join(cands))
    return True


AUTO_HOLD = 60        # новый узел должен продержаться столько секунд, иначе молчим (короткие скачки туда-обратно)
AUTO_GAP = 900        # и не чаще одного сообщения в 15 минут; переключения за это время сводим в одно


def short(name):
    return name.replace(" | VLESS ", " ").replace(" | AWG3", "") if name else "?"


def auto_switch(st):
    """Сообщить о переключении «Авто», только когда новый узел устоялся (держится AUTO_HOLD) и не чаще AUTO_GAP."""
    try:
        sec = open("/opt/mh-app/mihomo.secret", encoding="utf-8").read().strip()
        req = urllib.request.Request("http://127.0.0.1:19090/proxies/" + urllib.parse.quote("Авто — самый быстрый"), headers={"Authorization": "Bearer " + sec})
        g = json.loads(urllib.request.urlopen(req, timeout=8).read())
        now = g.get("now")
    except Exception:
        return
    if not now:
        return
    t = time.time()
    if g.get("fixed"):                     # закреплён вручную из приложения - об этом уже пришло «✋», молчим
        st.update(auto_now=now, auto_since=t, auto_rep=now, auto_flips=0)
        return
    if st.get("auto_now") != now:          # узел сменился: засекаем, сколько он держится
        st["auto_now"] = now; st["auto_since"] = t
        st["auto_flips"] = st.get("auto_flips", 0) + 1
    rep = st.setdefault("auto_rep", now)   # о каком узле пользователь знает
    if now == rep:                         # вернулся обратно, не дождавшись минуты - ничего не было
        st["auto_flips"] = 0
        return
    if t - st.get("auto_since", t) < AUTO_HOLD or t - st.get("auto_rep_t", 0) < AUTO_GAP:
        return
    notify("🔀 Авто: %s → %s" % (short(rep), short(now)))   # без счётчика: он считал и промежуточные скачки и путал ("3 переключения" при одном итоговом)
    st["auto_rep"] = now; st["auto_rep_t"] = t; st["auto_flips"] = 0


NODE_DOWN_N = 10   # проверок подряд (раз в минуту) - сервер считаем упавшим через ~10 минут


def nodes_down(st):
    """Сервер VLESS совсем не отвечает: все его варианты (Proton и прямой) мертвы по проверкам домашнего mihomo."""
    try:
        sec = open("/opt/mh-app/mihomo.secret", encoding="utf-8").read().strip()
        req = urllib.request.Request("http://127.0.0.1:19090/providers/proxies/az-vless", headers={"Authorization": "Bearer " + sec})
        px = json.loads(urllib.request.urlopen(req, timeout=10).read()).get("proxies", [])
    except Exception:
        return
    alive = {}
    for p in px:
        name = p.get("name", "")
        if " | " not in name:
            continue
        node = name.split(" | ")[0]
        alive[node] = alive.get(node, False) or bool(p.get("alive"))
    nd = st.setdefault("nodes", {})
    for node, ok in alive.items():
        rec = nd.setdefault(node, {"n": 0, "down": False})
        rec["n"] = 0 if ok else rec["n"] + 1
        if not ok and rec["n"] >= NODE_DOWN_N and not rec["down"]:
            rec["down"] = True; notify("❌ %s не отвечает (оба варианта, ~%d мин)" % (node, NODE_DOWN_N))
        elif ok and rec["down"]:
            rec["down"] = False; notify("✅ %s снова отвечает" % node)
    for node in list(nd):
        if node not in alive:
            del nd[node]



PROTON_EVERY = 300   # секунд между проверками Proton на узлах
PROTON_BAD_N = 2     # столько неудачных проверок подряд - «Proton не работает»


def _hc(sec, name):
    """Проверка одного варианта узла через домашний mihomo: True - открылся https-сайт."""
    url = "http://127.0.0.1:19090/providers/proxies/az-vless/%s/healthcheck?url=%s&timeout=6000" % (
        urllib.parse.quote(name), urllib.parse.quote("https://www.gstatic.com/generate_204"))
    try:
        d = json.loads(urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": "Bearer " + sec}), timeout=10).read())
        return bool(d.get("delay"))
    except Exception:
        return False


def proton_check(st):
    """Proton протух на узле (ключ отключили, сервер режет трафик), а сам узел жив - сообщить; починился - сообщить."""
    if time.time() - st.get("pc_t", 0) < PROTON_EVERY:
        return
    st["pc_t"] = time.time()
    try:
        sec = open("/opt/mh-app/mihomo.secret", encoding="utf-8").read().strip()
        req = urllib.request.Request("http://127.0.0.1:19090/providers/proxies/az-vless", headers={"Authorization": "Bearer " + sec})
        names = [p.get("name", "") for p in json.loads(urllib.request.urlopen(req, timeout=10).read()).get("proxies", [])]
    except Exception:
        return
    pc = st.setdefault("proton", {})
    for name in names:
        if " | VLESS Proton" not in name:
            continue
        node = name.split(" | ")[0]
        direct = node + " | VLESS прямой"
        rec = pc.setdefault(node, {"n": 0, "down": False})
        if _hc(sec, name) or _hc(sec, name):              # вторая попытка - от случайного таймаута
            rec["n"] = 0
            if rec["down"]:
                rec["down"] = False; notify("✅ %s: Proton снова работает" % node)
            continue
        if direct in names and not _hc(sec, direct):       # весь узел лёг - это сообщение «узел не отвечает», не дублируем
            continue
        rec["n"] += 1
        if rec["n"] >= PROTON_BAD_N and not rec["down"]:
            rec["down"] = True
            notify("❌ %s: Proton не работает (прямой выход в порядке) — нужен новый профиль Proton (WireGuard, Router, NetShield выкл). «Авто» этот вариант пока обходит" % node)
    for node in list(pc):
        if not any(n.startswith(node + " | ") for n in names):
            del pc[node]


def main():
    flush()   # сначала догнать отложенное
    st = load(ST, {})

    def upd(key, bad, down_msg, up_msg):
        n = st.get(key + "_n", 0)
        n = n + 1 if bad else 0
        was = st.get(key + "_down", False)
        st[key + "_n"] = n
        if bad and n >= LIMIT[key] and not was:
            st[key + "_down"] = True; return down_msg
        if not bad and was:
            st[key + "_down"] = False; notify("✅ " + up_msg)
        return None
    try:
        d = status()
    except Exception:
        d = None
    m = upd("rt", d is None, "Роутер не отвечает", "Роутер снова отвечает")
    if m: notify("⚠️ " + m)
    if d is not None:
        code = int(d.get("yt_code", "0") or 0)
        m = upd("yt", not (200 <= code < 400), "YouTube не открывается" + ("" if d.get("zapret") == "on" else " (запрет выключен)"), "YouTube снова открывается")
        if m: notify("⚠️ " + m)
        m = upd("mh", d.get("mihomo") == "off", "mihomo не работает", "mihomo снова работает")
        if m: notify("⚠️ " + m)
        awg = d.get("awg", "none")
        bad = awg != "none" and d.get("awg_ping", "fail") == "fail"
        m = upd("awg", bad, "%s не отвечает на пинг" % awg, "%s снова отвечает, пинг %s" % (awg, ms(d.get("awg_ping"))))
        if m:
            cfg = load(FAIL_FILE, {})
            if cfg.get("on") and time.time() - st.get("fo_t", 0) >= COOLDOWN:
                failover(st, d)
            else:
                notify("⚠️ " + m)
    auto_switch(st)
    nodes_down(st)
    proton_check(st)
    save(ST, st)
    flush()


main()
