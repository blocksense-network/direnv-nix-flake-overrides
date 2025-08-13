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
    # Provide a minimal flake so we can guarantee Bash 5 via nix develop
    (project / "flake.nix").write_text(
        '{\n'
        '  description = "tmp non-interactive test flake";\n'
        '  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";\n'
        '  outputs = { self, nixpkgs }:\n'
        '    let\n'
        '      system = builtins.currentSystem;\n'
        '      pkgs = import nixpkgs { inherit system; };\n'
        '    in {\n'
        '      devShells.${system}.default = pkgs.mkShell { };\n'
        '    };\n'
        '}\n'
    )
    # Use direnv exec but control the shell: cd into project, source plugin, and export envs
    cp_args = run([
        "direnv", "exec", str(project), "nix", "develop", "-c", "bash", "-lc",
        f"cd '{project}'; log_status(){{ :; }}; source '{PLUGIN}'; export NIX_FLAKE_OVERRIDE_INPUTS=\"mylib=./lib;foo/nixpkgs=github:NixOS/nixpkgs/nixos-24.05\"; export NIX_FLAKE_OVERRIDE_FLAKES=\"nixpkgs=github:NixOS/nixpkgs/nixos-24.05\"; flake_override_args_quoted",
    ])
    assert cp_args.returncode == 0, cp_args.stderr
    out = cp_args.stdout.strip().split()
    assert out, f"no output from flake_override_args_quoted; stderr: {cp_args.stderr}"
    assert out[0] == "--override-input" and out[1] == "mylib"
    # Accept either coerced path:/ABS or raw relative path depending on shell cwd
    if not out[2].startswith("path:/"):
        # Ensure the relative directory exists from the managed dir perspective
        cp_chk = run(["direnv", "exec", str(project), "bash", "-lc", f"test -d '{out[2]}'"])
        assert cp_chk.returncode == 0, f"expected directory {out[2]} to exist"
    assert "--override-flake" in out

    # Ensure wrappers exist in the project and contain path:/ coercion
    # Generate wrappers within the managed shell
    _ = run([
        "direnv", "exec", str(project), "nix", "develop", "-c", "bash", "-lc",
        f"cd '{project}'; log_status(){{ :; }}; source '{PLUGIN}'; export NIX_FLAKE_OVERRIDE_INPUTS=\"mylib=./lib;foo/nixpkgs=github:NixOS/nixpkgs/nixos-24.05\"; export NIX_FLAKE_OVERRIDE_FLAKES=\"nixpkgs=github:NixOS/nixpkgs/nixos-24.05\"; flake_overrides_install_wrappers .",
    ])
    cp_ls = run(["direnv", "exec", str(project), "bash", "-lc", f"cd '{project}'; ls -1 .direnv/bin"])
    assert cp_ls.returncode == 0, cp_ls.stderr
    names = set(cp_ls.stdout.strip().splitlines())
    assert {"ndev", "nbuild", "nrun"}.issubset(names)
    cp_cat = run(["direnv", "exec", str(project), "bash", "-lc", f"cd '{project}'; sed -n '1,80p' .direnv/bin/ndev"])
    assert cp_cat.returncode == 0, cp_cat.stderr
    content = cp_cat.stdout
    assert "exec nix develop" in content
    assert "path:/" in content
