import os
import pytest


@pytest.fixture()
def ensure_tmp_env(monkeypatch):
    # Prevent direnv from mutating the developer's environment during tests
    monkeypatch.setenv("DIRENV_LOG_FORMAT", "")
    # Ensure non-interactive
    monkeypatch.setenv("CI", "1")
    yield
