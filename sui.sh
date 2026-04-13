#!/usr/bin/env bash
#
# sui — Sudo User Interface (unified privilege gateway)
#
# Purpose:
#   - Give agents and humans ONE predictable GUI flow for local and remote root
#     commands, with full argv preserved (no fragile "$*" reassembly).
#   - Optional Polkit path for desktop users who prefer pkexec over zenity+sudo.
#   - Emit audit records compatible with traditional auth logging (syslog authpriv),
#     which on many distros is merged into /var/log/auth.log alongside sudo(8).
#
# Usage:
#   sui [options] [@ssh-target] <command> [args...]
#
# Options:
#   --polkit     Local only: use pkexec(1) instead of the unified zenity+sudo dialog.
#   --dry-run    Print (and optionally show) what would run; never prompts; no elevation.
#   -h, --help Show this summary.
#
# Environment:
#   SUI_LOG=1    Also append audit lines to ${XDG_STATE_HOME:-$HOME/.local/state}/sui/audit.log
#
# Install (example):
#   install -m 0755 sui.sh /usr/local/bin/sui
#
# Notes on auditing:
#   - Real sudo(8) invocations are still logged by sudoers defaults (e.g. auth.log lines).
#   - This script adds explicit "sui" syslog entries via logger(1) at authpriv.notice so
#     operators can grep for the wrapper even when Polkit is used (--polkit).
#   - Secrets (passwords) are never written to logs.
#
# Shell strictness (why not `set -e` here):
#   - `-u` / `nounset`: expanding an unset variable is an error. Catches typos and forgotten
#     defaults instead of silently running with empty values (important for paths and targets).
#   - `-o pipefail`: in `cmd1 | cmd2`, the pipeline fails if any stage fails, not only if the
#     last command fails. Otherwise a failing `printf`/`ssh` producer could be masked.
#   - We omit `errexit` (`-e`) so the script can use explicit `||`, `if`, and user-facing
#     flows (e.g. zenity cancel) without needing `|| true` everywhere.
set -uo pipefail

readonly SUI_VERSION="3.1.0"

# ---------------------------------------------------------------------------
# Globals (shared state for parse_args, audit logging, and execution helpers)
#
# Why globals: bash functions cannot return arrays or structured argv; we stash parsed
# results here so main() and helpers share state without passing many positional parameters.
# ---------------------------------------------------------------------------
# Where elevation runs: "local" (this machine) vs "remote" (via ssh). Set in parse_args().
SUI_SCOPE="local"
# Host label for logs/UI: "local", or the SSH target string after stripping @ (e.g. homelab).
SUI_TARGET="local"
# Username running sui (before sudo). Filled in main(); used in zenity text and sui_audit.
SUI_INVOKER=""
# Numeric uid of the invoker. Filled in main(); distinguishes already-root (0) vs needs elevation.
SUI_UID=""
# Single-line, bash-quoted copy of argv for syslog/file audit (no secrets). Set in main() after parse_args.
SUI_CMD_REPR=""
# Parsed command line: executable path/name plus arguments, after removing flags and optional @target.
# Populated as SUI_CMD=("$@") at end of parse_args(); executed via "${SUI_CMD[@]}" to preserve argv.
SUI_CMD=()
# Parsed from --polkit: local path uses pkexec instead of zenity+sudo (desktop habit). Remote ignores it.
USE_POLKIT=0
# Parsed from --dry-run: show intent only; sui_audit dry-run + zenity info or stdout; no elevation.
DRY_RUN=0
# Sudo password from zenity; kept only between read and first sudo/ssh pipe, then unset -v PASS.
PASS=""
SUDO_CACHE=0
AUTH_MAX_ATTEMPTS=3
EXIT_CANCELLED=130
EXIT_AUTH_FAILED=77

# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
sui — Sudo User Interface (privileged command gateway)

Usage:
  sui [options] [@ssh-target] <command> [args...]
  sui doctor

Options (must appear before @target and command):
  --polkit     Local elevation via pkexec (Polkit). Ignored for remote targets.
  --dry-run    Show intent only; no password; no execution.
  --doctor     Print runtime diagnostics (zenity/pkexec/sudo/ssh/gui/tty).
  --sudo-cache    Allow sudo timestamp cache (fewer prompts, less strict).
  --no-sudo-cache Enforce secure mode (default): invalidate timestamp each run.
  -h, --help   This help.

