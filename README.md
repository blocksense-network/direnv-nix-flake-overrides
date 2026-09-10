# direnv-nix-flake-overrides

Tiny direnv helper that lets you declare Nix flake overrides in your local `.env` and automatically splice them into `nix develop/build/run` via `use flake`.

It supports two kinds of overrides:

- `NIX_FLAKE_OVERRIDE_INPUTS`: expands to multiple `--override-input <input> <ref>` pairs
- `NIX_FLAKE_OVERRIDE_FLAKES`: expands to multiple `--override-flake <orig> <resolved>` pairs

---

## Quick Start

Add this to your project’s `.envrc`:

```bash
# See https://direnv-flake-overrides.blocksense.network
# Allows flake inputs to be easily overridden from your local .env file
source_url "https://direnv-flake-overrides.blocksense.network/plugin" \
           "sha256-ixCgoLDPJelkuT5gukgffNxg9edSZEfVOK5QciktI74="

# Optional: load overrides from .env
dotenv_if_exists .env

# Splice override flags into nix-direnv in one line (most convenient)
eval "use flake . $(flake-override-args-quoted)"

# Recompute when .env changes
watch_file .env
```

> To compute the integrity hash yourself:
>
> ```bash
> direnv fetchurl "https://direnv-flake-overrides.blocksense.network/plugin"
> ```
>
> The hash above is that of `plugin/flake-overrides.bash` **at this commit**;
> it is only live once this revision has been published to that URL. Because
> `source_url` resolves purely by content hash, a stale pin is not an older
> version of the same program — it is a *different* program, and one that
> lacks a feature you configure will not complain, it will simply emit no
> overrides. Re-run `direnv fetchurl` after every publish and update
> consumers, or point them at a sibling checkout:
>
> ```bash
> # Prefer a sibling checkout of the plugin (always current); else the pin.
> _fo_local="../direnv-nix-flake-overrides/plugin/flake-overrides.bash"
> if [[ -f "$_fo_local" ]]; then
>   watch_file "$_fo_local"; source "$_fo_local"
> else
>   source_url "https://direnv-flake-overrides.blocksense.network/plugin" \
>              "sha256-ixCgoLDPJelkuT5gukgffNxg9edSZEfVOK5QciktI74="
> fi
> unset _fo_local
> ```

---

## Requirements

- direnv ≥ 2.30
- bash ≥ 3.2 (macOS default is fine)
- Nix ≥ 2.18 (flakes enabled)

---

## Configure via `.env`

Declare key=value pairs separated by a delimiter that is illegal in URLs. Use `|` (recommended). If you truly need `|` inside a value, use `^` as the delimiter.

Values can be local paths, `github:` refs, `https://…`, `git+file:///…`, or `path:/ABS`.

Local directories are coerced to an absolute flake ref — see
[How local directories are handed to Nix](#how-local-directories-are-handed-to-nix)
for which ref, and why it matters.

### 1) Override flake inputs declared in your `flake.nix`

Variable: `NIX_FLAKE_OVERRIDE_INPUTS`

Example:

```dotenv
# .env
NIX_FLAKE_OVERRIDE_INPUTS='mylib=../my-lib|foo/nixpkgs=github:NixOS/nixpkgs/nixos-25.05'
```

Effect (conceptually):

```
--override-input mylib git+file:///ABS/PATH/TO/my-lib \
--override-input foo/nixpkgs github:NixOS/nixpkgs/nixos-24.05
```

### 2) Override registry names/refs used on the CLI

Variable: `NIX_FLAKE_OVERRIDE_FLAKES`

Example:

```dotenv
# .env
NIX_FLAKE_OVERRIDE_FLAKES='nixpkgs=github:NixOS/nixpkgs/nixos-25.05|myfork=github:blocksense-network/fork'
```

Effect:

```
--override-flake nixpkgs github:NixOS/nixpkgs/nixos-24.05 \
--override-flake myfork github:blocksense-network/fork
```

Tip: Use inputs for dependencies declared inside your `flake.nix`. Use flake overrides for registry lookups (e.g., CLI refs).

### 3) Auto-override flake inputs from local sibling checkouts

When you keep dependencies as sibling checkouts next to your project (the usual side-by-side / monorepo layout), you rarely want to hand-write a path for each one. Two variables make this automatic. Both resolve directories under the **siblings root** — default: the parent of the project; override with `NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT` — and **silently skip** any input whose sibling isn't checked out (so the same `.env` works whether or not you've cloned a given dependency).

