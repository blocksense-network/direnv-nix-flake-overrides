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
# Allows flake inputs to be easily overriden from your local .env file
source_url "https://direnv-flake-overrides.blocksense.network/plugin" "sha256-T201iQ1RBFKG3lP2bBhaOQssJt5O9G9M3pHtHkLGXWg="

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
- bash ≥ 4.4
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
NIX_FLAKE_OVERRIDE_INPUTS='mylib=../my-lib;foo/nixpkgs=github:NixOS/nixpkgs/nixos-24.05'
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
NIX_FLAKE_OVERRIDE_FLAKES='nixpkgs=github:NixOS/nixpkgs/nixos-24.05;myfork=github:blocksense-network/fork'
```

Effect:

```
--override-flake nixpkgs github:NixOS/nixpkgs/nixos-24.05 \
--override-flake myfork github:blocksense-network/fork
```

Tip: Use inputs for dependencies declared inside your `flake.nix`. Use flake overrides for registry lookups (e.g., CLI refs).

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

---

## Compatibility Notes

- Works alongside `nix-direnv`. You can replace a plain `use flake .` with the splice-enabled form above; caching still applies.
- If your flake reads environment variables (e.g., via `builtins.getEnv`), add `--impure` after `use flake`, for example:

  ```bash
  use flake . --impure "${FO_ARGS[@]}"
  ```

---

## Examples

### Example `.env`

```dotenv
# Point a flake input to a local checkout of a popular helper flake,
# and pin nixpkgs via a registry override
NIX_FLAKE_OVERRIDE_INPUTS='flake-parts=../flake-parts'
NIX_FLAKE_OVERRIDE_FLAKES='nixpkgs=github:NixOS/nixpkgs/nixos-24.05'
```

### Example `.envrc`

```bash
source_url "https://direnv-flake-overrides.blocksense.network/plugin" "sha256-T201iQ1RBFKG3lP2bBhaOQssJt5O9G9M3pHtHkLGXWg="
dotenv_if_exists .env
eval "use flake . $(flake-override-args-quoted)"
watch_file .env
```