Environment:
  SUI_LOG=1    Also append audit lines to $XDG_STATE_HOME/sui/audit.log (default: ~/.local/state).
  SUI_ZENITY_STDERR=1  Keep zenity stderr visible (default: suppress GUI/MESA noise).

Examples:
  sui apt update
  sui --dry-run @docker-host systemctl restart nginx
  sui --polkit -- gparted

Auditing:
  Real runs log via logger(1) at authpriv.notice (often merged into /var/log/auth.log).
  dry-run uses user.notice. Passwords are never logged.
EOF
}

# ---------------------------------------------------------------------------
# Build a single-line, bash-safe representation of argv for logs and dialogs.
# Why: "$*" and string concatenation break on spaces/quotes; %q per argument does not.
# ---------------------------------------------------------------------------
cmd_repr() {
  local out="" a
  for a in "$@"; do
    printf -v out '%s %q' "$out" "$a"
  done
  printf '%s\n' "${out# }"
}

# ---------------------------------------------------------------------------
# Multi-line body for zenity --forms --text=...
# The argv is always shown in a high-visibility block (never concealed): readability and safety first.
# ---------------------------------------------------------------------------
zenity_body() {
  local mode=$1       # LOCAL-ZENITY | REMOTE-ZENITY | DRY-RUN
  local target=$2
  shift 2
  local pretty
  pretty="$(cmd_repr "$@")"
  local scope_u
  scope_u="${SUI_SCOPE^^}"

  cat <<EOF
═══════════════════════════════════════════════════════════
  ${scope_u} ROOT ELEVATION  ·  sui v${SUI_VERSION}
═══════════════════════════════════════════════════════════

Read the COMMAND block below: it is exactly what will run with privileges.

Context
  Scope:     ${SUI_SCOPE}
  Target:    ${target}
  Invoker:   ${SUI_INVOKER} (uid ${SUI_UID})
  Host:      $(hostname 2>/dev/null || echo unknown)
  CWD:       $(pwd 2>/dev/null || echo unknown)
  Time:      $(date -Iseconds 2>/dev/null || date)
  Channel:   ${mode}

=============================================================
COMMAND (exact argv · bash-quoted · runs as root after OK)
=============================================================

  ${pretty}

=============================================================

Enter your password in the field below, or Cancel.
EOF
}

# ---------------------------------------------------------------------------
# Audit trail: syslog authpriv (often appears in /var/log/auth.log) + optional file.
# Why authpriv: matches sudo/sshd facility conventions on typical rsyslog rulesets.
# phase: invoke | dry-run | cancel | error
# ---------------------------------------------------------------------------
sui_audit() {
  local phase=$1
  local msg
  msg="phase=${phase} scope=${SUI_SCOPE} target=${SUI_TARGET} invoker=${SUI_INVOKER} uid=${SUI_UID} cmd=${SUI_CMD_REPR}"

  if command -v logger >/dev/null 2>&1; then
    # dry-run is not a real authentication event — keep it out of authpriv by default
    if [[ "$phase" == "dry-run" ]]; then
      logger -t sui -p user.notice --id=$$ -- "$msg"
    else
      logger -t sui -p authpriv.notice --id=$$ -- "$msg"
    fi
  else
    printf '%s\n' "sui: logger(1) not found; audit: $msg" >&2
  fi

  if [[ "${SUI_LOG:-0}" == "1" ]]; then
    local statedir="${XDG_STATE_HOME:-$HOME/.local/state}/sui"
    mkdir -p "$statedir"
    printf '%s %s\n' "$(date -Iseconds 2>/dev/null || date)" "$msg" >>"${statedir}/audit.log"
  fi
}

# ---------------------------------------------------------------------------
# GUI / TTY helpers
# ---------------------------------------------------------------------------
have_display() {
  [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]
}

have_zenity_gui() {
  command -v zenity >/dev/null 2>&1 && have_display
}

zenity_run() {
  # Force GTK software/cairo rendering to avoid noisy Vulkan/MESA warnings on some Intel stacks.
  # By default we silence remaining GUI stderr noise; set SUI_ZENITY_STDERR=1 to debug.
  if [[ "${SUI_ZENITY_STDERR:-0}" == "1" ]]; then
    GSK_RENDERER=cairo zenity "$@"
  else
    GSK_RENDERER=cairo zenity "$@" 2>/dev/null
  fi
}

