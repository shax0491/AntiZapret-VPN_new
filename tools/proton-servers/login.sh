#!/bin/bash
# Первый вход в аккаунт Proton для автоподбора серверов (или повторный, если сессия истекла).
# Спросит пароль и код 2FA, сохранит сессию в /root/.protonvpn-session.json (продлевается сама)
# и сразу обновит список серверов. Пароль нигде не сохраняется.
set -e
cd /opt/proton-auto
if ! grep -q '^PROTON_USER=.' env 2>/dev/null; then
	read -rp 'Имя пользователя Proton (логин или почта): ' U
	echo "PROTON_USER=$U" > env
	chmod 600 env
fi
. ./env
HOME=/root ./bin/protonvpn-wg-confgen --username "$PROTON_USER" --clear-session --list-servers --p2p-only=false | tail -3
./fetch.py
