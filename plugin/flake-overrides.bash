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

# Unconditional notice on **stderr**. Never stdout: stdout is spliced verbatim
# into `use flake …`, so a single stray word there corrupts the command line.
# Deliberately not routed through `log_status`, which direnv silences when
# DIRENV_LOG_FORMAT is empty — these notices describe files that will be
# missing from the build and must not be swallowed.
_nfo_notice() { printf 'flake-overrides: %s\n' "$1" >&2; }

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

# --- Local-directory flake refs ---------------------------------------------
# A local checkout can be handed to Nix two ways, and the choice is not a
# detail:
#
#   path:/ABS       copies the *entire* directory tree into the store and does
#                   not honour .gitignore. A sibling carrying build output
#                   (Rust target/, nimcache/, node_modules/) is copied in full
#                   on every lock change — measured at 19 GB / ~50 minutes for
#                   one real repo. Worse, the store path is content-addressed
#                   over all of it, so touching any generated file changes the
#                   input hash and silently invalidates the dev shell.
#
#   git+file://ABS  enumerates through git: gitignored content is skipped
#                   (19 GB -> 75 MB, ~50 min -> 13 s for that same repo) while
#                   **uncommitted edits to tracked files still reach the
#                   store**, which is the guarantee develop mode rests on.
#
# git+file: has two sharp edges, handled below rather than hidden:
#   - Untracked (not merely unignored-but-new) files are invisible to it. We
#     never silently downgrade to path: for them — one editor scratch file
#     would restore the 50-minute copy — we emit a loud notice instead.
#   - Submodule content is dropped unless ?submodules=1 is requested, but
#     ?submodules=1 hard-fails on an *uninitialised* submodule, the state of
#     any clone made without --recurse-submodules. So it is applied only when
#     every submodule is initialised; otherwise we fall back to path:, which
#     is faithful to what is on disk and cannot fail.

# How many untracked paths to name before summarising the rest.
_NFO_UNTRACKED_LIST_CAP=8

# Warn about files git does not know about, which git+file: will therefore not
# hand to Nix. `git add` alone is the whole remedy — no commit required.
_nfo_warn_untracked() {
  local _abs="$1" _list _f _count=0 _shown=0 _more
  _list="$(git -C "$_abs" ls-files --others --exclude-standard 2>/dev/null || true)"
  [[ -z "$_list" ]] && return 0
  while IFS= read -r _f; do
    [[ -n "$_f" ]] && _count=$(( _count + 1 ))
  done <<< "$_list"
  (( _count == 0 )) && return 0
  _nfo_notice "NOTICE: '$_abs' is overridden via git+file:, which lists files through git."
  _nfo_notice "  $_count untracked file(s) are therefore NOT part of what the dev shell builds:"
  while IFS= read -r _f; do
    [[ -z "$_f" ]] && continue
    (( _shown >= _NFO_UNTRACKED_LIST_CAP )) && break
    _nfo_notice "    $_f"
    _shown=$(( _shown + 1 ))
  done <<< "$_list"
  _more=$(( _count - _shown ))
  (( _more > 0 )) && _nfo_notice "    ... and $_more more (of $_count total)"
  _nfo_notice "  To include them, run:  git -C '$_abs' add <path>..."
  _nfo_notice "  Staging is enough - no commit is needed - and once a file is tracked,"
  _nfo_notice "  later worktree edits to it flow into the shell normally."
  return 0
}

# Warn that ?submodules=1 cannot be used, and say exactly how to earn it back.
_nfo_warn_uninit_submodules() {
  local _abs="$1" _subs="$2" _s
  _nfo_notice "NOTICE: '$_abs' has uninitialised submodule(s):"
  while IFS= read -r _s; do
    [[ -n "$_s" ]] && _nfo_notice "    $_s"
  done <<< "$_subs"
  _nfo_notice "  Nix cannot fetch a git+file: tree with submodules unless they are checked"
  _nfo_notice "  out, so this override falls back to path:, which copies the whole directory"
  _nfo_notice "  tree into the store - gitignored build output included - and can be slow."
  _nfo_notice "  To restore the fast override, run:"
  _nfo_notice "    git -C '$_abs' submodule update --init --recursive"
  return 0
}

# Print the flake ref for an existing absolute directory: git+file:// when git
# can faithfully enumerate it, path: otherwise.
_nfo_dir_flake_ref() {
  local _abs="$1"
  # No git at all: nothing to enumerate with.
  command -v git >/dev/null 2>&1 || { printf 'path:%s' "$_abs"; return 0; }

  # Only the *root* of a work tree qualifies. `git+file://<subdir>` would
  # fetch the whole enclosing repository, not the subdirectory asked for.
  local _top
  _top="$(git -C "$_abs" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$_top" ]] || { printf 'path:%s' "$_abs"; return 0; }
  _top="$(cd "$_top" 2>/dev/null && pwd -P)" || { printf 'path:%s' "$_abs"; return 0; }
  [[ "$_top" == "$_abs" ]] || { printf 'path:%s' "$_abs"; return 0; }

  # An unborn HEAD (freshly `git init`ed, nothing committed) gives git no tree
  # to hand over.
  git -C "$_abs" rev-parse --verify --quiet HEAD >/dev/null 2>&1 \
    || { printf 'path:%s' "$_abs"; return 0; }

  local _query=""
  if [[ -f "$_abs/.gitmodules" ]]; then
    # `git submodule status` marks an uninitialised submodule with a leading
    # '-'; the remaining fields are "<sha> <path>[ (describe)]".
    local _status _line _rest _uninit=""
    _status="$(git -C "$_abs" submodule status --recursive 2>/dev/null || true)"
    while IFS= read -r _line; do
      [[ "$_line" == -* ]] || continue
      _rest="${_line#-}"
      _rest="${_rest#* }"
      _rest="${_rest%% (*}"
      [[ -n "$_rest" ]] && _uninit="${_uninit}${_rest}
"
    done <<< "$_status"
    if [[ -n "$_uninit" ]]; then
      _nfo_warn_uninit_submodules "$_abs" "$_uninit"
      printf 'path:%s' "$_abs"
      return 0
    fi
    _query="?submodules=1"
  fi

  _nfo_warn_untracked "$_abs"
  printf 'git+file://%s%s' "$_abs" "$_query"
}

# Resolve a value: if it's a directory, coerce to a local flake ref
# (git+file://ABS, or path:/ABS — see _nfo_dir_flake_ref); else pass as-is.
_nfo_resolve_ref() {
  local _val="$1"
  local _base="${DIRENV_DIR:-}"
  _base="${_base#-}"  # direnv prefixes DIRENV_DIR with '-'
  if [[ -d "$_val" ]]; then
    local _abs
    if _abs="$(cd "$_val" 2>/dev/null && pwd -P)"; then
      [[ ! -f "$_abs/flake.nix" ]] && _direnv_nfo_log "warn '$_abs' has no flake.nix"
      _nfo_dir_flake_ref "$_abs"
      return 0
    else
      _direnv_nfo_log "cannot access dir '$_val'"
    fi
  elif [[ -n "$_base" && -d "$_base/$_val" ]]; then
    local _abs2
    if _abs2="$(cd "$_base/$_val" 2>/dev/null && pwd -P)"; then
      [[ ! -f "$_abs2/flake.nix" ]] && _direnv_nfo_log "warn '$_abs2' has no flake.nix"
      _nfo_dir_flake_ref "$_abs2"
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
    local ref; ref="$(_nfo_dir_flake_ref "$abs")"
    _nfo_print_pair --override-input "$input" "$ref"
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
