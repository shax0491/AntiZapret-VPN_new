#!/bin/bash
#
# Предстартовая диагностика сервера AntiZapret VPN.
#
# Поочерёдно запускает набор сторонних open-source утилит для проверки сети,
# гео/блокировок и производительности сервера. Каждый шаг можно прервать
# через Ctrl+C - скрипт перейдёт к следующему пункту, а не завершится целиком.
#
export LC_ALL=C
set -uo pipefail

echo 'Server diagnostics for AntiZapret VPN:'

# Ctrl+C должен убивать только текущий дочерний процесс (например, зависший
# speedtest), а не весь check_server.sh - иначе пользователь не сможет
# пропустить один долгий тест и перейти к следующим.
run_check() {
	local title="$1"
	shift

	echo
	echo "--- $title ---"

	trap '' INT
	( trap - INT; "$@" )
	local rc=$?
	trap - INT

	if [[ $rc -eq 130 ]]; then
		echo "[$title] прервано пользователем (Ctrl+C)"
	elif [[ $rc -ne 0 ]]; then
		echo "[$title] завершено с кодом $rc"
	fi

	# Пауза между тестами: без неё вывод одного теста тут же перекрывается
	# следующим и прочитать результат не успеваешь. Enter - продолжить,
	# Ctrl+C - пропустить оставшиеся тесты и выйти сразу.
	echo
	read -rp 'Enter - следующий тест, Ctrl+C - завершить диагностику: ' -e _ || { echo; exit 130; }
}

run_check 'Регион и гео-IP (ipregion.vrnt.xyz)' \
	bash -c 'bash <(wget -qO- https://ipregion.vrnt.xyz)'

run_check 'Скорость до России (speedtest.artydev.ru)' \
	bash -c 'wget -qO- speedtest.artydev.ru | bash'

# -4 принудительно выбирает IPv4-only и убирает интерактивный диалог выбора
# сети (Dual Stack/IPv4/IPv6), который иначе всплывает поверх текста и его
# не видно за автопрокруткой; -y отключает вопросы про установку зависимостей.
run_check 'Блокировки за рубежом (Check.Place)' \
	bash -c 'bash <(curl -Ls ip.check.place) -4 -y -E'

run_check 'Качество IP: прокси/абуз (Check.Place)' \
	bash -c 'bash <(curl -Ls https://check.place) -4 -y -EI'

run_check 'Общий бенчмарк сервера (bench.sh)' \
	bash -c 'wget -qO- bench.sh | bash'

run_check 'CPU benchmark (sysbench)' \
	bash -c 'command -v sysbench &>/dev/null || apt-get install -y sysbench; sysbench cpu run --threads=1 --time=10'

echo
echo 'Server diagnostics finished.'
exit 0
