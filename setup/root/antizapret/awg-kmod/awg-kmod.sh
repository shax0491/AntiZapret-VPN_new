#!/bin/bash
# Модуль ядра AmneziaWG (amneziawg) для AmneziaWG 2 (antizapret2/vpn2) и AmneziaWG 3 (awg1).
# В ядре шифрование заметно быстрее amneziawg-go: на 1-2 vCPU скорость VPN упирается в процессор.
#
# Исходники апстрима на закреплённом коммите + исправление сборки на ядрах, куда дистрибутив
# частично перенёс смену API udp_tunnel без смены версии (Ubuntu 7.0.0-38, PR #265 апстрима).
# В DKMS модуль добавляется с AUTOINSTALL=no: неудачная сборка под новое ядро не роняет dpkg,
# а собирает модуль под новые ядра хук /etc/kernel/postinst.d/zz-amneziawg (всегда код 0).
# Ядро без модуля продолжает работать: awg-quick и awg3-up.sh переходят на amneziawg-go.
#
# awg-kmod.sh install        исходники в DKMS и сборка под текущее и более новые ядра с заголовками
# awg-kmod.sh build <ядро>   сборка под одно ядро
# awg-kmod.sh has <ядро>     код 0, если модуль под ядро собран и установлен
# awg-kmod.sh prune          удалить ядра новее текущего, под которые модуль не собрался
#                            (чтобы после перезагрузки не загрузиться в ядро без модуля)
set -u
export LC_ALL=C

NAME=amneziawg
VERSION=1.0.0-az
COMMIT=4569c4c67f3a57414969260cafbbd04694fbaae0
REPO=https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git
SRC=/usr/src/$NAME-$VERSION
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PATCH=$HERE/udp-tunnel-compat.patch
HOOK=/etc/kernel/postinst.d/zz-amneziawg
LOG=/var/log/awg-kmod.log

log() {
	echo "$(date '+%F %T') $*" >> "$LOG"
	echo "awg-kmod: $*"
}

has() {
	dkms status -m "$NAME" -v "$VERSION" -k "$1" 2>/dev/null | grep -q ': installed'
}

build() {
	local K="$1"
	if [[ ! -d "/lib/modules/$K/build" ]]; then
		log "$K: нет заголовков ядра (linux-headers-$K), модуль не собран"
		return 1
	fi
	if has "$K"; then
		return 0
	fi
	if dkms install -m "$NAME" -v "$VERSION" -k "$K" >> "$LOG" 2>&1; then
		log "$K: модуль собран"
		return 0
	fi
	dkms remove -m "$NAME" -v "$VERSION" -k "$K" >> "$LOG" 2>&1
	log "$K: модуль НЕ собрался (подробности в $LOG), на этом ядре AmneziaWG работает через amneziawg-go"
	return 1
}

source_id() {
	echo "$COMMIT $(sha256sum "$PATCH" | cut -c1-16)"
}

