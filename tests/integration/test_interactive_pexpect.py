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

    # cd into the project and proactively allow/reload
    child.sendline(f"cd {tmp_path}")
    child.expect_exact("PEXPECT>$ ")
    child.sendline("direnv allow . || true")
    child.expect_exact("PEXPECT>$ ")
    child.sendline("direnv reload || true")
    child.expect_exact("PEXPECT>$ ")

    # Create wrappers explicitly within managed env, then list
    child.sendline(f"direnv exec . bash -lc 'source \"{PLUGIN}\"; cd \"$DIRENV_DIR\"; flake_overrides_install_wrappers .' && echo MADE")
    child.expect("MADE\r?\n")
    child.sendline("direnv exec . bash -lc 'ls -1 .direnv/bin && echo OK'")
    child.expect("OK\r?\n")
    output = child.before
    assert "ndev" in output and "nbuild" in output and "nrun" in output

    # Now print markers and the quoted args in between, captured from interactive session
    child.sendline("direnv exec . bash -lc 'echo __BEGIN__; flake_override_args_quoted; echo __END__'")
    child.expect("__END__\r?\n")
    # Capture everything printed before the END marker, then slice after BEGIN
    output = child.before
    b = output.rfind("__BEGIN__")
    if b != -1:
        output = output[b + len("__BEGIN__"):]
    args_output = output.strip().split()
    assert args_output[:2] == ["--override-input", "mylib"]
    assert args_output[2].startswith("path:/")

    child.sendline("exit")
    child.expect(pexpect.EOF)