tty_password_prompt() {
  local prompt=$1
  local p1=""
  if [[ ! -t 0 ]]; then
    return 1
  fi
  read -r -s -p "$prompt" p1
  printf '\n' >&2
  printf '%s' "$p1"
}

notify_auth_failure() {
  local msg=$1
  # Always print to shell for traceability, even when a GUI popup is shown.
  printf '%s\n' "sui: $msg" >&2
  if have_zenity_gui; then
    zenity_run --error --title="sui — authentication failed" --text="$msg" --width=520 --height=160 || true
  fi
}

sudo_validate_local_password() {
  local pass=$1
  if [[ "$SUDO_CACHE" -eq 1 ]]; then
    printf '%s\n' "$pass" | sudo -S -p '' -v >/dev/null 2>&1
  else
    printf '%s\n' "$pass" | sudo -S -k -p '' -v >/dev/null 2>&1
  fi
}

sudo_execute_local_with_ticket() {
  local ec
  sudo -n -p '' -- "$@"
  ec=$?
  if [[ "$SUDO_CACHE" -eq 0 ]]; then
    sudo -k >/dev/null 2>&1 || true
  fi
  return "$ec"
}

sudo_validate_remote_password() {
  local target=$1
  local pass=$2
  if [[ "$SUDO_CACHE" -eq 1 ]]; then
    printf '%s\n' "$pass" | ssh -o 'BatchMode=no' -- "$target" 'sudo -S -p "" -v' >/dev/null 2>&1
  else
    printf '%s\n' "$pass" | ssh -o 'BatchMode=no' -- "$target" 'sudo -S -k -p "" -v' >/dev/null 2>&1
  fi
}

sudo_execute_remote_with_ticket() {
  local target=$1
  shift
  local ec
  {
    printf 'set -euo pipefail\n'
    printf 'exec'
    local a
    for a in "$@"; do
      printf ' %q' "$a"
    done
    printf '\n'
  } | ssh -o 'BatchMode=no' -- "$target" 'sudo -n -p "" -- bash -s'
  ec=$?
  if [[ "$SUDO_CACHE" -eq 0 ]]; then
    ssh -o 'BatchMode=no' -- "$target" 'sudo -n -k' >/dev/null 2>&1 || true
  fi
  return "$ec"
}

print_doctor() {
  printf '%s\n' "sui doctor v${SUI_VERSION}"
  printf '%s\n' "---------------------"
  printf 'user: %s (uid %s)\n' "$(id -un)" "$(id -u)"
  printf 'cwd: %s\n' "$(pwd)"
  printf 'display: DISPLAY=%s WAYLAND_DISPLAY=%s\n' "${DISPLAY:-<unset>}" "${WAYLAND_DISPLAY:-<unset>}"
  printf 'tty-stdin: %s\n' "$([[ -t 0 ]] && echo yes || echo no)"
  printf 'tty-stdout: %s\n' "$([[ -t 1 ]] && echo yes || echo no)"
  printf 'zenity: %s\n' "$({ command -v zenity >/dev/null 2>&1 && echo yes || echo no; })"
  printf 'pkexec: %s\n' "$({ command -v pkexec >/dev/null 2>&1 && echo yes || echo no; })"
  printf 'sudo: %s\n' "$({ command -v sudo >/dev/null 2>&1 && echo yes || echo no; })"
  printf 'ssh: %s\n' "$({ command -v ssh >/dev/null 2>&1 && echo yes || echo no; })"
  printf 'gui-capable-now: %s\n' "$({ have_zenity_gui && echo yes || echo no; })"
  printf '%s\n' ""
  printf '%s\n' "fallback-order-local: zenity -> pkexec -> tty-password+sudo"
  printf '%s\n' "fallback-order-remote: zenity -> tty-password+ssh+sudo"
  printf 'sudo-cache-mode: %s\n' "$([[ "$SUDO_CACHE" -eq 1 ]] && echo enabled || echo secure-disabled)"
}

zenity_password() {
  local title=$1
  local text=$2
  if ! have_zenity_gui; then
    return 2
  fi
  # Use --entry --hide-text so Enter in the focused password field validates the dialog
  # consistently as "OK", while still showing our full command/context text.
  zenity_run --entry --hide-text --title="$title" --text="$text" \
    --ok-label="OK" --cancel-label="Cancel" \
    --width=780 --height=620
}

