# direnv-nix-flake-overrides

A tiny direnv helper that turns two environment variables into Nix flake CLI overrides:

* `NIX_FLAKE_OVERRIDE_INPUTS` → expands to multiple `--override-input <input> <ref>` pairs
* `NIX_FLAKE_OVERRIDE_FLAKES` → expands to multiple `--override-flake <orig> <resolved>` pairs

Use it to point flake inputs (and/or registry refs) to local paths, specific commits, forks, or alternate registries — without editing your `flake.nix` or sprinkling flags by hand.

---

## Features

* **Two kinds of overrides**: inputs (`--override-input`) and registry refs (`--override-flake`).
* **Clean composition**: provides a function that builds a **bash array** of args you can splice into `use flake` (from `nix-direnv`).
* **Wrapper scripts**: optional `ndev`, `nbuild`, `nrun` generated into `.direnv/bin/` so you can keep using short commands in your shell.
* **Path smarts**: directory values are resolved to absolute and coerced to `path:/ABS`.
* **Safe quoting**: printer uses `printf %q` so baked scripts are robust.
* **Zero-commit setup**: load via `source_url` pinned by hash and cached locally.

---

## Requirements

* **direnv** v2.30+ (stdlib functions like `dotenv_if_exists`, `source_url`)
* **bash** ≥ 4.4 (nameref `local -n`)
* **Nix** 2.18+ (flake commands)

---

## Install (via `source_url`)

Add this to your project’s `.envrc` (pin to a commit and hash):

```bash
# .envrc
# 1) Load the plugin (pinned)
source_url "https://raw.githubusercontent.com/blocksense-network/direnv-nix-flake-overrides/<COMMIT>/plugin/flake-overrides.bash" \
           "sha256-PASTE_HASH_HERE="

# 2) Load variables (optional)
dotenv_if_exists .env

# 3) Build args and splice into nix-direnv’s use flake
flake_override_args FO_ARGS
use flake . "${FO_ARGS[@]}"

# 4) (Optional) install wrapper scripts that carry the same args
flake_overrides_install_wrappers .
PATH_add .direnv/bin

# 5) Recompute when .env changes
watch_file .env
```

> Obtain the `sha256-…` with:
>
> ```bash
> direnv fetchurl "https://raw.githubusercontent.com/blocksense-network/direnv-nix-flake-overrides/<COMMIT>/plugin/flake-overrides.bash"
> ```

---

## Configure via environment variables

### 1) `NIX_FLAKE_OVERRIDE_INPUTS`

Semicolon-delimited `name=ref` pairs mapping **input paths** to **flake refs**. Keys may include nested input paths like `foo/nixpkgs`.

* Accepts directory paths → coerced to `path:/ABS`.
* Accepts literal flake refs: `github:owner/repo`, `https://…`, `git+file:///…`, `path:/ABS`.

**Example**

```dotenv
# .env
NIX_FLAKE_OVERRIDE_INPUTS='mylib=../my-lib;foo/nixpkgs=github:NixOS/nixpkgs/nixos-24.05'
```

**Effect** (conceptually):

```
--override-input mylib path:/ABS/PATH/TO/my-lib \
--override-input foo/nixpkgs github:NixOS/nixpkgs/nixos-24.05
```

### 2) `NIX_FLAKE_OVERRIDE_FLAKES`

Semicolon-delimited `orig=resolved` pairs mapping **registry names/refs** to another ref, mirroring `--override-flake`.

**Example**

```dotenv
# .env
NIX_FLAKE_OVERRIDE_FLAKES='nixpkgs=github:NixOS/nixpkgs/nixos-24.05;myfork=github:blocksense-network/fork'
```

**Effect**:

```
--override-flake nixpkgs github:NixOS/nixpkgs/nixos-24.05 \
--override-flake myfork github:blocksense-network/fork
```

