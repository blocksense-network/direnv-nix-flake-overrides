import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGIN = REPO_ROOT / "plugin" / "flake-overrides.bash"


def have(cmd: str) -> bool:
    return shutil.which(cmd) is not None


pytestmark = pytest.mark.skipif(
    not have("direnv"), reason="direnv not installed; skipping integration test"
)


def run(cmd: list[str], cwd: Path | None = None, env: dict | None = None) -> subprocess.CompletedProcess:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=merged_env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_direnv_exec_loads_plugin_and_emits_args(tmp_path: Path):
    project = tmp_path
    # Write .env
    (project / ".env").write_text(
        "NIX_FLAKE_OVERRIDE_INPUTS='mylib=./lib;foo/nixpkgs=github:NixOS/nixpkgs/nixos-24.05'\n"
        "NIX_FLAKE_OVERRIDE_FLAKES='nixpkgs=github:NixOS/nixpkgs/nixos-24.05'\n"
    )
    # Create a local directory to be resolved to path:/ABS
    (project / "lib").mkdir()
    # Write .envrc that sources the plugin directly
    (project / ".envrc").write_text(
        f"source '{PLUGIN}'\n"
        "dotenv_if_exists .env\n"
        "flake_overrides_install_wrappers .\n"
        "PATH_add .direnv/bin\n"
    )

    # direnv allow and then exec a command that prints the quoted args
    cp_allow = run(["direnv", "allow", str(project)])
    assert cp_allow.returncode == 0, cp_allow.stderr

    cp = run(["direnv", "exec", str(project), "bash", "-lc", "flake_override_args_quoted"])
    assert cp.returncode == 0, cp.stderr
    out = cp.stdout.strip().split()

    # Expect both input and flake overrides present
    assert out[0] == "--override-input"
    assert out[1] == "mylib"
    assert out[2].startswith("path:/")
    assert "--override-flake" in out

    # Ensure wrappers exist in the project
    for name in ["ndev", "nbuild", "nrun"]:
        p = project / ".direnv" / "bin" / name
        assert p.exists() and os.access(p, os.X_OK)
