#!/bin/sh
# Явная карта dual-клиентов AWG3 для kresd: только "имя dual" из ipv6-profile.txt, IPv4 берётся из комментария
# пира в awg1.conf ("[Peer]" -> "# имя" -> ... -> "AllowedIPs = 10.9.0.N/32, ..."). Неизвестные и старые клиенты
# в карту не попадают и остаются IPv4-only. Вызывается из панели (sync_dual_map) как `sh az-dual-clients.sh`.
#
# Ошибка = ненулевой код, понятное сообщение в stderr и НЕТ изменений в прежней карте:
#   1 - нет/не читается/повреждён awg1.conf или не читается ipv6-profile.txt
#   2 - не удалось собрать или записать карту
# Запись атомарная: временный файл в каталоге карты + mv, права и владелец прежней карты сохраняются.
AZ_DUAL_PROFILE=${AZ_DUAL_PROFILE:-/root/antizapret/config/ipv6-profile.txt}
AZ_DUAL_AWG_CONF=${AZ_DUAL_AWG_CONF:-/etc/amnezia/amneziawg3/awg1.conf}
AZ_DUAL_MAP=${AZ_DUAL_MAP:-/etc/knot-resolver/dual-clients.txt}

die() { echo "az-dual-clients: $2" >&2; exit "$1"; }

[ -r "$AZ_DUAL_AWG_CONF" ] || die 1 "нет или не читается $AZ_DUAL_AWG_CONF, карта не изменена"
grep -q '^\[Interface\]' "$AZ_DUAL_AWG_CONF" || die 1 "$AZ_DUAL_AWG_CONF повреждён (нет секции [Interface]), карта не изменена"
if [ -e "$AZ_DUAL_PROFILE" ] && [ ! -r "$AZ_DUAL_PROFILE" ]; then
	die 1 "не читается $AZ_DUAL_PROFILE, карта не изменена"
fi

[ ! -d "$AZ_DUAL_MAP" ] || die 2 "$AZ_DUAL_MAP - каталог, а не файл карты, карта не изменена"
T=$(mktemp "$AZ_DUAL_MAP.XXXXXX") || die 2 "не удалось создать временный файл рядом с $AZ_DUAL_MAP (нет каталога или нет прав), карта не изменена"
trap 'rm -f "$T"' EXIT

printf '' > "$T" || die 2 "не удалось записать временный файл $T, карта не изменена"
if [ -f "$AZ_DUAL_PROFILE" ]; then
	names=$(awk '$1 !~ /^#/ && $2 == "dual" { print $1 }' "$AZ_DUAL_PROFILE") || die 2 "не удалось разобрать $AZ_DUAL_PROFILE, карта не изменена"
	set -f
	for n in $names; do
		awk -v a="# ${n}_az" -v b="# ${n}" '/^\[Peer\]/{f=0} $0==a||$0==b{f=1;next} f&&/^AllowedIPs/{ if (match($0,/10\.9\.0\.[0-9]+/)) print substr($0,RSTART,RLENGTH); f=0 }' "$AZ_DUAL_AWG_CONF" >> "$T" || die 2 "не удалось построить карту из $AZ_DUAL_AWG_CONF (ошибка разбора или записи, возможно нет места на диске), карта не изменена"
	done
	set +f
fi
sort -u "$T" -o "$T" || die 2 "не удалось отсортировать карту, карта не изменена"

if [ -e "$AZ_DUAL_MAP" ]; then
	cmp -s "$T" "$AZ_DUAL_MAP" && exit 0
	chmod --reference="$AZ_DUAL_MAP" "$T" 2>/dev/null || chmod 644 "$T"
	chown --reference="$AZ_DUAL_MAP" "$T" 2>/dev/null || true
else
	chmod 644 "$T" || die 2 "не удалось выставить права на $T, карта не изменена"
fi
mv -f "$T" "$AZ_DUAL_MAP" || die 2 "не удалось записать $AZ_DUAL_MAP, прежняя карта не изменена"
