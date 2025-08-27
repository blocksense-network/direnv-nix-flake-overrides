import os
from pathlib import Path

import pytest
import pexpect  # type: ignore

REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGIN = REPO_ROOT / "plugin" / "flake-overrides.bash"


@pytest.mark.timeout(60)
def test_interactive_direnv_session(tmp_path: Path):
    # Prepare a project with .envrc and .env
    (tmp_path / ".env").write_text(
        "NIX_FLAKE_OVERRIDE_INPUTS='mylib=./lib'\n"
    )
    (tmp_path / "lib").mkdir()
    (tmp_path / ".envrc").write_text(
        f"source '{PLUGIN}'\n"
        "dotenv_if_exists .env\n"
        "flake_overrides_install_wrappers .\n"
        "PATH_add .direnv/bin\n"
    )

    # Provide a minimal flake for nix develop inside direnv exec
    (tmp_path / "flake.nix").write_text(
        '{\n'
        '  description = "tmp interactive test flake";\n'
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

    # Spawn an interactive bash with direnv hook
    bash_bin = os.environ.get("BASH_BINARY", "bash")
    child = pexpect.spawn(bash_bin, ["--noprofile", "--norc", "-i"], encoding="utf-8", timeout=120)
    child.expect_exact(["$", "#", ">", "%", "]$"])  # First prompt heuristic
    child.sendline('PS1="PEXPECT>$ "')
    child.expect_exact("PEXPECT>$ ")
    child.sendline('eval "$(direnv hook bash)"')
    child.expect_exact("PEXPECT>$ ")

    # cd into the project and proactively allow/reload
    child.sendline(f"cd {tmp_path}")
    child.expect_exact("PEXPECT>$ ")
    child.sendline("direnv allow . || true")
    child.expect_exact("PEXPECT>$ ")
    child.sendline("direnv reload || true")
    child.expect_exact("PEXPECT>$ ")

    # Create wrappers explicitly within managed env using the ambient nix develop from pytest
    child.sendline(f"direnv exec . bash -lc 'source \"{PLUGIN}\"; cd \"$DIRENV_DIR\"; flake_overrides_install_wrappers .' && echo MADE")
    child.expect("MADE\r?\n")
    child.sendline("direnv exec . bash -lc 'ls -1 .direnv/bin; echo OK'")
    child.expect("OK\r?\n")
    output = child.before
    assert "local-nix-develop" in output and "local-nix-build" in output and "local-nix-run" in output

    child.sendline("exit")
    child.expect(pexpect.EOF)