notify_dry_run() {
  local text text="$(zenity_body "DRY-RUN" "$SUI_TARGET" "$@")"
  if have_zenity_gui; then
    zenity_run --info --title="sui — dry-run" --text="$text" --width=720 --height=480
  else
    printf '%s\n' "$text"
  fi
}

# ---------------------------------------------------------------------------
# Local execution paths
# ---------------------------------------------------------------------------
run_local_as_root() {
  # Already root — no elevation, no password. Still log for accountability.
  sui_audit "invoke"
  exec "$@"
}

run_local_pkexec() {
  if ! command -v pkexec >/dev/null 2>&1; then
    printf '%s\n' "sui: pkexec not found (install polkit or use default zenity+sudo path)." >&2
    return 1
  fi
  sui_audit "invoke"
  exec pkexec -- "$@"
}

run_local_zenity_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    printf '%s\n' "sui: sudo not found." >&2
    return 1
  fi
  local body title zpwd summary attempt
  summary="$(cmd_repr "$@")"
  title="sui — local sudo [${SUI_INVOKER}] — ${summary}"
  body="$(zenity_body "LOCAL-ZENITY" "local" "$@")"
  for ((attempt=1; attempt<=AUTH_MAX_ATTEMPTS; attempt++)); do
    zpwd="$(zenity_password "${title} [${attempt}/${AUTH_MAX_ATTEMPTS}]" "$body")"
    case $? in
      0) ;;
      2)
        # No GUI zenity available: prefer pkexec locally, then TTY password fallback.
        if command -v pkexec >/dev/null 2>&1; then
          run_local_pkexec "$@"
          return $?
        fi
        zpwd="$(tty_password_prompt "sui: sudo password for ${SUI_INVOKER}: ")" || {
          printf '%s\n' "sui: no GUI available and no interactive TTY password input possible." >&2
          sui_audit "cancel"
          return "$EXIT_CANCELLED"
        }
        ;;
      *)
        printf '%s\n' "sui: authentication cancelled by user (local)." >&2
        sui_audit "cancel"
        return "$EXIT_CANCELLED"
        ;;
    esac
    PASS="$zpwd"
    unset -v zpwd
    if sudo_validate_local_password "$PASS"; then
      unset -v PASS
      sui_audit "invoke"
      sudo_execute_local_with_ticket "$@"
      return $?
    fi
    unset -v PASS
    if [[ "$attempt" -lt "$AUTH_MAX_ATTEMPTS" ]]; then
      notify_auth_failure "Authentication failed (${attempt}/${AUTH_MAX_ATTEMPTS}). Please try again."
    fi
  done
  notify_auth_failure "Authentication failed ${AUTH_MAX_ATTEMPTS} times. Aborting."
  printf '%s\n' "sui: local sudo aborted after ${AUTH_MAX_ATTEMPTS} failed attempts." >&2
  sui_audit "cancel"
  return "$EXIT_AUTH_FAILED"
}

# ---------------------------------------------------------------------------
# Remote execution — robust argv tunnel (never use "$*" over SSH)
#
# Protocol over SSH stdin for non-root→sudo case:
#   Line 1: sudo password (consumed by sudo -S)
#   Rest:   bash script executed as root
#
# Why bash -s: arbitrary argv is re-materialized with %q on the remote shell,
# avoiding one giant quoted string and injection via metacharacters.
# ---------------------------------------------------------------------------
run_remote_root_direct() {
  local target=$1
  shift
  sui_audit "invoke"
  {
    printf 'set -euo pipefail\n'
    printf 'exec'
    local a
    for a in "$@"; do
      printf ' %q' "$a"
    done
    printf '\n'
  } | ssh -o 'BatchMode=no' -- "$target" 'bash -s'
}

