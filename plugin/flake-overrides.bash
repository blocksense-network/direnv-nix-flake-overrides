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
#   flake_overrides_install_wrappers [flake='.'] (legacy/optional)
#     -> emits .direnv/bin/{local-nix-develop,local-nix-build,local-nix-run}
#        plus a helper printer .direnv/bin/flake-override-args-quoted (baked)
#   flake_overrides_install_leader [name='with-local-flake-overrides'] (legacy/optional)
#     -> emits .direnv/bin/<name> that injects overrides into `nix <subcmd> ...`
#
# On source: auto-install lightweight tools under .direnv/local-flake-overrides/bin
#  - with-local-flake-overrides
#  - flake-override-args-quoted
# and add that directory to PATH (via PATH_add if available).
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
  local _raw=""
  # Safely read the named variable even under `set -u`
  # Temporarily disable nounset if enabled
  local _had_u=0
  case $- in *u*) _had_u=1; set +u ;; esac
  _raw="${!_var_name}"
  (( _had_u )) && set -u
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
  local _base="${DIRENV_DIR:-}"
  if [[ -d "$_val" ]]; then
    local _abs
    if _abs="$(cd "$_val" 2>/dev/null && pwd -P)"; then
      [[ ! -f "$_abs/flake.nix" ]] && _direnv_nfo_log "warn '$_abs' has no flake.nix"
      printf 'path:%s' "$_abs"
      return 0
    else
      _direnv_nfo_log "cannot access dir '$_val'"
    fi
  elif [[ -n "$_base" && -d "$_base/$_val" ]]; then
    local _abs2
    if _abs2="$(cd "$_base/$_val" 2>/dev/null && pwd -P)"; then
      [[ ! -f "$_abs2/flake.nix" ]] && _direnv_nfo_log "warn '$_abs2' has no flake.nix"
      printf 'path:%s' "$_abs2"
      return 0
    else
      _direnv_nfo_log "cannot access dir '$_base/$_val'"
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
  local -a subcmds
  if (( $# > 0 )); then
    subcmds=("$@")
  else
    subcmds=(develop build run)
  fi
  local argsq; argsq="$(flake_override_args_quoted)"
  mkdir -p .direnv/bin
  for sub in "${subcmds[@]}"; do
    local name
    case "$sub" in
      develop) name=local-nix-develop ;;
      build)   name=local-nix-build ;;
      run)     name=local-nix-run ;;
      *)       name="local-nix-$sub" ;;
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

  # Also provide a baked printer with a command-style name for convenience
  cat > .direnv/bin/flake-override-args-quoted <<EOF
#!/usr/bin/env bash
# Prints the baked, shell-escaped override args
printf '%s' "$argsq"
EOF
  chmod +x .direnv/bin/flake-override-args-quoted
}

# Leader that injects overrides into nix invocations generically.
# Usage: with-local-flake-overrides nix <subcmd> [args...]
flake_overrides_install_leader() {
  local name="${1:-with-local-flake-overrides}"
  local argsq; argsq="$(flake_override_args_quoted)"
  mkdir -p .direnv/bin
  cat > ".direnv/bin/$name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
argsq='__ARGSQ_PLACEHOLDER__'
if (( $# == 0 )); then
  echo "usage: with-local-flake-overrides nix <subcmd> [args...]" >&2
  exit 2
fi
if [[ "$1" != "nix" ]]; then
  # Not a nix invocation; run as-is
  exec "$@"
fi
cmd="$1"; shift || true
sub="${1-}"
if [[ -z "$sub" ]]; then
  # No subcommand; just append flags to whatever follows (if anything)
  declare -a OV=()
  eval "OV=($argsq)"
  exec "$cmd" "${OV[@]}" "$@"
fi
shift || true
# Insert subcommand first, then overrides, then remaining args using arrays
declare -a OV=()
eval "OV=($argsq)"
exec "$cmd" "$sub" "${OV[@]}" "$@"
EOF
  # Inject the precomputed args into the file safely
  # shellcheck disable=SC2001
  sed -i.bak "s|__ARGSQ_PLACEHOLDER__|$(printf '%s' "$argsq" | sed 's/[\&/]/\\&/g')|" ".direnv/bin/$name" && rm -f ".direnv/bin/$name.bak"
  chmod +x ".direnv/bin/$name"
}

# Auto-install minimal tools into .direnv/local-flake-overrides/bin and add to PATH
_nfo_autoinstall_tools() {
  local argsq; argsq="$(flake_override_args_quoted)"
  local base_dir=".direnv/local-flake-overrides"
  local bindir="$base_dir/bin"
  mkdir -p "$bindir"
  # VCS ignore: keep directory silent in Git (and most tools)
  if [[ ! -f "$base_dir/.gitignore" ]]; then
    printf '*\n!.gitignore\n' > "$base_dir/.gitignore" || true
  fi
  # Baked CLI printer with args injected safely
  cat > "$bindir/flake-override-args-quoted" <<'EOF'
#!/usr/bin/env bash
argsq='__ARGSQ_PLACEHOLDER__'
printf '%s' "$argsq"
EOF
  sed -i.bak "s|__ARGSQ_PLACEHOLDER__|$(printf '%s' "$argsq" | sed 's/[\&/]/\\&/g')|" "$bindir/flake-override-args-quoted" && rm -f "$bindir/flake-override-args-quoted.bak"
  chmod +x "$bindir/flake-override-args-quoted"
  # Generic leader wrapper around nix subcommands (array-safe)
  cat > "$bindir/with-local-flake-overrides" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
argsq='__ARGSQ_PLACEHOLDER__'
if (( $# == 0 )); then
  echo "usage: with-local-flake-overrides nix <subcmd> [args...]" >&2
  exit 2
fi
if [[ "$1" != "nix" ]]; then
  exec "$@"
fi
cmd="$1"; shift || true
sub="${1-}"
if [[ -z "$sub" ]]; then
  declare -a OV=(); eval "OV=($argsq)"; exec "$cmd" "${OV[@]}" "$@"
fi
shift || true
declare -a OV=(); eval "OV=($argsq)"
exec "$cmd" "$sub" "${OV[@]}" "$@"
EOF
  # Inject args safely
  sed -i.bak "s|__ARGSQ_PLACEHOLDER__|$(printf '%s' "$argsq" | sed 's/[\&/]/\\&/g')|" "$bindir/with-local-flake-overrides" && rm -f "$bindir/with-local-flake-overrides.bak"
  chmod +x "$bindir/with-local-flake-overrides"
  # Newline-delimited collector (for arrays without eval): mapfile -t ARGS < <(collect-flake-override-args)
  cat > "$bindir/collect-flake-override-args" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
argsq='__ARGSQ_PLACEHOLDER__'
eval "set -- $argsq"
printf '%s\n' "$@"
EOF
  sed -i.bak "s|__ARGSQ_PLACEHOLDER__|$(printf '%s' "$argsq" | sed 's/[\&/]/\\&/g')|" "$bindir/collect-flake-override-args" && rm -f "$bindir/collect-flake-override-args.bak"
  chmod +x "$bindir/collect-flake-override-args"
  # PATH
  if command -v PATH_add >/dev/null 2>&1; then
    PATH_add "$bindir" || true
  else
    case ":$PATH:" in *":$bindir:"*) : ;; *) export PATH="$bindir:$PATH" ;; esac
  fi
}

# Run auto-install on source
_nfo_autoinstall_tools || true
