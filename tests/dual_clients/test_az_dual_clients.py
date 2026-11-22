# -*- coding: utf-8 -*-
"""pytest для az-dual-clients.sh: карта dual-клиентов AWG3 для kresd и её установка через setup.sh.

Скрипт запускается как в панели (`sh az-dual-clients.sh`), пути подменяются переменными AZ_DUAL_*;
ничего за пределами tmp_path не читается и не пишется. Нужен Linux (sh, awk, mktemp, sort, cmp)."""

import os
import re
import shutil
import stat
import subprocess
import sys

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPT = os.path.join(ROOT, "setup", "root", "antizapret", "az-dual-clients.sh")
SETUP_SH = os.path.join(ROOT, "setup.sh")

pytestmark = pytest.mark.skipif(sys.platform == "win32" or not shutil.which("sh"), reason="нужен Linux/sh")

HEAD = "[Interface]\nPrivateKey = x\nAddress = 10.9.0.1/24\nListenPort = 51821\n"


def peer(name, allowed):
    return f"\n[Peer]\n# {name}\nPublicKey = k_{name}\nPresharedKey = p\nAllowedIPs = {allowed}\n"


@pytest.fixture
def node(tmp_path):
    d = tmp_path / "node"
    (d / "map").mkdir(parents=True)
    return types_ns(
        profile=d / "ipv6-profile.txt",
        conf=d / "awg1.conf",
        map=d / "map" / "dual-clients.txt",
        mapdir=d / "map",
    )


def types_ns(**kw):
    class NS:
        pass

    ns = NS()
    ns.__dict__.update(kw)
    return ns


def run(node, path=None):
    env = dict(os.environ, AZ_DUAL_PROFILE=str(node.profile), AZ_DUAL_AWG_CONF=str(node.conf), AZ_DUAL_MAP=str(node.map),
               AZ_DUAL_SETUP=str(node.map.parent.parent / "setup"))  # нет файла setup: профиль по умолчанию dual, как в client.sh
    if path:
        env["PATH"] = path + os.pathsep + env["PATH"]
    return subprocess.run(["sh", SCRIPT], env=env, capture_output=True, text=True)


def ips(node):
    return node.map.read_text().split()


def leftovers(node):
    return sorted(p.name for p in node.mapdir.iterdir() if p.name != node.map.name)


def test_dual_in_map_ipv4_only_and_unknown_not(node):
    node.profile.write_text("# комментарий\ndev dual\nold ipv4\nopenvpn_only dual\n")
    node.conf.write_text(
        HEAD + peer("dev_az", "10.9.0.2/32, fd29:7::2/128") + peer("old_az", "10.9.0.3/32") + peer("stranger_az", "10.9.0.4/32")
    )
    r = run(node)
    assert r.returncode == 0, r.stderr
    assert ips(node) == ["10.9.0.2"]  # openvpn_only dual без пира AWG3 - не ошибка и не запись


def test_default_profile_dual_client_without_profile_line_is_in_map(node):
    # клиент создан с профилем «по умолчанию» (строки в ipv6-profile.txt нет): IPv6 на сервере есть -> должен попасть в карту
    node.profile.write_text("old ipv4\n")
    node.conf.write_text(
        HEAD + peer("new_az", "10.9.0.2/32, fd29:7::2/128, fd29:7:2::/64") + peer("new_vpn", "10.9.1.2/32, fd28:7::2/128")
        + peer("old_az", "10.9.0.3/32, fd29:7::3/128") + peer("legacy_az", "10.9.0.4/32")
    )
    assert run(node).returncode == 0
    assert ips(node) == ["10.9.0.2"]  # old - явный ipv4, legacy - без IPv6 на сервере, vpn-слой в карту не идёт


def test_default_profile_ipv4_needs_explicit_dual_line(node):
    setup = node.map.parent.parent / "setup"
    setup.write_text("ENABLE_IPV6=y\nIPV6_PROFILE_DEFAULT='ipv4'\n")
    node.profile.write_text("dev dual\n")
    node.conf.write_text(HEAD + peer("dev_az", "10.9.0.2/32, fd29:7::2/128") + peer("new_az", "10.9.0.3/32, fd29:7::3/128"))
    assert run(node).returncode == 0
    assert ips(node) == ["10.9.0.2"]


def test_paired_record_only_split_ip_and_name_without_suffix(node):
    node.profile.write_text("dev dual\nplain dual\n")
    node.conf.write_text(
        HEAD + peer("dev_az", "10.9.0.2/32, fd29:7::2/128") + peer("dev_vpn", "10.9.1.2/32") + peer("plain", "10.9.0.5/32")
    )
    assert run(node).returncode == 0
    assert ips(node) == ["10.9.0.2", "10.9.0.5"]


