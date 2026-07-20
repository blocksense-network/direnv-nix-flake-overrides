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

# The `_nfo_emit_*` helpers are invoked indirectly, by name, through the
# `_nfo_each_kv` / `_nfo_each_sibling` / `_nfo_auto_override` dispatchers, so
# ShellCheck's "never invoked" heuristic does not see the call sites.
# shellcheck disable=SC2329

set -o pipefail

# --- Internals --------------------------------------------------------------
_direnv_nfo_log() { log_status "flake-overrides: $*"; }

# direnv exports DIRENV_DIR as '-' followed by the absolute project path; strip
# that marker to get a usable directory. Falls back to $PWD outside direnv
# (e.g. when the plugin is sourced directly, as in the tests).
_nfo_project_dir() {
  local _d="${DIRENV_DIR:-}"
  _d="${_d#-}"
  if [[ -n "$_d" ]]; then printf '%s' "$_d"; else printf '%s' "$PWD"; fi
}

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
  _base="${_base#-}"  # direnv prefixes DIRENV_DIR with '-'
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

# --- Sibling auto-detection -------------------------------------------------
# Two convenience layers on top of the explicit NIX_FLAKE_OVERRIDE_INPUTS:
#   - NIX_FLAKE_OVERRIDE_SIBLINGS: a curated list of inputs to override with a
#     local checkout *iff* that checkout is present.
#   - NIX_FLAKE_OVERRIDE_AUTO:     probe every flake input for a same-named
#     sibling, so no list needs to be maintained.
# Both resolve sibling directories under NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT
# (default: the parent of the project directory — the usual side-by-side
# checkout layout) and silently skip inputs whose sibling is absent.

# Truthy test for opt-in flags.
_nfo_is_true() {
  case "${1:-}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

# Root directory under which local sibling checkouts live.
_nfo_siblings_root() {
  local _root="${NIX_FLAKE_OVERRIDE_SIBLINGS_ROOT:-}"
  if [[ -z "$_root" ]]; then
    _root="$(_nfo_project_dir)/.."
  fi
  ( cd "$_root" 2>/dev/null && pwd -P ) || printf '%s' "$_root"
}

# Iterate NIX_FLAKE_OVERRIDE_SIBLINGS entries as `callback <input> <dir>`.
# Each entry is `<name>` (input name == sibling dir name) or `<input>=<dir>`.
_nfo_each_sibling() {
  local _cb="$1" _raw="" _had_u=0
  case $- in *u*) _had_u=1; set +u ;; esac
  _raw="${NIX_FLAKE_OVERRIDE_SIBLINGS:-}"
  (( _had_u )) && set -u
  [[ -z "$_raw" ]] && return 0
  local _delim='|'
  case "$_raw" in *'^'*) _delim='^' ;; esac
  local IFS="$_delim"
  local _entries=()
  read -r -a _entries <<< "$_raw"
  local _entry _input _dir
  for _entry in "${_entries[@]}"; do
    [[ -z "$_entry" ]] && continue
    if [[ "$_entry" == *=* ]]; then
      _input="${_entry%%=*}"; _dir="${_entry#*=}"
    else
      _input="$_entry"; _dir="$_entry"
    fi
    if [[ -z "$_input" || -z "$_dir" ]]; then
      _direnv_nfo_log "ignoring malformed sibling entry: '$_entry'"
      continue
    fi
    "$_cb" "$_input" "$_dir"
  done
}

# Print the flake input names declared in the current project's flake, one per
# line, from the lock via `nix flake metadata --json`. Requires nix and jq;
# prints nothing (and warns) if either is missing or the flake can't be read.
# Overridable in tests by redefining this function.
_nfo_flake_input_names() {
  if ! command -v nix >/dev/null 2>&1; then
    _direnv_nfo_log "auto-override: 'nix' not found; skipping"; return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    _direnv_nfo_log "auto-override: 'jq' not found; skipping"; return 1
  fi
  local _dir; _dir="$(_nfo_project_dir)"
  nix flake metadata "$_dir" --json --no-write-lock-file 2>/dev/null \
    | jq -r '.locks as $l | ($l.nodes[$l.root].inputs // {}) | keys[]' 2>/dev/null
}

