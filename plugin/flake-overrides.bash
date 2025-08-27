#!/usr/bin/env bash
# direnv-nix-flake-overrides
#
# Exposes helpers to translate two env vars into Nix flake CLI flags:
#   - NIX_FLAKE_OVERRIDE_INPUTS  => multiple --override-input <input> <ref>
#   - NIX_FLAKE_OVERRIDE_FLAKES  => multiple --override-flake <orig> <resolved>
#
# Primary usage:
#   - Inline: eval "use flake . $(flake-override-args-quoted)"
#   - Arrays without eval: map words from collect-flake-override-args
#
# Public CLI helpers (auto-generated on source):
#   - flake-override-args-quoted          # prints flags shell-escaped for inline eval
#   - collect-flake-override-args         # prints one word per line (for mapfile/loops)
#   - with-local-flake-overrides          # leader for ad‑hoc `nix <subcmd>` usage
#
# On source: auto-install lightweight tools under .direnv/local-flake-overrides/bin
#  - with-local-flake-overrides
#  - flake-override-args-quoted
# and add that directory to PATH (via PATH_add if available).
#
# Requirements: direnv >= 2.30, nix >= 2.18
# Bash compatibility: Bash >= 3.2

set -o pipefail

# --- Internals --------------------------------------------------------------
_direnv_nfo_log() { log_status "flake-overrides: $*"; }

# Convert a delimited KV list VAR (e.g., name=val|foo=bar) into
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
  # Choose a delimiter not valid in URLs: prefer '|' normally, but if '^' is present, use '^'
  local _delim='|'
  case "$_raw" in
    *'^'*) _delim='^' ;;
    *'|'*) _delim='|' ;;
    *) _delim='|' ;;
  esac
  local IFS="$_delim"
  # Read into array of entries split on the chosen delimiter
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

# ---

# ---

# Print shell-escaped override args (for `eval` use if desired)
flake_override_args_quoted() {
  # Print shell-escaped override args without relying on nameref arrays
  _nfo_print_word() { local s="$1"; s=${s//\'/\'\\\'\'}; printf "'%s' " "$s"; }
  _nfo_print_pair() { _nfo_print_word "$1"; _nfo_print_word "$2"; _nfo_print_word "$3"; }
  _nfo_emit_in() { local name="$1" val="$2"; local ref; ref="$(_nfo_resolve_ref "$val")"; _nfo_print_pair --override-input "$name" "$ref"; }
  _nfo_emit_fk() { local orig="$1" val="$2"; local ref; ref="$(_nfo_resolve_ref "$val")"; _nfo_print_pair --override-flake "$orig" "$ref"; }
  _nfo_each_kv NIX_FLAKE_OVERRIDE_INPUTS _nfo_emit_in
  _nfo_each_kv NIX_FLAKE_OVERRIDE_FLAKES _nfo_emit_fk
}

# Auto-tools are generated on source

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
  # Baked CLI printer using array literal for safety
  cat > "$bindir/flake-override-args-quoted" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ARGS=( $argsq )
for w in "\${ARGS[@]}"; do
  s=\$w
  s=\${s//\'/\'\\\'\'}
  printf "'%s' " "\$s"
done
EOF
  chmod +x "$bindir/flake-override-args-quoted"
  # Generic leader wrapper around nix subcommands (array-safe)
  cat > "$bindir/with-local-flake-overrides" <<EOF
#!/usr/bin/env bash
set -euo pipefail
OV=( $argsq )
if (( \$# == 0 )); then
  echo "usage: with-local-flake-overrides nix <subcmd> [args...]" >&2
  exit 2
fi
if [[ "\$1" != "nix" ]]; then
  exec "\$@"
fi
cmd="\$1"; shift || true
sub="\${1-}"
if [[ -z "\$sub" ]]; then
  exec "\$cmd" "\${OV[@]}" "\$@"
fi
shift || true
exec "\$cmd" "\$sub" "\${OV[@]}" "\$@"
EOF
  chmod +x "$bindir/with-local-flake-overrides"
  # Newline-delimited collector (for arrays without eval): mapfile -t ARGS < <(collect-flake-override-args)
  cat > "$bindir/collect-flake-override-args" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ARGS=( $argsq )
printf '%s\n' "\${ARGS[@]}"
EOF
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
