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

    # Spawn an interactive bash with direnv hook
    child = pexpect.spawn("bash", ["--noprofile", "--norc", "-i"], encoding="utf-8", timeout=20)
    child.expect_exact(["$", "#", ">", "%", "]$"])  # First prompt heuristic
    child.sendline('PS1="PEXPECT>$ "')
    child.expect_exact("PEXPECT>$ ")
    child.sendline('eval "$(direnv hook bash)"')
    child.expect_exact("PEXPECT>$ ")

    # cd into the project, allow, then verify wrappers exist
    child.sendline(f"cd {tmp_path}")
    # direnv will block until allow; run allow
    child.expect("direnv: error|denied|refuse|allow")
    child.sendline("direnv allow .")
    child.expect_exact("PEXPECT>$ ")

    # List wrappers and print quoted args via direnv exec
    child.sendline("ls -1 .direnv/bin && echo OK")
    child.expect("OK\r?\n")
    output = child.before
    assert "ndev" in output and "nbuild" in output and "nrun" in output

    # Now use direnv exec to call the function inside a managed bash
    child.sendline("direnv exec . bash -lc 'flake_override_args_quoted' && echo DONE")
    child.expect("DONE\r?\n")
    args_output = child.before.strip().split()
    assert args_output[:2] == ["--override-input", "mylib"]
    assert args_output[2].startswith("path:/")

    child.sendline("exit")
    child.expect(pexpect.EOF)
