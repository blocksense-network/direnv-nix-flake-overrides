import os
import shutil
import subprocess
import sys
from packaging.version import Version
import pytest


def get_bash_version() -> Version | None:
    try:
        bash_bin = os.environ.get("BASH_BINARY", "bash")
        cp = subprocess.run(
            [bash_bin, "-lc", "printf '%s.%s' ${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"],
            text=True,
            capture_output=True,
            check=False,
        )
        if cp.returncode == 0 and cp.stdout.strip():
            return Version(cp.stdout.strip())
    except Exception:
        return None
    return None


bash_version = get_bash_version()


def pytest_collection_modifyitems(config, items):
    # Skip all tests if bash is too old for nameref
    if not bash_version or bash_version < Version("4.4"):
        skip = pytest.mark.skip(reason="bash >= 4.4 required for plugin tests")
        for item in items:
            item.add_marker(skip)


@pytest.fixture()
def ensure_tmp_env(monkeypatch):
    # Prevent direnv from mutating the developer's environment during tests
    monkeypatch.setenv("DIRENV_LOG_FORMAT", "")
    # Ensure non-interactive
    monkeypatch.setenv("CI", "1")
    yield
