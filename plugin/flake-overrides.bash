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
  _emit() {
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
  _emit() {
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
eval "set -- $argsq \"$@\""
exec nix $sub ${flake@Q} "$@"
EOF
    chmod +x ".direnv/bin/$name"
  done
}