#### Curated list — `NIX_FLAKE_OVERRIDE_SIBLINGS`

A `|`-delimited list of inputs to override with a local checkout *iff* it is present. Each entry is `<name>` (input name == sibling dir name) or `<input>=<dir>` when they differ.

```dotenv
# .env — override these inputs with ../<sibling> when the dir exists
NIX_FLAKE_OVERRIDE_SIBLINGS='ct-test-src=ct-test|runquota-src=runquota'
```

If `../ct-test` and `../runquota` exist, this expands to:

```
--override-input ct-test-src git+file:///ABS/ct-test \
--override-input runquota-src git+file:///ABS/runquota
```

#### Full auto — `NIX_FLAKE_OVERRIDE_AUTO`

Opt in (`=1`) and **every** flake input is probed for a same-named sibling — no list to maintain. Inputs without a matching sibling are left on their pinned ref.

```dotenv
# .env
NIX_FLAKE_OVERRIDE_AUTO=1
# Optional: let an input like `foo-src` match a sibling named `foo`
NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES='-src'
```

Reading the input names uses `nix flake metadata --json`, so `nix` and `jq` must be available; if either is missing, the auto pass is skipped with a warning (your explicit overrides still apply).

**Precedence** — each input is overridden at most once: explicit `NIX_FLAKE_OVERRIDE_INPUTS` wins over `NIX_FLAKE_OVERRIDE_SIBLINGS`, which wins over `NIX_FLAKE_OVERRIDE_AUTO`. So you can enable auto globally and still pin a single input by hand.

---

## How local directories are handed to Nix

A local checkout can be given to Nix two ways, and the difference is not cosmetic.

`path:/ABS` copies the **entire** directory tree into the Nix store and does **not** honour `.gitignore`. On a checkout that carries build output — Rust `target/`, `nimcache/`, `node_modules/` — that means copying gigabytes on every lock change. One real repo measured 19 GB of tree for 3,719 tracked files, and roughly **50 minutes** per override. It is also a correctness problem: the store path is content-addressed over everything it copied, so touching a single generated file changes the input hash and silently invalidates the dev shell for everyone using that override.

`git+file:///ABS` enumerates the directory **through git** instead. Gitignored content is skipped (the same repo: 19 GB → 75 MB, ~50 min → 13 s) while **uncommitted edits to tracked files still reach the store** — the guarantee that makes local overrides worth having in the first place.

So a sibling that is the root of a git work tree with at least one commit is emitted as `git+file:///ABS`. Everything else keeps `path:/ABS`.

### Untracked files are not in the build — and you will be told

`git+file:` can only hand Nix the files git knows about. A brand-new file that has never been `git add`ed is invisible to it.

The plugin never silently downgrades such a checkout back to `path:` — one editor scratch file would quietly restore the whole-tree copy and make build times unpredictable. Instead it prints a notice **on stderr** (stdout is spliced straight into `use flake`, so nothing else may go there) naming the files and how many were elided:

```
flake-overrides: NOTICE: '/ABS/my-lib' is overridden via git+file:, which lists files through git.
flake-overrides:   12 untracked file(s) are therefore NOT part of what the dev shell builds:
flake-overrides:     scratch-1.nim
…
flake-overrides:     ... and 4 more (of 12 total)
flake-overrides:   To include them, run:  git -C '/ABS/my-lib' add <path>...
flake-overrides:   Staging is enough - no commit is needed - and once a file is tracked,
flake-overrides:   later worktree edits to it flow into the shell normally.
```

