#!/usr/bin/env bash
set -u

# Live smoke test for sui (interactive by design).
# It runs both dry-run and real privileged flows with richer commands than `id -u`.

SUI_BIN="${SUI_BIN:-/usr/local/bin/sui}"
PASS_POLICY="${PASS_POLICY:---no-sudo-cache}"

if [[ ! -x "$SUI_BIN" ]]; then
  echo "sui smoke: binary not found or not executable at $SUI_BIN" >&2
  exit 2
fi

run_case() {
  local name=$1
  shift
  echo ""
  echo "===== $name ====="
  echo "+ $*"
  "$@"
  local ec=$?
  echo "----- exit=$ec ($name)"
  return 0
}

echo "sui smoke starting..."
echo "SUI_BIN=$SUI_BIN"
echo "PASS_POLICY=$PASS_POLICY"

# Discovery / doctor
run_case "doctor-text" "$SUI_BIN" --doctor
run_case "doctor-json" "$SUI_BIN" --doctor --json

# Dry-run rich local/remote command lines (complex argv + shell syntax)
run_case "dryrun-local-rich" \
  "$SUI_BIN" --dry-run --reason "Preview local maintenance command" \
  bash -lc 'set -e; id -u; ls -ld /root; command -v apt >/dev/null'

run_case "dryrun-remote-kpihx-labs-rich" \
  "$SUI_BIN" --dry-run --reason "Preview remote maintenance command" \
  @kpihx-labs bash -lc 'set -e; id -u; ls -ld /root; command -v apt >/dev/null'

run_case "dryrun-remote-docker-host-rich" \
  "$SUI_BIN" --dry-run --reason "Preview remote docker host checks" \
  @docker-host bash -lc 'set -e; id -u; ls -ld /root; command -v systemctl >/dev/null'

# Real local privileged checks (require root)
run_case "local-rich-root-check" \
  "$SUI_BIN" "$PASS_POLICY" --reason "Validate local privileged filesystem + apt readiness" \
  bash -lc 'set -e; whoami; id -u; ls -ld /root; test -r /etc/shadow; apt-cache policy >/dev/null'

run_case "local-apt-update" \
  "$SUI_BIN" "$PASS_POLICY" --reason "Refresh local apt package metadata" \
  apt update

# Real remote privileged checks (require remote root via sudo)
run_case "remote-kpihx-labs-rich-root-check" \
  "$SUI_BIN" "$PASS_POLICY" --reason "Validate kpihx-labs root + apt readiness" \
  @kpihx-labs bash -lc 'set -e; whoami; id -u; ls -ld /root; test -r /etc/shadow; apt-cache policy >/dev/null'

run_case "remote-kpihx-labs-apt-update" \
  "$SUI_BIN" "$PASS_POLICY" --reason "Refresh kpihx-labs apt package metadata" \
  @kpihx-labs apt update

run_case "remote-docker-host-rich-root-check" \
  "$SUI_BIN" "$PASS_POLICY" --reason "Validate docker-host root + service tooling" \
  @docker-host bash -lc 'set -e; whoami; id -u; ls -ld /root; command -v docker >/dev/null; systemctl --version >/dev/null'

echo ""
echo "sui smoke completed."
