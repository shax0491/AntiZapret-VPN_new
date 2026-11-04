#!/bin/sh
# Агент вкладки «mihomo · работа» в Mini App: раз в 15 с отправляет состояние mihomo на домашний сервер и в ответ
# получает команды (переключить карточку, замерить задержки). Роутер сам ходит наружу - вход снаружи на него не нужен.
API=http://127.0.0.1:9190
CFG=/opt/etc/mihomo/config.yaml
KEY=$(cat /opt/etc/mihomo/agent.key 2>/dev/null)
URL=https://de3.hoststatus2346.ru/api/agent/report
CHECK="Все серверы — проверка"
PXF=/tmp/mh-px.json; PVF=/tmp/mh-pv.json; BODY=/tmp/mh-body.json; RESP=/tmp/mh-resp.json
[ -z "$KEY" ] && exit 1
uri() { printf %s "$1" | jq -sRr @uri; }

info() {
	pid=$(pidof nfqws | cut -d' ' -f1)
	args=$(grep '^ARGS=' /opt/etc/init.d/S98nfqws 2>/dev/null)
	tcp=$(echo "$args" | sed 's/--new.*//' | grep -oE -- '--(dpi-desync|dpi-desync-fooling|dpi-desync-split-pos)=[^ "]+' | sed -E 's/^--dpi-desync=/метод: /; s/^--dpi-desync-fooling=/fooling: /; s/^--dpi-desync-split-pos=/split-pos: /' | tr '\n' ';' | sed 's/;/ · /g; s/ · $//')
	udp=$(echo "$args" | sed 's/.*--new//' | grep -oE -- '--(dpi-desync|dpi-desync-repeats)=[^ "]+|quic_[a-z_]+\.bin' | sed -E 's/^--dpi-desync=/метод: /; s/^--dpi-desync-repeats=/повторов: /' | tr '\n' ';' | sed 's/;/ · /g; s/ · $//')
	qnum=$(echo "$args" | grep -oE -- '--qnum=[0-9]+' | head -1 | cut -d= -f2)
	n=$(curl -s -m 8 http://localhost:79/rci/show/running-config 2>/dev/null | jq -r '.message[]?' | awk '/^ip hotspot/{h=1} h&&/^!/{h=0} h&&/ policy Mihomo$/{n++} END{print n+0}')
	up=$(uptime | sed -E 's/.* up ([^,]+),.*/\1/')
	mem=$(free -m | awk 'NR==2{printf "%d/%d МБ", $3, $2}')
	# состояние для Mini App (wtctl): раз в минуту - проверка YouTube не чаще
	RT=/tmp/wtctl.status
	if [ ! -s $RT ] || [ $(( $(date +%s) - $(date -r $RT +%s) )) -gt 60 ]; then /opt/bin/wtctl status > $RT.t 2>/dev/null && mv $RT.t $RT; fi
	rt=$(jq -Rn '[inputs|select(contains("="))|split("=")|{(.[0]):(.[1:]|join("="))}]|add // {}' < $RT)
	lists=$(for l in vpn direct block; do /opt/bin/wtctl list items $l | jq -Rn --arg k $l '{($k): [inputs|select(length>0)]}'; done | jq -cs 'add')
	[ -n "$rt" ] || rt="{}"; [ -n "$lists" ] || lists="{}"
	jq -cn --arg pid "$pid" --arg tcp "$tcp" --arg udp "$udp" --arg q "$qnum" --argjson n "${n:-0}" --arg up "$up" --arg mem "$mem" \
		--argjson rt "$rt" --argjson lists "$lists" --arg hosts "" \
		'{zapret:{running:($pid!=""), pid:$pid, tcp:$tcp, udp:$udp, qnum:$q, hosts:($hosts|split("\n")|map(select(length>0)))}, policy_devices:$n, uptime:$up, mem:$mem, rt:$rt, lists:$lists}'
}

run_cmds() {
	SEC=$(grep -oE '^secret: "[^"]+"' $CFG | cut -d'"' -f2)
	jq -c '.cmds[]?' $RESP 2>/dev/null | while read -r c; do
		t=$(echo "$c" | jq -r .type)
		if [ "$t" = select ]; then
			g=$(echo "$c" | jq -r .group); nm=$(echo "$c" | jq -r .name)
			if [ "$nm" = "__auto" ]; then
				curl -s -m 8 -X DELETE -H "Authorization: Bearer $SEC" "$API/proxies/$(uri "$g")" >/dev/null
			else
				curl -s -m 8 -X PUT -H "Authorization: Bearer $SEC" -d "$(jq -cn --arg n "$nm" '{name:$n}')" "$API/proxies/$(uri "$g")" >/dev/null
			fi
			logger -t mh-agent "select: $g -> $nm"
		elif [ "$t" = config ]; then
			# новый config.yaml по ссылке с DE3: проверка mihomo -t, бэкап, перезапуск; при сбое - откат
			u=$(echo "$c" | jq -r .url)
			case "$u" in https://de3.hoststatus2346.ru/*) ;; *) logger -t mh-agent "config: чужой адрес отклонён"; continue;; esac
			if curl -fsS -m 90 -x http://127.0.0.1:7890 -o /tmp/mh-new.yaml "$u" && /opt/sbin/mihomo -d /opt/etc/mihomo -t -f /tmp/mh-new.yaml >/tmp/mh-new.log 2>&1; then
				cp $CFG $CFG.prev && cp /tmp/mh-new.yaml $CFG && /opt/etc/init.d/S99mihomo restart >/dev/null 2>&1
				sleep 20
				if ! curl -s -m 8 -H "Authorization: Bearer $(grep -oE '^secret: "[^"]+"' $CFG | cut -d'"' -f2)" $API/version >/dev/null; then
					cp $CFG.prev $CFG && /opt/etc/init.d/S99mihomo restart >/dev/null 2>&1; logger -t mh-agent "config: mihomo не поднялся, откат"
				else logger -t mh-agent "config: применён"; fi
			else logger -t mh-agent "config: проверка не прошла: $(tail -1 /tmp/mh-new.log)"; fi
		elif [ "$t" = rt ]; then
			# команды панели работы из Mini App: только разрешённые формы
			rc=$(echo "$c" | jq -r .cmd)
			case "$rc" in
				"zapret on"|"zapret off"|"strategy 1"|"strategy 2"|"strategy 3"|"strategy 4"|"strategy 5"|"strategy auto") /opt/bin/wtctl $rc >/dev/null 2>&1 ;;
				"list add "*|"list del "*) set -- $rc; [ $# -eq 4 ] && /opt/bin/wtctl list "$2" "$3" "$4" >/dev/null 2>&1 ;;
				*) logger -t mh-agent "rt: отклонено: $rc"; continue ;;
			esac
			rm -f /tmp/wtctl.status; logger -t mh-agent "rt: $rc"
		elif [ "$t" = delay ]; then
			curl -s -m 25 -H "Authorization: Bearer $SEC" "$API/group/$(uri "$CHECK")/delay?url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000" >/dev/null
			/opt/bin/mh-ut-delay.sh
			logger -t mh-agent "delay test"
		fi
	done
}

