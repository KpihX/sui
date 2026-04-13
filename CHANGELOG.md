# Changelog

All notable changes to `sui` are documented in this file.

The format is inspired by Keep a Changelog and this project follows Semantic Versioning.

## [3.1.2] - 2026-04-13

### Added
- `--reason` (and `--reason=...`) option to attach a human rationale displayed in the privilege dialog.
- Audit trail now records the provided rationale (`reason=...`) for traceability.
- `tests/live-smoke.sh` interactive smoke suite covering rich local/remote privileged scenarios.

### Changed
- Dialog context block now shows `Rationale:` prominently before password entry.

### Fixed
- Local sudo flow now executes in the same `sudo -S` invocation (robust with `sudo-rs`).
- Remote sudo flow now executes in the same `sudo -S` invocation (avoids ticket loss across SSH calls).
- Filtered remote auth noise (`Sorry, try again`) from shell while preserving non-auth stderr.
- Fixed local `--polkit` path (`pkexec "$@"` instead of executing literal `--`).

## [3.1.1] - 2026-04-13

### Added
- `--json` output mode for doctor diagnostics (`sui --doctor --json` and `sui doctor --json`).
- Machine-readable runtime fields (tool availability, GUI/TTY capability, cache mode, fallback order).

### Changed
- `doctor` now routes through one dispatcher that supports both text and JSON outputs.

## [3.1.0] - 2026-04-13

### Added
- Distinct exit codes for authentication outcomes:
  - `130` for user cancellation.
  - `77` for max-attempts authentication failure.
- Attempt counter in dialog titles (`[1/3]`, `[2/3]`, ...).
- Configurable sudo cache policy:
  - `--no-sudo-cache` (secure default).
  - `--sudo-cache` (allow timestamp reuse).
- Controlled retry loop with explicit shell + popup feedback on failures.

### Changed
- Strengthened local/remote auth UX and terminal feedback consistency.

## [3.0.6] - 2026-04-13

### Fixed
- Password prompt UX: Enter reliably validates the dialog.
- Forced strict password validation path (`sudo -k`) to prevent false-positive auth from cached sudo tickets.

## [3.0.5] - 2026-04-13

### Added
- `doctor` / `--doctor` runtime diagnostics.
- Auto-fallback when Zenity/GUI is unavailable:
  - local: `pkexec`, then TTY prompt.
  - remote: TTY prompt.

### Changed
- Zenity calls use `GSK_RENDERER=cairo` and stderr suppression by default.

## [3.0.4] - 2026-04-13

### Fixed
- Removed problematic separator characters that broke Zenity markup parsing.

## [3.0.3] - 2026-04-13

### Changed
- Command line is always shown prominently in the dialog body.

## [3.0.1] - 2026-04-13

### Fixed
- Switched to Zenity forms mode to keep full command details visible on Zenity 4.x.

## [3.0.0] - 2026-04-13

### Added
- First public standalone release of `sui`:
  - unified local/remote privilege flow,
  - command preview in GUI,
  - audit hooks,
  - `--polkit` and `--dry-run`.