run_remote_zenity_sudo() {
  local target=$1
  shift
  # Remote machine must provide sudo(8); we cannot probe it without a session. A missing remote sudo
  # surfaces as a non-zero ssh exit code.
  local body title zpwd summary attempt
  summary="$(cmd_repr "$@")"
  title="sui — remote sudo [@${target}] — ${summary}"
  body="$(zenity_body "REMOTE-ZENITY" "$target" "$@")"
  for ((attempt=1; attempt<=AUTH_MAX_ATTEMPTS; attempt++)); do
    zpwd="$(zenity_password "${title} [${attempt}/${AUTH_MAX_ATTEMPTS}]" "$body")"
    case $? in
      0) ;;
      2)
        zpwd="$(tty_password_prompt "sui: remote sudo password for @${target}: ")" || {
          printf '%s\n' "sui: no GUI available and no interactive TTY password input possible." >&2
          sui_audit "cancel"
          return "$EXIT_CANCELLED"
        }
        ;;
      *)
        printf '%s\n' "sui: authentication cancelled by user (remote @${target})." >&2
        sui_audit "cancel"
        return "$EXIT_CANCELLED"
        ;;
    esac
    PASS="$zpwd"
    unset -v zpwd
    if sudo_validate_remote_password "$target" "$PASS"; then
      unset -v PASS
      sui_audit "invoke"
      sudo_execute_remote_with_ticket "$target" "$@"
      return $?
    fi
    unset -v PASS
    if [[ "$attempt" -lt "$AUTH_MAX_ATTEMPTS" ]]; then
      notify_auth_failure "Remote authentication failed (${attempt}/${AUTH_MAX_ATTEMPTS}) for @${target}. Please try again."
    fi
  done
  notify_auth_failure "Remote authentication failed ${AUTH_MAX_ATTEMPTS} times for @${target}. Aborting."
  printf '%s\n' "sui: remote sudo aborted for @${target} after ${AUTH_MAX_ATTEMPTS} failed attempts." >&2
  sui_audit "cancel"
  return "$EXIT_AUTH_FAILED"
}

# ---------------------------------------------------------------------------
# Parse argv: [options] [@host] command ...
# ---------------------------------------------------------------------------
parse_args() {
  USE_POLKIT=0
  DRY_RUN=0
  DOCTOR_MODE=0
  SUDO_CACHE=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --polkit)
        USE_POLKIT=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --doctor)
        DOCTOR_MODE=1
        shift
        ;;
      --sudo-cache)
        SUDO_CACHE=1
        shift
        ;;
      --no-sudo-cache)
        SUDO_CACHE=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ "$DOCTOR_MODE" -eq 1 && $# -lt 1 ]]; then
    return 0
  fi

  if [[ $# -lt 1 ]]; then
    printf '%s\n' "sui: missing command (see sui --help)." >&2
    exit 2
  fi

  SUI_TARGET="local"
  SUI_SCOPE="local"
  if [[ "$1" == @* ]]; then
    SUI_TARGET="${1#@}"
    SUI_SCOPE="remote"
    shift
    if [[ $# -lt 1 ]]; then
      printf '%s\n' "sui: missing command after @${SUI_TARGET}." >&2
      exit 2
    fi
  fi

  # Remaining positional parameters are exactly what we must exec (preserve argv).
  SUI_CMD=("$@")
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  SUI_INVOKER="$(id -un)"
  SUI_UID="$(id -u)"

  if [[ "${1:-}" == "doctor" ]]; then
    print_doctor
    exit 0
  fi

  parse_args "$@"

  if [[ "${DOCTOR_MODE:-0}" -eq 1 ]]; then
    print_doctor
    exit 0
  fi

  # Parsed command + argv (flags and @target already stripped).
  SUI_CMD_REPR="$(cmd_repr "${SUI_CMD[@]}")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    sui_audit "dry-run"
    notify_dry_run "${SUI_CMD[@]}"
    exit 0
  fi

  if [[ "$SUI_SCOPE" == "local" ]]; then
    if [[ "$SUI_UID" -eq 0 ]]; then
      run_local_as_root "${SUI_CMD[@]}"
    fi
    if [[ "$USE_POLKIT" -eq 1 ]]; then
      run_local_pkexec "${SUI_CMD[@]}"
    fi
    run_local_zenity_sudo "${SUI_CMD[@]}"
    exit $?
  fi

  # Remote branch
  if [[ "$USE_POLKIT" -eq 1 ]]; then
    printf '%s\n' "sui: note: --polkit applies to local elevation only; remote still uses SSH + zenity + sudo." >&2
  fi

  local ruid
  ruid="$(ssh -o 'BatchMode=no' -- "$SUI_TARGET" 'id -u' 2>/dev/null)" || {
    printf '%s\n' "sui: cannot reach ssh target '${SUI_TARGET}' (ssh failed)." >&2
    sui_audit "error"
    exit 1
  }

  if [[ "$ruid" == "0" ]]; then
    run_remote_root_direct "$SUI_TARGET" "${SUI_CMD[@]}"
  else
    run_remote_zenity_sudo "$SUI_TARGET" "${SUI_CMD[@]}"
  fi
  exit $?
}

main "$@"
