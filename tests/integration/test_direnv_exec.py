import os
import subprocess
import tempfile
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGIN = REPO_ROOT / "plugin" / "flake-overrides.bash"


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
    # Write .envrc that ensures modern bash via nix dev shell first
    (project / ".envrc").write_text(
        "use flake\n"
        f"source '{PLUGIN}'\n"
        "dotenv_if_exists .env\n"
        "flake_overrides_install_wrappers .\n"
        "PATH_add .direnv/bin\n"
    )

    # direnv allow and then check wrapper content
    cp_allow = run(["direnv", "allow", str(project)])
    assert cp_allow.returncode == 0, cp_allow.stderr
    # Create wrappers inside the managed environment (avoid relying on .envrc side-effects)
    cp_prep = run([
        "direnv", "exec", str(project), "bash", "-lc",
        f"source '{PLUGIN}'; cd \"$DIRENV_DIR\"; flake_overrides_install_wrappers .; flake_override_args_quoted",
    ])
    assert cp_prep.returncode == 0, cp_prep.stderr
    out = cp_prep.stdout.strip().split()
    assert out, f"no output from flake_override_args_quoted; stderr: {cp_prep.stderr}"
    assert out[0] == "--override-input" and out[1] == "mylib" and out[2].startswith("path:/")
    assert "--override-flake" in out

    # Ensure wrappers exist in the project and contain path:/ coercion
    cp_ls = run(["direnv", "exec", str(project), "bash", "-lc", "ls -1 .direnv/bin"])
    assert cp_ls.returncode == 0, cp_ls.stderr
    names = set(cp_ls.stdout.strip().splitlines())
    assert {"ndev", "nbuild", "nrun"}.issubset(names)
    cp_cat = run(["direnv", "exec", str(project), "bash", "-lc", "sed -n '1,80p' .direnv/bin/ndev"])
    assert cp_cat.returncode == 0, cp_cat.stderr
    content = cp_cat.stdout
    assert "exec nix develop" in content
    assert "path:/" in content
