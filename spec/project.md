# direnv-nix-flake-overrides

A tiny direnv helper that turns two environment variables into Nix flake CLI overrides:

* `NIX_FLAKE_OVERRIDE_INPUTS` → expands to multiple `--override-input <input> <ref>` pairs
* `NIX_FLAKE_OVERRIDE_FLAKES` → expands to multiple `--override-flake <orig> <resolved>` pairs

Use it to point flake inputs (and/or registry refs) to local paths, specific commits, forks, or alternate registries — without editing your `flake.nix` or sprinkling flags by hand.

---

## Features

* **Two kinds of overrides**: inputs (`--override-input`) and registry refs (`--override-flake`).
* **Sibling auto-detection**: override flake inputs from same-named local checkouts — a curated list (`NIX_FLAKE_OVERRIDE_SIBLINGS`) or full auto-probe of every input (`NIX_FLAKE_OVERRIDE_AUTO`) — silently skipping any sibling that isn't checked out. Resolved under `NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT` (default: the project's parent dir). Precedence: explicit inputs > curated siblings > auto.
* **Clean composition**: provides a function that builds a **bash array** of args you can splice into `use flake` (from `nix-direnv`), plus CLI helpers for inline usage.
* **Auto tools on source**: installs tiny helpers into `.direnv/local-flake-overrides/bin` and adds it to `PATH`:
  * `flake-override-args-quoted` → prints safely quoted flags for inline eval
  * `collect-flake-override-args` → prints one arg per line for easy `mapfile`
  * `with-local-flake-overrides` → leader for ad‑hoc `nix <subcmd>` usage
