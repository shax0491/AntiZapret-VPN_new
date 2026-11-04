#!/bin/sh
# раз в минуту (cron): mihomo / nfqws живы? группа «Авто» на каком сервере? Сообщения - в Telegram через бота на LXC 107.
# Туннели не будит: только читает состояние mihomo.
ST=/opt/etc/mihomo/watch.state; SEC=$(cat /opt/etc/mihomo/tg.secret)

send() {
	# JSON: экранируем обратный слэш и кавычки, переводы строк -> \n
	t=$(printf '🏠 %s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR>1{printf "\\n"} {printf "%s", $0}')
	printf '{"eventType":"Notice","html":true,"text":"%s"}' "$t" > /tmp/mihomo-msg.json
	:
}

[ "$1" = "test" ] && { send "$2"; exit 0; }

# Только одна копия сторожа (23.10: роутер под нагрузкой, проверки шли дольше минуты, копии сторожа
# запускали mihomo параллельно - 4 mihomo, память кончилась, роутер встал). Зависшую блокировку снимаем через 5 минут.
LOCK=/tmp/mh-watch.lock
if ! mkdir $LOCK 2>/dev/null; then
	[ $(( $(date +%s) - $(cat $LOCK/t 2>/dev/null || echo 0) )) -lt 300 ] && exit 0
	rm -rf $LOCK; mkdir $LOCK 2>/dev/null || exit 0
fi
date +%s > $LOCK/t
trap 'rm -rf $LOCK' EXIT INT TERM

# Лишние копии mihomo (запуск вручную поверх работающего и т.п.) - оставляем самую старую
PIDS=$(pidof mihomo)
if [ $(echo $PIDS | wc -w) -gt 1 ]; then
	KEEP=$(for p in $PIDS; do echo "$(cut -d' ' -f22 /proc/$p/stat) $p"; done | sort -n | head -1 | cut -d' ' -f2)
	for p in $PIDS; do [ "$p" != "$KEEP" ] && kill $p; done
fi

if ! pidof mihomo >/dev/null; then
	# Падает снова и снова (например, не хватает памяти) - после 3 перезапусков за 15 минут больше не трогаем,
	# одно сообщение; иначе перезапуски сами добивают роутер. Сброс: rm /tmp/mh-restarts
	RS=/tmp/mh-restarts; NOWT=$(date +%s)
	CNT=$(awk -v n=$NOWT '$1 > n - 900' $RS 2>/dev/null | wc -l)
	if [ "$CNT" -ge 3 ]; then
		[ -f $RS.told ] || { send "❌ mihomo падает при каждом запуске (3 раза за 15 мин) — перезапуски остановлены, нужен разбор."; touch $RS.told; }
	else
		echo $NOWT >> $RS; rm -f $RS.told
		/opt/etc/init.d/S99mihomo start >/dev/null; sleep 5
		pidof mihomo >/dev/null && send "⚠️ mihomo упал — перезапущен." || send "❌ mihomo упал и не запускается — устройства политики «mihomo (тест)» без интернета."
	fi
fi
SECRET=$(grep -oE '^secret: "[^"]+"' /opt/etc/mihomo/config.yaml | cut -d'"' -f2)
NOW=$(curl -s -m 5 -H "Authorization: Bearer $SECRET" http://127.0.0.1:9090/proxies | grep -oE '"name":"Авто — самый быстрый"[^}]*"now":"[^"]*"' | grep -oE '"now":"[^"]*"' | cut -d'"' -f4)
[ -z "$NOW" ] && exit 0
# в watch.state: 1 - сервер сейчас, 2 - pid mihomo, 3 - о каком сервере писали последним, 4 - когда писали (unix).
# Пишем коротко и не чаще раза в 30 мин; метание туда-обратно в это окно и перезапуск mihomo - молча.
PID=$(pidof mihomo); NOWT=$(date +%s)
OLDPID=$(sed -n 2p $ST 2>/dev/null); LASTN=$(sed -n 3p $ST 2>/dev/null); LASTT=$(sed -n 4p $ST 2>/dev/null)
[ -z "$LASTN" ] && LASTN=$NOW
[ -z "$LASTT" ] && LASTT=0
if [ -n "$OLDPID" ] && [ "$PID" != "$OLDPID" ]; then
	LASTN=$NOW
elif [ "$NOW" != "$LASTN" ] && [ $((NOWT - LASTT)) -ge 1800 ]; then
	: # уведомления об автопереключении выключены 15.10 - send "🔀 Авто: $(echo "$LASTN" | sed 's/ | AWG3//') → $(echo "$NOW" | sed 's/ | AWG3//')"
	LASTN=$NOW; LASTT=$NOWT
fi
printf '%s
%s
%s
%s
' "$NOW" "$PID" "$LASTN" "$LASTT" > $ST