`git add` really is the whole remedy: staging alone makes the file visible, and from then on your worktree edits to it flow into the shell as usual.

### Submodules

Submodule content is dropped from a `git+file:` fetch unless `?submodules=1` is requested, so a checkout containing `.gitmodules` gets `git+file:///ABS?submodules=1`.

But `?submodules=1` **hard-fails** when a submodule is uninitialised — the state of any clone made without `--recurse-submodules`. Rather than break your shell, such a checkout falls back to `path:` (faithful to what is on disk, cannot fail) with a notice telling you how to earn the fast path back:

```
flake-overrides: NOTICE: '/ABS/my-lib' has uninitialised submodule(s):
flake-overrides:     vendor/sub
…
flake-overrides:   To restore the fast override, run:
flake-overrides:     git -C '/ABS/my-lib' submodule update --init --recursive
```

### When `path:` is still used

- the directory is not a git work tree at all;
- the directory is *inside* a repo but is not its root (`git+file://<subdir>` would fetch the whole enclosing repository);
- the repo has no commit yet, so git has no tree to hand over;
- a submodule is uninitialised (above);
- `git` is not on `PATH`.

> **If you parse these override arguments**, note that a local checkout is now spelled `git+file:///ABS` (optionally with `?submodules=1`) as well as `path:/ABS`. A parser that matches only `path:` will not fail loudly — it will quietly see no overrides, which is exactly the stale-dev-shell class of bug this plugin exists to prevent.

---

## Usage Patterns

- Inline splice (recommended):

  ```bash
  # Inside .envrc
  eval "use flake . $(flake-override-args-quoted)"
  ```

  Notes:
  - Uses `eval` with a safely quoted printer; argument boundaries are preserved. Treat `.env` as trusted input.
  - The `flake-override-args-quoted` helper is auto-generated when the plugin is sourced and prints the current pre-quoted flags.

- Leader script (rarely needed):

  Use this when you want to run ad‑hoc `nix` commands directly in your shell without editing your `use flake` line, e.g.:

  ```bash
  with-local-flake-overrides nix build .#mypkg --rebuild
  with-local-flake-overrides nix develop .
  with-local-flake-overrides nix run .#tool -- --flag
  ```

- Build an array (no eval):

  If you prefer to avoid `eval` or need to manipulate the flags programmatically in Bash, collect them into an array.

  ```bash
  # Newline-delimited helper: prints one word per line
  mapfile -t FO_ARGS < <(collect-flake-override-args)
  # FO_ARGS now contains: --override-input name ref --override-flake orig ref …
  use flake . "${FO_ARGS[@]}"
  ```

  Why arrays: lets you merge, reorder, or filter the flags in Bash without dealing with quoting or string parsing.

  Note for macOS Bash 3.2 (no mapfile):

  ```bash
  FO_ARGS=(); while IFS= read -r w; do FO_ARGS+=("$w"); done < <(collect-flake-override-args)
  use flake . "${FO_ARGS[@]}"
  ```


---

## Deployment

`https://direnv-flake-overrides.blocksense.network/plugin` is a Cloudflare
redirect to this repo's **`stable`** branch, served via GitHub raw:

```
https://raw.githubusercontent.com/blocksense-network/direnv-nix-flake-overrides/refs/heads/stable/plugin/flake-overrides.bash
```

The redirect follows `stable`, so it is configured **once** and never needs to
change again. Consumers pin the integrity hash of the current `stable` version
(see [Quick Start](#quick-start)).

### Cutting a release

1. Land the change on `main`.
2. Fast-forward `stable` to the release commit:

   ```bash
   git push origin main:stable
   ```

3. Recompute the hash and update it in the Quick Start snippet above — and in
   any consuming `.envrc` (e.g. the `blocksense` monorepo):

   ```bash
   direnv fetchurl "https://direnv-flake-overrides.blocksense.network/plugin"
   ```

Because `source_url` verifies the pinned hash against the downloaded bytes,
steps 2 and 3 must land together: moving `stable` without updating the hash
will break fresh checkouts (cached consumers are unaffected until they refetch).
