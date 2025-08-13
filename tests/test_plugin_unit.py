import os
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PLUGIN = REPO_ROOT / "plugin" / "flake-overrides.bash"


def run_bash(script: str, cwd: Path | None = None, env: dict | None = None) -> subprocess.CompletedProcess:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    bash_script = f"set -euo pipefail\nlog_status(){{ :; }}\nsource '{PLUGIN}'\n{script}\n"
    return subprocess.run(
        ["bash", "-lc", bash_script],
        cwd=str(cwd) if cwd else None,
        env=merged_env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_no_env_vars_prints_nothing():
    cp = run_bash("flake_override_args_quoted")
    assert cp.returncode == 0
    assert cp.stdout.strip() == ""


def test_inputs_parsing_to_override_input_pairs(tmp_path: Path):
    # Create a local directory to be resolved to path:/ABS
    (tmp_path / "my-lib").mkdir()
    env = {
        "NIX_FLAKE_OVERRIDE_INPUTS": "mylib=my-lib;foo/nixpkgs=github:NixOS/nixpkgs/nixos-24.05",
    }
    cp = run_bash("flake_override_args_quoted", cwd=tmp_path, env=env)
    assert cp.returncode == 0, cp.stderr
    out = cp.stdout.strip().split()
    # Expect flags and values present in order (inputs first)
    assert out[0] == "--override-input"
    assert out[1] == "mylib"
    assert out[2].startswith("path:/")
    assert out[3] == "--override-input"
    assert out[4] == "foo/nixpkgs"
    assert out[5] == "github:NixOS/nixpkgs/nixos-24.05"


def test_flake_overrides_to_override_flake_pairs():
    env = {
        "NIX_FLAKE_OVERRIDE_FLAKES": "nixpkgs=github:NixOS/nixpkgs/nixos-24.05;myfork=github:blocksense-network/fork",
    }
    cp = run_bash("flake_override_args_quoted", env=env)
    assert cp.returncode == 0, cp.stderr
    out = cp.stdout.strip().split()
    # Since only flakes are provided, first pair should be --override-flake nixpkgs ...
    assert out[:3] == ["--override-flake", "nixpkgs", "github:NixOS/nixpkgs/nixos-24.05"]
    assert out[3:6] == ["--override-flake", "myfork", "github:blocksense-network/fork"]


def test_wrapper_script_generation(tmp_path: Path):
    env = {
        "NIX_FLAKE_OVERRIDE_INPUTS": "foo=./bar",
    }
    (tmp_path / "bar").mkdir()
    script = "flake_overrides_install_wrappers . develop build run; ls -1 .direnv/bin; printf '\n'; for f in .direnv/bin/*; do echo '---'; echo \"$f\"; cat \"$f\"; done"
    cp = run_bash(script, cwd=tmp_path, env=env)
    assert cp.returncode == 0, cp.stderr
    listing, _, blobs = cp.stdout.partition("\n---\n")
    names = set(listing.strip().splitlines())
    assert {"ndev", "nbuild", "nrun"}.issubset(names)
    # Ensure files are executable and contain an exec nix line
    for name in ["ndev", "nbuild", "nrun"]:
        p = tmp_path / ".direnv" / "bin" / name
        assert p.exists()
        assert os.access(p, os.X_OK)
        content = p.read_text()
        assert "exec nix" in content
