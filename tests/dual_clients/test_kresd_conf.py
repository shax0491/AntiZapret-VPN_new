"""Закоммиченный kresd.conf должен читать карту dual-клиентов (Задача 19), а не только локальная копия узла."""
import os
import shutil
import subprocess

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def test_committed_kresd_reads_dual_map_per_client():
    git = shutil.which("git")
    if not git:
        pytest.skip("git не найден")
    p = subprocess.run([git, "-C", ROOT, "show", "HEAD:setup/etc/knot-resolver/kresd.conf"], capture_output=True)
    if p.returncode:
        pytest.skip("kresd.conf нет в HEAD")
    conf = p.stdout.decode("utf-8")
    assert "/etc/knot-resolver/dual-clients.txt" in conf and "local function is_dual(a)" in conf
    rule = [ln for ln in conf.splitlines() if "nodata_answer end" in ln and "10%.9%.0%." in ln]
    assert len(rule) == 1
    assert "not is_dual(a)" in rule[0] and "awg1_dual()" not in rule[0]
    assert "10%.29%.0%." in rule[0]  # подсеть 10.29.0.x по-прежнему без AAAA
