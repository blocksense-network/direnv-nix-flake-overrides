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
    bash_bin = merged_env.get("BASH_BINARY", "bash")
    bash_script = f"set -euo pipefail\nlog_status(){{ :; }}\nsource '{PLUGIN}'\n{script}\n"
    return subprocess.run(
        [bash_bin, "-lc", bash_script],
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
    env = {"NIX_FLAKE_OVERRIDE_INPUTS": "foo=./bar"}
    (tmp_path / "bar").mkdir()
    # Auto-install should happen on source; list the autoinstall dir
    script = "ls -1 .direnv/local-flake-overrides/bin; printf '\n'; for f in .direnv/local-flake-overrides/bin/*; do echo '---'; echo \"$f\"; cat \"$f\"; done"
    cp = run_bash(script, cwd=tmp_path, env=env)
    assert cp.returncode == 0, cp.stderr
    listing, _, blobs = cp.stdout.partition("\n---\n")
    names = set(listing.strip().splitlines())
    assert {"with-local-flake-overrides", "flake-override-args-quoted"}.issubset(names)
    # Ensure files are executable
    for name in ["with-local-flake-overrides", "flake-override-args-quoted"]:
        p = tmp_path / ".direnv" / "local-flake-overrides" / "bin" / name
        assert p.exists(), name
        assert os.access(p, os.X_OK)


def test_malformed_entries_ignored(tmp_path: Path):
    # Create only one valid local dir and one valid ref; malformed entries should be ignored silently
    (tmp_path / "x").mkdir()
    env = {
        "NIX_FLAKE_OVERRIDE_INPUTS": "good=./x;bad;=noval;trailing=;also=github:owner/repo",
    }
    script = (
        "flake_override_args ARGS; "
        "for ((i=0; i<${#ARGS[@]}; i+=3)); do printf '%s|%s|%s\n' \"${ARGS[i]}\" \"${ARGS[i+1]}\" \"${ARGS[i+2]}\"; done"
    )
    cp = run_bash(script, cwd=tmp_path, env=env)
    assert cp.returncode == 0, cp.stderr
    lines = [l for l in cp.stdout.strip().splitlines() if l]
    # Expect exactly two input override triplets: good and also
    assert len(lines) == 2
    flag1, name1, val1 = lines[0].split("|")
    flag2, name2, val2 = lines[1].split("|")
    assert flag1 == flag2 == "--override-input"
    assert {name1, name2} == {"good", "also"}
    # good resolves to path:/ABS, also remains literal ref
    assert val1.startswith("path:/") or val2.startswith("path:/")
    assert (val1 == "github:owner/repo") or (val2 == "github:owner/repo")


def test_combined_inputs_then_flakes_order(tmp_path: Path):
    (tmp_path / "lib").mkdir()
    env = {
        "NIX_FLAKE_OVERRIDE_INPUTS": "mylib=./lib",
        "NIX_FLAKE_OVERRIDE_FLAKES": "nixpkgs=github:NixOS/nixpkgs/nixos-24.05",
    }
    script = "flake_override_args ARGS; printf '%s\n' \"${ARGS[@]}\""
    cp = run_bash(script, cwd=tmp_path, env=env)
    assert cp.returncode == 0, cp.stderr
    tokens = cp.stdout.strip().splitlines()
    # Find indices of flags
    input_idxs = [i for i, t in enumerate(tokens) if t == "--override-input"]
    flake_idxs = [i for i, t in enumerate(tokens) if t == "--override-flake"]
    assert input_idxs and flake_idxs
    assert max(input_idxs) < min(flake_idxs), "inputs should precede flakes"


def test_quoting_edge_cases_in_args_and_wrappers(tmp_path: Path):
    # Directory with space; flake ref containing $HOME should remain literal when evaluated
    weird_dir = tmp_path / "my lib"
    weird_dir.mkdir()
    env = {
        "NIX_FLAKE_OVERRIDE_INPUTS": "mylib=./my lib",
        "NIX_FLAKE_OVERRIDE_FLAKES": "orig=github:owner/repo?query=$HOME&x=1",
    }
    # Inspect array values directly to ensure elements are preserved
    script_array = (
        "flake_override_args ARGS; "
        "for ((i=0; i<${#ARGS[@]}; i++)); do printf '%s\n' \"${ARGS[i]}\"; done"
    )
    cp = run_bash(script_array, cwd=tmp_path, env=env)
    assert cp.returncode == 0, cp.stderr
    elems = cp.stdout.strip().splitlines()
    # Find the value for mylib
    try:
        i = elems.index("mylib")
    except ValueError:
        raise AssertionError(f"mylib key not found in args: {elems}")
    path_val = elems[i + 1]
    assert path_val.startswith("path:/"), path_val
    assert " " in path_val, "space should be present in path element"
    # Ensure $HOME is preserved literally in flake override value
    j = elems.index("orig")
    flake_val = elems[j + 1]
    assert "$HOME" in flake_val

    # Now ensure the baked CLI printer escapes as expected (space and $ are escaped)
    cp2 = run_bash("sed -n '1,40p' .direnv/local-flake-overrides/bin/flake-override-args-quoted", cwd=tmp_path, env=env)
    assert cp2.returncode == 0, cp2.stderr
    content = cp2.stdout
    # It's a small script that prints a pre-quoted string; ensure it contains escaped space and $HOME
    assert "\\ " in content or "' '" in content  # space escaped in args
    assert "\\$HOME" in content  # dollar sign escaped by %q


def test_nonexistent_dir_passes_through_literal(tmp_path: Path):
    env = {
        "NIX_FLAKE_OVERRIDE_INPUTS": "ghost=./does-not-exist",
    }
    script = (
        "flake_override_input_args ARGS; "
        "printf '%s\n' \"${ARGS[@]}\""
    )
    cp = run_bash(script, cwd=tmp_path, env=env)
    assert cp.returncode == 0, cp.stderr
    toks = cp.stdout.strip().splitlines()
    assert toks[:2] == ["--override-input", "ghost"]
    assert toks[2] == "./does-not-exist", toks[2]


def test_direnv_dir_relative_resolution(tmp_path: Path):
    project = tmp_path / "proj"
    project.mkdir()
    (project / "lib").mkdir()
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    env = {
        "DIRENV_DIR": str(project),
        "NIX_FLAKE_OVERRIDE_INPUTS": "mylib=lib",
    }
    script = "flake_override_input_args ARGS; printf '%s\n' \"${ARGS[@]}\""
    cp = run_bash(script, cwd=elsewhere, env=env)
    assert cp.returncode == 0, cp.stderr
    toks = cp.stdout.strip().splitlines()
    assert toks[:2] == ["--override-input", "mylib"]
    assert toks[2].startswith("path:/"), toks[2]
    assert toks[2].endswith("/proj/lib")


def test_collect_cli_outputs_words(tmp_path: Path):
    # Ensure the newline-delimited collector produces words that can be mapped into an array
    (tmp_path / "lib").mkdir()
    env = {
        "NIX_FLAKE_OVERRIDE_INPUTS": "mylib=./lib",
        "NIX_FLAKE_OVERRIDE_FLAKES": "override-me=github:owner/repo",
    }
    # Use the collector and verify first tokens
    cp = run_bash(".direnv/local-flake-overrides/bin/collect-flake-override-args", cwd=tmp_path, env=env)
    assert cp.returncode == 0, cp.stderr
    words = cp.stdout.strip().splitlines()
    assert words[:2] == ["--override-input", "mylib"]
    assert words[3:5] == ["--override-flake", "override-me"]


def test_leader_supports_custom_subcommands(tmp_path: Path):
    env = {"NIX_FLAKE_OVERRIDE_INPUTS": "foo=./bar"}
    (tmp_path / "bar").mkdir()
    # Use a nix stub to capture arguments
    (tmp_path / "bin").mkdir()
    nix_stub = tmp_path / "bin" / "nix"
    nix_stub.write_text("#!/usr/bin/env bash\nfor a in \"$@\"; do echo \"$a\"; done\n")
    nix_stub.chmod(0o755)
    env["PATH"] = f"{tmp_path / 'bin'}:" + os.environ.get("PATH", "")
    script = ".direnv/local-flake-overrides/bin/with-local-flake-overrides nix tree -I nixpkgs=."
    cp = run_bash(script, cwd=tmp_path, env=env)
    assert cp.returncode == 0, cp.stderr
    out = cp.stdout.strip().splitlines()
    assert out[0] == "tree"
    assert "--override-input" in out


def test_leader_script_injects_flags_before_args(tmp_path: Path):
    # Create a stub `nix` that echos its argv so we can verify positions
    (tmp_path / "bin").mkdir()
    nix_stub = tmp_path / "bin" / "nix"
    nix_stub.write_text(
        "#!/usr/bin/env bash\n" \
        "for i in \"$@\"; do echo \"$i\"; done\n"
    )
    nix_stub.chmod(0o755)

    env = {
        "PATH": f"{tmp_path / 'bin'}:" + os.environ.get("PATH", ""),
        "NIX_FLAKE_OVERRIDE_INPUTS": "mylib=./bar",
    }
    (tmp_path / "bar").mkdir()
    # Install leader and run it
    script = (
        "flake_overrides_install_leader; "
        ".direnv/bin/with-local-flake-overrides nix build .#pkg --rebuild"
    )
    cp = run_bash(script, cwd=tmp_path, env=env)
    assert cp.returncode == 0, cp.stderr
    lines = [l for l in cp.stdout.strip().splitlines() if l]
    # Expect: build <flags…> .#pkg --rebuild (first token printed by stub is subcommand)
    assert lines[0] == "build"
    assert "--override-input" in lines
    # The flake ref and user flags should still be present
    assert ".#pkg" in lines and "--rebuild" in lines


def test_empty_envs_no_error():
    env = {
        "NIX_FLAKE_OVERRIDE_INPUTS": "",
        "NIX_FLAKE_OVERRIDE_FLAKES": "",
    }
    cp = run_bash("flake_override_args_quoted", env=env)
    assert cp.returncode == 0, cp.stderr
    assert cp.stdout.strip() == ""