def test_deleted_client_disappears_and_others_stay(node):
    node.profile.write_text("a dual\nb dual\n")
    node.conf.write_text(HEAD + peer("a_az", "10.9.0.2/32") + peer("b_az", "10.9.0.3/32"))
    assert run(node).returncode == 0 and ips(node) == ["10.9.0.2", "10.9.0.3"]
    node.profile.write_text("b dual\n")  # a удалён: строка профиля и пир сняты
    node.conf.write_text(HEAD + peer("b_az", "10.9.0.3/32"))
    assert run(node).returncode == 0
    assert ips(node) == ["10.9.0.3"]


def test_rerun_is_idempotent_without_duplicates_or_rewrite(node):
    node.profile.write_text("dev dual\ndev dual\n")  # повтор строки профиля
    node.conf.write_text(HEAD + peer("dev_az", "10.9.0.2/32") + peer("dev", "10.9.0.2/32"))
    assert run(node).returncode == 0
    assert ips(node) == ["10.9.0.2"]
    before = node.map.stat()
    assert run(node).returncode == 0
    after = node.map.stat()
    assert ips(node) == ["10.9.0.2"]
    assert (before.st_ino, before.st_mtime_ns) == (after.st_ino, after.st_mtime_ns)  # без изменений - без перезаписи
    assert leftovers(node) == []


@pytest.mark.parametrize("conf", [None, "", "# мусор\nAddress = 10.9.0.1/24\n"], ids=["missing", "empty", "no-interface"])
def test_missing_or_damaged_awg1_conf_keeps_good_map(node, conf):
    node.map.write_text("10.9.0.2\n10.9.0.3\n")
    node.profile.write_text("dev dual\n")
    if conf is not None:
        node.conf.write_text(conf)
    r = run(node)
    assert r.returncode == 1
    assert "az-dual-clients:" in r.stderr and "awg1.conf" in r.stderr
    assert node.map.read_text() == "10.9.0.2\n10.9.0.3\n"
    assert leftovers(node) == []


@pytest.mark.skipif(os.geteuid() == 0, reason="root читает любой файл")
def test_unreadable_profile_keeps_good_map(node):
    node.map.write_text("10.9.0.2\n")
    node.conf.write_text(HEAD + peer("dev_az", "10.9.0.2/32"))
    node.profile.write_text("dev dual\n")
    node.profile.chmod(0)
    r = run(node)
    node.profile.chmod(0o600)
    assert r.returncode == 1 and "ipv6-profile.txt" in r.stderr
    assert node.map.read_text() == "10.9.0.2\n"


def test_no_profile_file_gives_empty_map(node):
    node.conf.write_text(HEAD + peer("dev_az", "10.9.0.2/32"))
    assert run(node).returncode == 0
    assert node.map.read_text() == ""


def shim(tmp_path, name, body="exit 1"):
    d = tmp_path / "shim"
    d.mkdir(exist_ok=True)
    f = d / name
    f.write_text(f"#!/bin/sh\n{body}\n")
    f.chmod(0o755)
    return str(d)


@pytest.mark.parametrize("tool", ["mv", "sort"])
def test_write_failure_leaves_no_partial_file_and_keeps_map(node, tmp_path, tool):
    node.map.write_text("10.9.0.9\n")
    node.profile.write_text("dev dual\n")
    node.conf.write_text(HEAD + peer("dev_az", "10.9.0.2/32"))
    r = run(node, path=shim(tmp_path, tool))
    assert r.returncode == 2
    assert "az-dual-clients:" in r.stderr
    assert node.map.read_text() == "10.9.0.9\n"
    assert leftovers(node) == []  # временный файл убран


def test_missing_map_directory_is_error_not_a_stray_file(node, tmp_path):
    node.profile.write_text("dev dual\n")
    node.conf.write_text(HEAD + peer("dev_az", "10.9.0.2/32"))
    node.map = tmp_path / "no_such_dir" / "dual-clients.txt"
    r = run(node)
    assert r.returncode == 2 and "az-dual-clients:" in r.stderr
    assert not (tmp_path / "no_such_dir").exists()


def test_map_path_that_is_a_directory_is_error_and_nothing_is_moved_into_it(node):
    node.profile.write_text("dev dual\n")
    node.conf.write_text(HEAD + peer("dev_az", "10.9.0.2/32"))
    node.map = node.mapdir  # mv положил бы временный файл внутрь каталога и вернул успех
    r = run(node)
    assert r.returncode == 2 and "каталог" in r.stderr
    assert list(node.mapdir.iterdir()) == []