> **Tip**: Use `NIX_FLAKE_OVERRIDE_INPUTS` for inputs declared inside `flake.nix`. Use `NIX_FLAKE_OVERRIDE_FLAKES` to rewrite registry lookups (e.g., command-line flake refs).

---

## Usage patterns

### Splice into `use flake`

```bash
flake_override_args FO_ARGS
use flake . "${FO_ARGS[@]}"
```

### Wrapper scripts

```bash
flake_overrides_install_wrappers .
PATH_add .direnv/bin
# now use:
ndev        # -> nix develop . <overrides…>
nbuild      # -> nix build   . <overrides…>
nrun        # -> nix run     . <overrides…>
# pass extra flags:
nbuild .#mypkg --rebuild
```

### Inline (alternative)

If you prefer a single call site and don’t mind `eval`, there’s a safe printer:

```bash
# Inside .envrc
eval "use flake . $(flake_override_args_quoted)"
```

---

## How it works

* The plugin parses the env vars, resolves directory values to absolute paths, and constructs the appropriate `--override-input` / `--override-flake` flag pairs.
* `flake_override_args OUT_ARR` fills a **bash array** so argument boundaries are preserved without quoting bugs.
* `flake_overrides_install_wrappers` bakes the computed flags into `.direnv/bin/{ndev,nbuild,nrun}` as tiny scripts so they persist beyond the `.envrc` subshell.

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

