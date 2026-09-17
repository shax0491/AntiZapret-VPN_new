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
	#
	# Читаем строго из /dev/tty, а не из fd0: скрипт обычно запускают как
	# `curl ... setup.sh | bash`, и fd0 там - это тот же пайп, из которого
	# ВНЕШНИЙ bash ещё дочитывает хвост setup.sh. Если тут читать из fd0,
	# Enter/Ctrl+C съедает байты из ещё не прочитанного скрипта, и внешний
	# bash падает с "syntax error near unexpected token" на случайном месте.
	echo
	read -rp 'Press Enter for the next test, Ctrl+C to stop diagnostics: ' -e _ < /dev/tty || { echo; exit 130; }
}

# Каждый инструмент ниже принудительно ограничен IPv4 (-4 / --ipv4, где
# поддерживается): на этих серверах IPv6 отключён на уровне ядра ещё до
# запуска диагностики, и без явного форсирования IPv4 некоторые инструменты
# всё равно пытаются резолвить AAAA и виснут в ожидании таймаута.
#
# ipregion.vrnt.xyz и Check.Place (ip.check.place / check.place) исключены:
# оба дублируют гео/ASN/блокировки, которые и так видны в выводе bench.sh
# ниже, а Check.Place к тому же всегда открывает собственное вложенное
# интерактивное меню ("Welcome to XY Series Scripts" -> "IP Quality Check
# Script") и не выходит из него сам - под non-interactive-паузой run_check
# это просто виснет до ручного вмешательства.

# speedtest.artydev.ru - тот же bench.sh (Teddysun), но зеркало с рекламными
# баннерами поверх результатов; используется официальный bench.sh.
run_check 'Общий бенчмарк сервера (bench.sh)' \
	bash -c 'curl -4 -fsSL bench.sh | bash'

run_check 'CPU benchmark (sysbench)' \
	bash -c 'command -v sysbench &>/dev/null || apt-get install -y sysbench; sysbench cpu run --threads=1 --time=10'

echo
echo 'Server diagnostics finished.'
exit 0