* **Path smarts**: directory values are resolved to absolute and coerced to a local flake ref — `git+file:///ABS` (plus `?submodules=1` where needed) for a git work tree, `path:/ABS` otherwise. See [Local directory refs](#local-directory-refs).
* **Safe quoting**: printer uses `printf %q` so baked scripts are robust.
* **Zero-commit setup**: load via `source_url` pinned by hash and cached locally.

---

## Requirements

* **direnv** v2.30+ (stdlib functions like `dotenv_if_exists`, `source_url`)
* **bash** ≥ 3.2 (macOS default is fine)
* **Nix** 2.18+ (flake commands)

---

## Install (via `source_url`)

Add this to your project’s `.envrc` (pin to a commit and hash):

```bash
# .envrc
# 1) Load the plugin (pinned)
source_url "https://direnv-flake-overrides.blocksense.network/plugin" \
           "sha256-BTxlsheP/7/FQw9IBPGFc6zYTl5S2qdAAt3EUqfkbjI="

# 2) Load variables (optional)
dotenv_if_exists .env

# 3) Splice overrides into nix-direnv in one line
eval "use flake . $(flake-override-args-quoted)"

# 4) Recompute when .env changes
watch_file .env
```

> Obtain the `sha256-…` with:
>
> ```bash
> direnv fetchurl "https://direnv-flake-overrides.blocksense.network/plugin"
> ```

---

## Configure via environment variables

### 1) `NIX_FLAKE_OVERRIDE_INPUTS`

`name=ref` pairs separated by a delimiter that is illegal in URLs. Use `|` (recommended). If your value truly needs `|`, use `^` as the delimiter. Keys may include nested input paths like `foo/nixpkgs`.

* Accepts directory paths → coerced to `git+file:///ABS` or `path:/ABS` ([Local directory refs](#local-directory-refs)).
* Accepts literal flake refs: `github:owner/repo`, `https://…`, `git+file:///…`, `path:/ABS`.

**Example**

```dotenv
# .env
NIX_FLAKE_OVERRIDE_INPUTS='flake-parts=../flake-parts'
```

**Effect** (conceptually):

```
--override-input flake-parts git+file:///ABS/PATH/TO/flake-parts
```

### 2) `NIX_FLAKE_OVERRIDE_FLAKES`

Semicolon-delimited `orig=resolved` pairs mapping **registry names/refs** to another ref, mirroring `--override-flake`.

**Example**

```dotenv
# .env
NIX_FLAKE_OVERRIDE_FLAKES='nixpkgs=github:NixOS/nixpkgs/nixos-24.05|myfork=github:blocksense-network/fork'
```

**Effect**:

```
--override-flake nixpkgs github:NixOS/nixpkgs/nixos-24.05 \
--override-flake myfork github:blocksense-network/fork
```

> **Tip**: Use `NIX_FLAKE_OVERRIDE_INPUTS` for inputs declared inside `flake.nix`. Use `NIX_FLAKE_OVERRIDE_FLAKES` to rewrite registry lookups (e.g., command-line flake refs).

---

## Local directory refs

A directory value is never handed to Nix as a bare path. It is coerced to one of two flake refs, and the choice is behavioural, not cosmetic.

### Requirement

An override that points at a local checkout MUST make Nix see:

1. every file git tracks, **including uncommitted worktree edits** to them —
   this is the entire reason local overrides exist;
2. submodule content, where the checkout has submodules;

and MUST NOT make Nix see:

3. gitignored content (build output), which is neither an input to the build
   nor stable, and whose presence in a content-addressed store path silently
   invalidates the dev shell whenever a build touches it.

### Behaviour

| condition | emitted ref |
|---|---|
| root of a git work tree, ≥1 commit, no `.gitmodules` | `git+file:///ABS` |
| …and `.gitmodules` present, all submodules initialised | `git+file:///ABS?submodules=1` |
| …and any submodule uninitialised | `path:/ABS` + notice |
| not a git work tree / not its root / unborn HEAD / no `git` | `path:/ABS` |

`path:` copies the entire tree and ignores `.gitignore`, violating (3); measured at 19 GB and ~50 minutes for one real repo against 75 MB and 13 s for `git+file:`. `?submodules=1` satisfies (2) but hard-fails on an uninitialised submodule, so it is applied only when every submodule is checked out; otherwise `path:` is used, because being slow is better than being broken.

### Untracked files

`git+file:` cannot see a file git has never been told about, which is the one behaviour `path:` had that this loses. It MUST NOT be lost silently, and the plugin MUST NOT fall back to `path:` to paper over it — a single editor scratch file would restore the whole-tree copy and make build times unpredictable.

Instead, before emitting a `git+file:` ref the plugin runs `git ls-files --others --exclude-standard` and, if the result is non-empty, prints a notice **on stderr** (never stdout, which is spliced verbatim into `use flake`) that:

* states the count and names the files, capping the list and saying how many were elided;
* states plainly that those files are not part of what the shell builds;
* gives the runnable remedy — `git add` — and states that **staging alone suffices, no commit is needed**, after which worktree edits flow normally.

### Note for downstream parsers

Anything that reads these override arguments must accept `git+file://` (with an optional `?submodules=1` query) alongside `path:`. A parser matching only `path:` does not fail loudly; it silently observes "no overrides", which reintroduces exactly the stale-dev-shell bug this plugin exists to prevent.

---

## Usage patterns

### Splice into `use flake`

```bash
eval "use flake . $(flake-override-args-quoted)"
```

### Leader script (ad‑hoc)

```bash
with-local-flake-overrides nix build .#mypkg --rebuild
with-local-flake-overrides nix develop .
with-local-flake-overrides nix run .#tool -- --flag
```

### Build an array (no eval)

Collect into a Bash array without `eval` and splice safely:

```bash
mapfile -t FO_ARGS < <(collect-flake-override-args)
use flake . "${FO_ARGS[@]}"
```

---

## How it works

* The plugin parses the env vars, resolves directory values to absolute paths, and constructs the appropriate `--override-input` / `--override-flake` flag pairs.
* For array usage, prefer the helper `collect-flake-override-args` and map it into an array (`mapfile -t` or a read loop) to preserve boundaries without quoting bugs.
* Auto tools are generated on source: `flake-override-args-quoted`, `collect-flake-override-args`, and `with-local-flake-overrides`.

---

## Security & trust

* Always load via `source_url` with an integrity hash; the script is cached content-addressably under direnv’s CAS.
* The wrapper scripts bake the precomputed arguments using shell-escaping (`printf %q`).
* Treat your `.env` as trusted input. If you need to share, prefer relative paths checked into your monorepo or pin to specific commits.

---

## Compatibility notes

* Works alongside `nix-direnv`. You may replace `use flake` with our splice-enabled form; caching still applies.
* If your flake logic reads env vars via `builtins.getEnv`, add `--impure` *after* `use flake`, e.g.:

  ```bash
  use flake . --impure "${FO_ARGS[@]}"
  ```

---

## Development

```bash
# Clone for local hacking
git clone https://github.com/blocksense-network/direnv-nix-flake-overrides
cd direnv-nix-flake-overrides

# Lint
shellcheck plugin/flake-overrides.bash
```

---

## License

MIT © Blocksense Network

---

## Files

### `plugin/flake-overrides.bash`

Defines the helpers described above and auto-installs the small CLI tools on source. Prefer the README for usage examples.

### Example `.env`

```dotenv
# Point a flake input to a local checkout and pin nixpkgs via registry override
NIX_FLAKE_OVERRIDE_INPUTS='flake-parts=../flake-parts'
NIX_FLAKE_OVERRIDE_FLAKES='nixpkgs=github:NixOS/nixpkgs/nixos-24.05'
```

### Example `.envrc` (full)

```bash
source_url "https://direnv-flake-overrides.blocksense.network/plugin" \
           "sha256-BTxlsheP/7/FQw9IBPGFc6zYTl5S2qdAAt3EUqfkbjI="
dotenv_if_exists .env
eval "use flake . $(flake-override-args-quoted)"
watch_file .env
```

---

### MIT License

```
Copyright (c) 2025 Blocksense Network

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