```bash
#!/usr/bin/env bash
# direnv-nix-flake-overrides
#
# Exposes helpers to translate two env vars into Nix flake CLI flags:
#   - NIX_FLAKE_OVERRIDE_INPUTS  => multiple --override-input <input> <ref>
#   - NIX_FLAKE_OVERRIDE_FLAKES  => multiple --override-flake <orig> <resolved>
#
# Primary API (recommended):
#   flake_override_args OUT_ARR
#     -> fills bash array OUT_ARR with all flags (inputs + flakes)
#
# Secondary APIs:
#   flake_override_input_args OUT_ARR   # inputs only
#   flake_override_flake_args OUT_ARR   # registry overrides only
#   flake_override_args_quoted          # prints flags shell-escaped for eval
#   flake_overrides_install_wrappers [flake='.']
#     -> emits .direnv/bin/{ndev,nbuild,nrun} with baked flags
#
# Requirements: bash >= 4.4, direnv >= 2.30, nix >= 2.18

set -o pipefail

# --- Internals --------------------------------------------------------------
_direnv_nfo_log() { log_status "flake-overrides: $*"; }

# Convert a semicolon-delimited KV list VAR (e.g., name=val;foo=bar) into
# pairs via callback: _nfo_each_kv VAR_NAME callback
# callback receives: name value
_nfo_each_kv() {
  local _var_name="$1" _cb="$2"
  local _raw
  # indirect expansion to read the named variable
  _raw="${!_var_name}"
  [[ -z "$_raw" ]] && return 0
  local IFS=';'
  # Read into array of entries split on semicolons
  read -r -a _entries <<< "$_raw"
  local _entry _name _val
  for _entry in "${_entries[@]}"; do
    [[ -z "$_entry" ]] && continue
    _name="${_entry%%=*}"
    _val="${_entry#*=}"
    if [[ -z "$_name" || -z "$_val" || "$_entry" == "$_name" ]]; then
      _direnv_nfo_log "ignoring malformed entry: '$_entry'"
      continue
    fi
    "$_cb" "$_name" "$_val"
  done
}

# Resolve a value: if it's a directory, coerce to path:/ABS
# else pass as-is.
_nfo_resolve_ref() {
  local _val="$1"
  if [[ -d $_val ]]; then
    local _abs
    if _abs="$(cd "$_val" 2>/dev/null && pwd -P)"; then
      [[ ! -f "$_abs/flake.nix" ]] && _direnv_nfo_log "warn '$_abs' has no flake.nix"
      printf 'path:%s' "$_abs"
      return 0
    else
      _direnv_nfo_log "cannot access dir '$_val'"
    fi
  fi
  printf '%s' "$_val"
}

# Append words to an OUT array by nameref
_nfo_out_append() {
  local _out_name="$1"; shift
  local -n _out="$_out_name"
  _out+=("$@")
}

# --- Public builders --------------------------------------------------------

# Build --override-input pairs from $NIX_FLAKE_OVERRIDE_INPUTS
flake_override_input_args() {
  local _out_name="$1"; [[ -z "$_out_name" ]] && { echo "need OUT_ARR" >&2; return 2; }
  local -n _out="$_out_name"; _out=()
  local _emit() {
    local name="$1" val="$2"
    local ref; ref="$(_nfo_resolve_ref "$val")"
    _out+=( --override-input "$name" "$ref" )
  }
  _nfo_each_kv NIX_FLAKE_OVERRIDE_INPUTS _emit
}

# Build --override-flake pairs from $NIX_FLAKE_OVERRIDE_FLAKES
flake_override_flake_args() {
  local _out_name="$1"; [[ -z "$_out_name" ]] && { echo "need OUT_ARR" >&2; return 2; }
  local -n _out="$_out_name"; _out=()
  local _emit() {
    local orig="$1" val="$2"
    local ref; ref="$(_nfo_resolve_ref "$val")"
    _out+=( --override-flake "$orig" "$ref" )
  }
  _nfo_each_kv NIX_FLAKE_OVERRIDE_FLAKES _emit
}

# Combine both kinds of overrides
flake_override_args() {
  local _out_name="$1"; [[ -z "$_out_name" ]] && { echo "need OUT_ARR" >&2; return 2; }
  local -n _out="$_out_name"; _out=()
  local A=() B=()
  flake_override_input_args A
  flake_override_flake_args B
  # Append preserving order: inputs then flakes
  _out+=("${A[@]}")
  _out+=("${B[@]}")
}

# Print shell-escaped override args (for `eval` use if desired)
flake_override_args_quoted() {
  local ARGS=()
  flake_override_args ARGS
  local w
  for w in "${ARGS[@]}"; do printf '%q ' "$w"; done
}

# Generate wrapper scripts into .direnv/bin and bake in current overrides
# Usage: flake_overrides_install_wrappers [flake='.'] [subcmd ...]
# Default subcmds: develop build run
flake_overrides_install_wrappers() {
  local flake="${1:-.}"; shift || true
  local subcmds=("${@:-develop build run}")
  local argsq; argsq="$(flake_override_args_quoted)"
  mkdir -p .direnv/bin
  for sub in "${subcmds[@]}"; do
    local name
    case "$sub" in
      develop) name=ndev ;;
      build)   name=nbuild ;;
      run)     name=nrun ;;
      *)       name="n$sub" ;;
    esac
    cat > ".direnv/bin/$name" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Rehydrate precomputed override args, then append any user args.
eval "set -- $argsq \"\$@\""
exec nix $sub ${flake@Q} "\$@"
EOF
    chmod +x ".direnv/bin/$name"
  done
}
```

### Example `.env`

```dotenv
# Point a flake input to a local checkout and pin nixpkgs via registry override
NIX_FLAKE_OVERRIDE_INPUTS='mylib=../my-lib;foo/nixpkgs=github:NixOS/nixpkgs/24.05'
NIX_FLAKE_OVERRIDE_FLAKES='nixpkgs=github:NixOS/nixpkgs/nixos-24.05'
```

### Example `.envrc` (full)

```bash
# Load plugin (pin to a commit and hash)
source_url "https://raw.githubusercontent.com/blocksense-network/direnv-nix-flake-overrides/<COMMIT>/plugin/flake-overrides.bash" \
           "sha256-PASTE_HASH_HERE="

# Load local overrides
dotenv_if_exists .env

# Build and splice
flake_override_args FO_ARGS
use flake . "${FO_ARGS[@]}"

# Optional wrappers
flake_overrides_install_wrappers .
PATH_add .direnv/bin

# Reload on changes
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

