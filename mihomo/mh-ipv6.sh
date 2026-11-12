#!/usr/bin/env bash
# mh-ipv6.sh — флаги IPv6 для сборки конфигов mihomo в /opt/mh-app.
#
# Использование: mh-ipv6.sh on|off|status [home|work]
#   без цели — home. status без цели показывает оба флага.
#
# home → /opt/mh-app/ipv6.flag, work → /opt/mh-app/ipv6-work.flag (1/0),
# затем build_configs.py пересобирает конфиги (строки ipv6: в шаблоне).

set -u

MODE="${1:-}"
TARGET="${2:-}"
APP_DIR="/opt/mh-app"
BUILDER="$APP_DIR/build_configs.py"

usage() {
    echo "Использование: mh-ipv6.sh on|off|status [home|work]" >&2
    echo "  on/off без цели = home; status без цели показывает home и work" >&2
    exit 2
}

flag_file() {
    case "$1" in
        home) echo "$APP_DIR/ipv6.flag" ;;
        work) echo "$APP_DIR/ipv6-work.flag" ;;
    esac
}

show() {
    local f; f=$(flag_file "$1")
    echo "$1: ipv6=$([[ -f $f ]] && cat "$f" || echo 0)"
}

[[ $MODE == on || $MODE == off || $MODE == status ]] || usage
[[ -z $TARGET || $TARGET == home || $TARGET == work ]] || usage
[[ -d $APP_DIR ]] || { echo "Ошибка: нет $APP_DIR на этом хосте." >&2; exit 1; }

if [[ $MODE == status ]]; then
    if [[ -n $TARGET ]]; then show "$TARGET"; else show home; show work; fi
    exit 0
fi

TARGET="${TARGET:-home}"
if [[ $MODE == on ]]; then
    echo "Внимание: включай IPv6 только если провайдер выдаёт префикс (PD) и на роутере" >&2
    echo "IPv6 тоже заворачивается в mihomo (ip6tables TPROXY). Иначе IPv6 идёт мимо." >&2
    echo 1 > "$(flag_file "$TARGET")"
else
    echo 0 > "$(flag_file "$TARGET")"
fi

python3 "$BUILDER" || { echo "Ошибка: build_configs.py упал." >&2; exit 1; }
show "$TARGET"
echo "Конфиги пересобраны."