while true; do
	SEC=$(grep -oE '^secret: "[^"]+"' $CFG | cut -d'"' -f2)
	if curl -s -m 8 -H "Authorization: Bearer $SEC" $API/proxies > $PXF 2>/dev/null && [ -s $PXF ]; then
		VER=$(curl -s -m 5 -H "Authorization: Bearer $SEC" $API/version | jq -r '.version // ""')
		curl -s -m 8 -H "Authorization: Bearer $SEC" $API/providers/proxies > $PVF 2>/dev/null || echo {} > $PVF
		jq -c -n --slurpfile px $PXF --slurpfile pv $PVF --arg ver "$VER" --argjson info "$(info)" '{px:(([$pv[0].providers[]? | select(.vehicleType != "Compatible") | .proxies[]? | {(.name): .}] | add // {}) + $px[0].proxies), ver:$ver, info:$info, lp:1}' > $BODY 2>/dev/null
		if [ -s $BODY ] && curl -s -m 40 -x http://127.0.0.1:7890 -X POST -H "X-Agent-Key: $KEY" -H "Content-Type: application/json" --data-binary @$BODY "$URL" -o $RESP; then
			if [ "$(jq '.cmds|length' $RESP 2>/dev/null)" = 0 ]; then sleep 1; else run_cmds; sleep 1; fi
			continue
		fi
	fi
	sleep 15
done
