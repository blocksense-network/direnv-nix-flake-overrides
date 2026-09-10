"""Sibling overrides must be emitted as `git+file:` refs, not `path:`.

`path:` copies the *entire* directory tree into the Nix store and does not
honour `.gitignore`, so a sibling checkout carrying build output (Rust
`target/`, Nim `nimcache/`, …) is copied in full on every lock change. Beyond
being slow, it is a correctness problem: the store path is content-addressed
over everything, so touching a single file under a gitignored build directory
changes the input hash and silently invalidates the dev shell.

`git+file:` enumerates through git, which excludes gitignored content while
still honouring uncommitted edits to tracked files — the load-bearing
develop-mode guarantee. The trade-offs it introduces (untracked files are
invisible; submodules need `?submodules=1`; `?submodules=1` hard-fails on an
uninitialised submodule) are what the tests below pin down.

These tests assert against the *real* Nix store contents via
`builtins.fetchTree`, not against the emitted string alone: the string is only
interesting insofar as it makes Nix see the right files. No network is needed —
`path:` and `git+file:` on a local directory are both offline fetchers — but
the tests skip loudly if `nix` or `git` is missing.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from test_plugin_unit import run_bash


NIX_FEATURES = ["--extra-experimental-features", "nix-command flakes"]


def _require(tool: str) -> None:
    if shutil.which(tool) is None:
        pytest.skip(f"SKIPPING LOUDLY: '{tool}' is not on PATH; this test asserts "
                    f"against real {tool} behaviour and cannot be faked")


def git(repo: Path, *args: str) -> str:
    cp = subprocess.run(
        ["git", "-c", "user.email=t@example.com", "-c", "user.name=t",
         "-c", "protocol.file.allow=always", "-C", str(repo), *args],
        text=True, capture_output=True, check=True,
    )
    return cp.stdout


def fetch_tree(ref: str) -> Path:
    """Realize a flake ref into the store and return the store path.

    Goes through `nix flake metadata`, i.e. the very same flakeref parser and
    fetcher that consumes an `--override-input` value, so what the tests see is
    what the dev shell would see. `--no-write-lock-file` keeps the fetch from
    dropping a `flake.lock` into the fixture (which would itself show up as an
    untracked file and skew the other assertions)."""
    import json
    cp = subprocess.run(
        ["nix", *NIX_FEATURES, "flake", "metadata", "--json",
         "--no-write-lock-file", ref],
        text=True, capture_output=True, check=False,
    )
    assert cp.returncode == 0, f"fetching {ref} failed:\n{cp.stderr}"
    return Path(json.loads(cp.stdout)["path"])


def make_flake(d: Path) -> None:
    (d / "flake.nix").write_text("{ outputs = _: {}; }\n")


def make_git_sibling(root: Path, name: str) -> Path:
    """A committed sibling with a tracked file and a gitignored build dir."""
    d = root / name
    d.mkdir(parents=True, exist_ok=True)
    make_flake(d)
    (d / "tracked.txt").write_text("tracked-committed\n")
    (d / ".gitignore").write_text("build-output/\n")
    (d / "build-output").mkdir()
    (d / "build-output" / "huge.bin").write_text("pretend this is 17 GB\n")
    git(d, "init", "-q", "-b", "main", ".")
    git(d, "add", "-A")
    git(d, "commit", "-qm", "init")
    return d


def sibling_ref(project: Path, root: Path, input_name: str, dirname: str):
    """Emit the override for one sibling; return (ref, stderr)."""
    project.mkdir(parents=True, exist_ok=True)
    env = {
        "NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT": str(root),
        "NIX_FLAKE_OVERRIDE_SIBLINGS": f"{input_name}={dirname}",
    }
    cp = run_bash(
        'eval "set -- $(flake_override_args_quoted)"; printf \'%s\\n\' "$@"',
        cwd=project, env=env,
    )
    assert cp.returncode == 0, cp.stderr
    toks = [t for t in cp.stdout.strip().splitlines() if t]
    assert toks[:2] == ["--override-input", input_name], toks
    return toks[2], cp.stderr


# --------------------------------------------------------------------------
# The core swap: git-backed siblings must not be copied wholesale
# --------------------------------------------------------------------------

def test_git_sibling_emits_git_file_ref(tmp_path: Path):
    _require("git")
    root = tmp_path / "siblings"
    make_git_sibling(root, "mylib")
    ref, _ = sibling_ref(tmp_path / "proj", root, "mylib", "mylib")
    assert ref.startswith("git+file://"), ref
    assert ref.endswith("/mylib"), ref


def test_gitignored_content_excluded_from_store(tmp_path: Path):
    _require("git")
    _require("nix")
    root = tmp_path / "siblings"
    make_git_sibling(root, "mylib")
    ref, _ = sibling_ref(tmp_path / "proj", root, "mylib", "mylib")
    store = fetch_tree(ref)
    assert (store / "tracked.txt").is_file(), "tracked content must be present"
    assert not (store / "build-output").exists(), (
        f"gitignored build output leaked into the store at {store}"
    )


def test_uncommitted_edit_to_tracked_file_reaches_the_store(tmp_path: Path):
    """Develop mode is the whole point: local edits MUST be what nix builds."""
    _require("git")
    _require("nix")
    root = tmp_path / "siblings"
    d = make_git_sibling(root, "mylib")
    (d / "tracked.txt").write_text("EDITED-IN-WORKTREE-NOT-COMMITTED\n")
    ref, _ = sibling_ref(tmp_path / "proj", root, "mylib", "mylib")
    store = fetch_tree(ref)
    assert (store / "tracked.txt").read_text() == "EDITED-IN-WORKTREE-NOT-COMMITTED\n"


# --------------------------------------------------------------------------
# The one real regression: untracked files vanish — loudly, never silently
# --------------------------------------------------------------------------

def test_untracked_files_produce_a_loud_notice_naming_them(tmp_path: Path):
    _require("git")
    root = tmp_path / "siblings"
    d = make_git_sibling(root, "mylib")
    (d / "scratch-one.nim").write_text("x\n")
    (d / "scratch-two.nim").write_text("y\n")
    ref, err = sibling_ref(tmp_path / "proj", root, "mylib", "mylib")
    # Still git+file: — falling back to path: would silently restore the
    # whole-tree copy the moment anyone leaves an editor scratch file around.
    assert ref.startswith("git+file://"), ref
    assert "scratch-one.nim" in err, err
    assert "scratch-two.nim" in err, err
    assert "not" in err.lower(), err
    # The remedy must be runnable and must say a commit is unnecessary.
    assert "git add" in err or "git -C" in err, err
    assert "add" in err, err
    assert "commit" in err.lower(), err


def test_untracked_notice_goes_to_stderr_not_stdout(tmp_path: Path):
    """stdout is spliced straight into `use flake`; a stray word breaks it."""
    _require("git")
    root = tmp_path / "siblings"
    d = make_git_sibling(root, "mylib")
    (d / "scratch.nim").write_text("x\n")
    env = {
        "NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT": str(root),
        "NIX_FLAKE_OVERRIDE_SIBLINGS": "mylib",
    }
    cp = run_bash("flake_override_args_quoted", cwd=tmp_path, env=env)
    assert cp.returncode == 0, cp.stderr
    assert "scratch.nim" not in cp.stdout, cp.stdout
    assert "scratch.nim" in cp.stderr, cp.stderr
    # stdout must remain exactly three shell words
    words = cp.stdout.split()
    assert words[0] == "'--override-input'", cp.stdout
    assert len(words) == 3, cp.stdout


def test_untracked_notice_caps_the_list_and_says_how_many_elided(tmp_path: Path):
    _require("git")
    root = tmp_path / "siblings"
    d = make_git_sibling(root, "mylib")
    for i in range(40):
        (d / f"scratch-{i:02d}.tmp").write_text("x\n")
    _, err = sibling_ref(tmp_path / "proj", root, "mylib", "mylib")
    assert "40" in err, f"total count must be stated: {err}"
    assert err.count("scratch-") < 40, f"list must be capped: {err}"


def test_clean_git_sibling_produces_no_untracked_notice(tmp_path: Path):
    _require("git")
    root = tmp_path / "siblings"
    make_git_sibling(root, "mylib")
    _, err = sibling_ref(tmp_path / "proj", root, "mylib", "mylib")
    assert "untracked" not in err.lower(), err


# --------------------------------------------------------------------------
# Submodules
# --------------------------------------------------------------------------

def make_submodule_sibling(root: Path, name: str) -> Path:
    upstream = root / f"{name}-submodule-upstream"
    upstream.mkdir(parents=True)
    (upstream / "sub-file.txt").write_text("SUBMODULE_CONTENT\n")
    git(upstream, "init", "-q", "-b", "main", ".")
    git(upstream, "add", "-A")
    git(upstream, "commit", "-qm", "init")

    d = make_git_sibling(root, name)
    git(d, "submodule", "add", "-q", str(upstream), "sub")
    git(d, "commit", "-qm", "add submodule")
    return d


def test_submodule_content_present_via_submodules_query(tmp_path: Path):
    _require("git")
    _require("nix")
    root = tmp_path / "siblings"
    make_submodule_sibling(root, "mylib")
    ref, _ = sibling_ref(tmp_path / "proj", root, "mylib", "mylib")
    assert "submodules=1" in ref, (
        f"a repo with submodules needs ?submodules=1 or its content vanishes: {ref}"
    )
    store = fetch_tree(ref)
    assert (store / "sub" / "sub-file.txt").is_file(), (
        f"submodule content missing from {store}"
    )


def test_no_gitmodules_means_no_submodules_query(tmp_path: Path):
    _require("git")
    root = tmp_path / "siblings"
    make_git_sibling(root, "mylib")
    ref, _ = sibling_ref(tmp_path / "proj", root, "mylib", "mylib")
    assert "submodules" not in ref, ref


def test_uninitialised_submodule_falls_back_to_path_without_failing(tmp_path: Path):
    """`?submodules=1` hard-fails on an uninitialised submodule — the state of
    any clone made without `--recurse-submodules`. Fall back to `path:`, which
    is faithful to what is on disk and cannot fail."""
    _require("git")
    _require("nix")
    root = tmp_path / "siblings"
    origin = make_submodule_sibling(tmp_path / "origins", "mylib")
    root.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "-c", "protocol.file.allow=always", "clone", "-q",
         str(origin), str(root / "mylib")],
        check=True, capture_output=True, text=True,
    )
    assert not any((root / "mylib" / "sub").iterdir()), "submodule should be uninitialised"

    ref, err = sibling_ref(tmp_path / "proj", root, "mylib", "mylib")
    assert ref.startswith("path:"), (
        f"uninitialised submodule must fall back to path:, got {ref}"
    )
    assert "submodule" in err.lower(), err
    assert "--init" in err, f"the notice must give the runnable remedy: {err}"
    # And the fallback must actually work.
    store = fetch_tree(ref)
    assert (store / "tracked.txt").is_file()


# --------------------------------------------------------------------------
# Non-git directories keep the path: fallback
# --------------------------------------------------------------------------

def test_non_git_sibling_keeps_path_fallback(tmp_path: Path):
    root = tmp_path / "siblings"
    d = root / "mylib"
    d.mkdir(parents=True)
    make_flake(d)
    ref, _ = sibling_ref(tmp_path / "proj", root, "mylib", "mylib")
    assert ref.startswith("path:/"), ref


def test_linked_git_worktree_behaves_like_a_normal_checkout(tmp_path: Path):
    """`git worktree add` siblings are the normal layout in a multi-repo
    workspace, and their `.git` is a file, not a directory."""
    _require("git")
    _require("nix")
    root = tmp_path / "siblings"
    origin = make_git_sibling(tmp_path / "origins", "mylib")
    root.mkdir(parents=True, exist_ok=True)
    git(origin, "worktree", "add", "-q", "-b", "feat", str(root / "mylib"))
    assert (root / "mylib" / ".git").is_file(), "linked worktree marker"
    (root / "mylib" / "tracked.txt").write_text("EDITED-IN-LINKED-WORKTREE\n")

    ref, _ = sibling_ref(tmp_path / "proj", root, "mylib", "mylib")
    assert ref.startswith("git+file://"), ref
    store = fetch_tree(ref)
    assert (store / "tracked.txt").read_text() == "EDITED-IN-LINKED-WORKTREE\n"
    assert not (store / "build-output").exists(), "gitignored output must stay out"


def test_subdirectory_of_a_git_repo_keeps_path_fallback(tmp_path: Path):
    """`git+file://<subdir>` would fetch the whole enclosing repo, so a sibling
    that is merely *inside* a repo rather than its root must stay on path:."""
    _require("git")
    root = tmp_path / "siblings"
    outer = make_git_sibling(root, "outer")
    inner = outer / "nested"
    inner.mkdir()
    make_flake(inner)
    ref, _ = sibling_ref(tmp_path / "proj", root, "inner", "outer/nested")
    assert ref.startswith("path:/"), ref


# --------------------------------------------------------------------------
# The explicit NIX_FLAKE_OVERRIDE_INPUTS path gets the same treatment
# --------------------------------------------------------------------------

def test_explicit_input_dir_also_uses_git_file(tmp_path: Path):
    _require("git")
    root = tmp_path / "siblings"
    make_git_sibling(root, "mylib")
    env = {"NIX_FLAKE_OVERRIDE_INPUTS": f"mylib={root / 'mylib'}"}
    cp = run_bash(
        'eval "set -- $(flake_override_args_quoted)"; printf \'%s\\n\' "$@"',
        cwd=tmp_path, env=env,
    )
    assert cp.returncode == 0, cp.stderr
    toks = [t for t in cp.stdout.strip().splitlines() if t]
    assert toks[:2] == ["--override-input", "mylib"]
    assert toks[2].startswith("git+file://"), toks[2]
