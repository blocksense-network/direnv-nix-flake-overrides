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
           "sha256-BTxlsheP/7/FQw9IBPGFc6zYTl5S2qdAAt3EUqfkbjI="

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

---

## Requirements

- direnv ≥ 2.30
- bash ≥ 3.2 (macOS default is fine)
- Nix ≥ 2.18 (flakes enabled)

---

## Configure via `.env`

Declare key=value pairs separated by a delimiter that is illegal in URLs. Use `|` (recommended). If you truly need `|` inside a value, use `^` as the delimiter.

Values can be local paths, `github:` refs, `https://…`, `git+file:///…`, or `path:/ABS`.

### 1) Override flake inputs declared in your `flake.nix`

Variable: `NIX_FLAKE_OVERRIDE_INPUTS`

Example:

```dotenv
# .env
NIX_FLAKE_OVERRIDE_INPUTS='mylib=../my-lib|foo/nixpkgs=github:NixOS/nixpkgs/nixos-25.05'
```

Effect (conceptually):

```
--override-input mylib path:/ABS/PATH/TO/my-lib \
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
--override-input ct-test-src path:/ABS/ct-test \
--override-input runquota-src path:/ABS/runquota
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