install_source() {
	# Пакет amneziawg-dkms из PPA Amnezia собирается под каждое ядро с AUTOINSTALL=yes и роняет dpkg,
	# если сборка не удалась (7.0.0-38). Модуль тот же, поэтому пакет заменяем своим DKMS.
	if dpkg -s amneziawg-dkms &>/dev/null; then
		log "удаляю пакет amneziawg-dkms из PPA (заменяется модулем из исходников)"
		DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms >> "$LOG" 2>&1 || dpkg --purge --force-all amneziawg-dkms >> "$LOG" 2>&1
	fi
	local OTHER
	for OTHER in $(dkms status -m "$NAME" 2>/dev/null | sed -n "s|^$NAME/\([^,:]*\)[,:].*|\1|p" | sort -u); do
		[[ "$OTHER" == "$VERSION" ]] && continue
		dkms remove -m "$NAME" -v "$OTHER" --all >> "$LOG" 2>&1
	done
	if [[ -f "$SRC/.az-source" && "$(cat "$SRC/.az-source")" == "$(source_id)" ]] && dkms status -m "$NAME" -v "$VERSION" 2>/dev/null | grep -q .; then
		return 0
	fi
	local TMP
	TMP="$(mktemp -d)"
	if ! git clone -q "$REPO" "$TMP/src" >> "$LOG" 2>&1 || ! git -C "$TMP/src" checkout -q "$COMMIT" >> "$LOG" 2>&1; then
		log "не удалось скачать исходники модуля ($REPO)"
		rm -rf "$TMP"
		return 1
	fi
	if ! git -C "$TMP/src" apply "$PATCH" >> "$LOG" 2>&1; then
		log "не удалось применить $PATCH"
		rm -rf "$TMP"
		return 1
	fi
	dkms remove -m "$NAME" -v "$VERSION" --all >> "$LOG" 2>&1
	rm -rf "$SRC"
	cp -a "$TMP/src/src" "$SRC"
	rm -rf "$TMP"
	make -C "$SRC" clean >> "$LOG" 2>&1
	sed -i -e "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"$VERSION\"/" -e 's/^AUTOINSTALL=.*/AUTOINSTALL=no/' -e '/^REMAKE_INITRD=/d' "$SRC/dkms.conf"
	source_id > "$SRC/.az-source"
	if ! dkms add -m "$NAME" -v "$VERSION" >> "$LOG" 2>&1; then
		log "dkms add не удался"
		return 1
	fi
	log "исходники модуля $NAME/$VERSION ($COMMIT) добавлены в DKMS"
}

install_hook() {
	cat > "$HOOK" <<EOF
#!/bin/sh
# Сборка модуля AmneziaWG под новое ядро (awg-kmod.sh). Ошибка сборки не должна ронять установку ядра.
[ -x $HERE/awg-kmod.sh ] && $HERE/awg-kmod.sh build "\$1" >/dev/null 2>&1
exit 0
EOF
	chmod 755 "$HOOK"
}

kernel_newer() {
	[[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

prune() {
	local RUNNING K KBASE PKGS
	RUNNING="$(uname -r)"
	for K in /lib/modules/*/; do
		K="$(basename "$K")"
		[[ -d "/lib/modules/$K/kernel" ]] || continue
		kernel_newer "$K" "$RUNNING" || continue
		has "$K" && continue
		KBASE="${K%-*}"
		# linux-image-7.0.0-38-generic, linux-modules(-extra)-..., linux-headers-..., linux-hwe-7.0-headers-7.0.0-38
		PKGS="$(dpkg-query -W -f '${Package} ${Status}\n' 'linux-*' 2>/dev/null \
			| awk -v k="-$K" -v b="-$KBASE" '/ installed$/ { n = $1; if (substr(n, length(n) - length(k) + 1) == k || substr(n, length(n) - length(b) + 1) == b) print n }' \
			| tr '\n' ' ')"
		[[ -z "$PKGS" ]] && continue
		log "ядро $K без модуля AmneziaWG: удаляю ($PKGS), остаёмся на ядре с модулем"
		DEBIAN_FRONTEND=noninteractive apt-get purge -y $PKGS >> "$LOG" 2>&1 || log "не удалось удалить $PKGS"
	done
}

case "${1:-}" in
	install)
		command -v dkms &>/dev/null || { log "dkms не установлен"; exit 1; }
		install_source || exit 1
		install_hook
		RC=0
		# Старые ядра не загружаются (загрузчик берёт новейшее), собирать под них незачем
		for K in /lib/modules/*/; do
			K="$(basename "$K")"
			[[ -d "/lib/modules/$K/build" ]] || continue
			[[ "$K" == "$(uname -r)" ]] || kernel_newer "$K" "$(uname -r)" || continue
			build "$K" || { [[ "$K" == "$(uname -r)" ]] && RC=1; }
		done
		exit $RC
		;;
	build)
		[[ -n "${2:-}" ]] || exit 2
		[[ -f "$SRC/dkms.conf" ]] || exit 1
		build "$2"
		;;
	has)
		has "${2:-$(uname -r)}"
		;;
	prune)
		prune
		;;
	*)
		echo "usage: $0 install | build <kernel> | has [kernel] | prune"
		exit 2
		;;
esac