# Full auto-override: for every flake input, look for a same-named sibling and,
# if present, emit an override via `callback <input> <dir>`. The optional
# NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES (comma/space list, e.g. "-src,-flake")
# lets an input like `foo-src` match a sibling named `foo`.
_nfo_auto_override() {
  local _cb="$1"
  local _names; _names="$(_nfo_flake_input_names)" || return 0
  [[ -z "$_names" ]] && return 0
  local _root; _root="$(_nfo_siblings_root)"
  local _sfxs="${NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES:-}"
  local _name _cands _try _s _oldifs
  while IFS= read -r _name; do
    [[ -z "$_name" ]] && continue
    _cands="$_name"
    if [[ -n "$_sfxs" ]]; then
      _oldifs="$IFS"; IFS=', '
      for _s in $_sfxs; do
        [[ -n "$_s" && "$_name" == *"$_s" ]] && _cands="$_cands ${_name%"$_s"}"
      done
      IFS="$_oldifs"
    fi
    for _try in $_cands; do
      if [[ -d "$_root/$_try" ]]; then
        "$_cb" "$_name" "$_try"
        break
      fi
    done
  done <<< "$_names"
}

# Print shell-escaped override args (for `eval` use if desired). Emits, in
# precedence order — explicit wins; each input is overridden at most once:
#   1) NIX_FLAKE_OVERRIDE_INPUTS   (explicit --override-input)
#   2) NIX_FLAKE_OVERRIDE_SIBLINGS (curated list; present siblings only)
#   3) NIX_FLAKE_OVERRIDE_AUTO     (every flake input with a same-named sibling)
#   4) NIX_FLAKE_OVERRIDE_FLAKES   (--override-flake)
#
# The nested `_nfo_*` helpers below are invoked indirectly — by name, as
# callbacks passed to _nfo_each_kv / _nfo_each_sibling / _nfo_auto_override —
# which shellcheck's reachability analysis can't follow, so it reports every
# helper body as unreachable (SC2317). They are all reached; suppress the
# false positive for this function.
# shellcheck disable=SC2317
flake_override_args_quoted() {
  # Print shell-escaped override args without relying on nameref arrays
  _nfo_print_word() { local s="$1"; s=${s//\'/\'\\\'\'}; printf "'%s' " "$s"; }
  _nfo_print_pair() { _nfo_print_word "$1"; _nfo_print_word "$2"; _nfo_print_word "$3"; }

  # Inputs already overridden by a higher-precedence rule, so a duplicate
  # --override-input is never emitted for the same input. Space-delimited
  # (input names contain no spaces); works on Bash 3.2 (no associative arrays).
  local _nfo_claimed=" "
  _nfo_claim() { _nfo_claimed="${_nfo_claimed}$1 "; }
  _nfo_is_claimed() { [[ "$_nfo_claimed" == *" $1 "* ]]; }

  _nfo_emit_in() {
    local name="$1" val="$2"
    _nfo_is_claimed "$name" && return 0
    local ref; ref="$(_nfo_resolve_ref "$val")"
    _nfo_print_pair --override-input "$name" "$ref"
    _nfo_claim "$name"
  }
  # Override <input> with <root>/<dir>, but only if that directory exists.
  # Shared by the curated sibling list and the full auto-override.
  _nfo_emit_sibling() {
    local input="$1" dir="$2"
    _nfo_is_claimed "$input" && return 0
    local root; root="$(_nfo_siblings_root)"
    local cand="$root/$dir" abs
    [[ -d "$cand" ]] || return 0
    abs="$(cd "$cand" 2>/dev/null && pwd -P)" || return 0
    if [[ ! -f "$abs/flake.nix" ]]; then
      _direnv_nfo_log "warn sibling '$abs' has no flake.nix; skipping"
      return 0
    fi
    _nfo_print_pair --override-input "$input" "path:$abs"
    _nfo_claim "$input"
  }
  _nfo_emit_fk() { local orig="$1" val="$2"; local ref; ref="$(_nfo_resolve_ref "$val")"; _nfo_print_pair --override-flake "$orig" "$ref"; }

  _nfo_each_kv NIX_FLAKE_OVERRIDE_INPUTS _nfo_emit_in
  _nfo_each_sibling _nfo_emit_sibling
  if _nfo_is_true "${NIX_FLAKE_OVERRIDE_AUTO:-}"; then
    _nfo_auto_override _nfo_emit_sibling
  fi
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