def test_existing_mode_is_preserved_and_new_map_is_world_readable(node):
    node.profile.write_text("dev dual\n")
    node.conf.write_text(HEAD + peer("dev_az", "10.9.0.2/32"))
    assert run(node).returncode == 0
    assert stat.S_IMODE(node.map.stat().st_mode) == 0o644  # kresd читает не от root
    node.map.chmod(0o640)
    node.conf.write_text(HEAD + peer("dev_az", "10.9.0.2/32") + peer("x_az", "10.9.0.7/32"))
    node.profile.write_text("dev dual\nx dual\n")
    assert run(node).returncode == 0 and ips(node) == ["10.9.0.2", "10.9.0.7"]
    assert stat.S_IMODE(node.map.stat().st_mode) == 0o640


# --- установка: скрипт отслеживается Git и раскладывается тем же кодом setup.sh для чистой установки и --update ---

def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True)


def test_script_is_tracked_executable_with_lf_endings():
    if not shutil.which("git") or git("rev-parse", "--git-dir").returncode != 0:
        pytest.skip("нет git-репозитория")
    r = git("ls-files", "-s", "setup/root/antizapret/az-dual-clients.sh")
    assert r.stdout.startswith("100755 "), f"не отслеживается или не executable: {r.stdout!r}"
    assert b"\r" not in open(SCRIPT, "rb").read()


def _staging_commands():
    """Точные команды setup.sh, которые раскладывают клон репо по системе (одни и те же для установки и --update)."""
    lines = open(SETUP_SH, encoding="utf-8").read().splitlines()
    wanted = [
        r"^find /tmp/antizapret -type f -exec chmod 644 \{\} \+$",
        r"^find /tmp/antizapret -type d -exec chmod 755 \{\} \+$",
        r"^find /tmp/antizapret/setup/root/antizapret -type f -exec chmod \+x \{\} \+$",
        r"^rm -rf /root/antizapret$",
        r"^cp -r /tmp/antizapret/setup/\* /$",
    ]
    found = []
    for rx in wanted:
        hits = [ln for ln in lines if re.match(rx, ln)]  # в начале строки: вне if/--update-веток
        assert len(hits) == 1, f"setup.sh изменён, пересмотрите установку az-dual-clients.sh: {rx}"
        found.append(hits[0])
    return found


def _install(tmp_path, preexisting=None):
    stage = tmp_path / "stage" / "antizapret"
    shutil.copytree(os.path.join(ROOT, "setup"), stage / "setup", ignore=shutil.ignore_patterns("__pycache__"))
    root = tmp_path / "root"
    (root / "root" / "antizapret").mkdir(parents=True)
    for name, (text, mode) in (preexisting or {}).items():
        f = root / "root" / "antizapret" / name
        f.write_text(text)
        f.chmod(mode)
    cmds = []
    for ln in _staging_commands():
        ln = ln.replace("/tmp/antizapret", str(stage))
        ln = ln.replace("rm -rf /root/antizapret", f"rm -rf {root}/root/antizapret")
        ln = re.sub(r" /$", f" {root}/", ln)
        cmds.append(ln)
    assert all(str(tmp_path) in c for c in cmds), cmds  # ни одна команда не должна смотреть на настоящие /root и /
    r = subprocess.run(["sh", "-c", "set -e\n" + "\n".join(cmds)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return root / "root" / "antizapret" / "az-dual-clients.sh"


def test_fresh_install_lays_out_executable_script(tmp_path):
    dst = _install(tmp_path)
    assert dst.is_file() and os.access(dst, os.X_OK)
    assert dst.read_bytes() == open(SCRIPT, "rb").read()


def test_update_replaces_old_script_and_keeps_it_executable(tmp_path):
    # на узле лежит ручная неисполняемая копия со старым содержимым (как LV1 до интеграции)
    dst = _install(tmp_path, {"az-dual-clients.sh": ("#!/bin/sh\necho old\n", 0o600)})
    assert os.access(dst, os.X_OK) and stat.S_IMODE(dst.stat().st_mode) & 0o111
    assert b"echo old" not in dst.read_bytes()
    assert dst.read_bytes() == open(SCRIPT, "rb").read()


def test_installation_does_not_run_the_script(tmp_path):
    dst = _install(tmp_path)
    assert not (dst.parent / "dual-clients.txt").exists()  # раскладка файлов карту не строит
