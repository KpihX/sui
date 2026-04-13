# sui — Sudo User Interface

Unified graphical gateway for **local** and **remote** privileged commands on Linux desktops (Zenity + `sudo` / `pkexec`, SSH for remote hosts). Preserves full `argv` (no fragile `"$*`" over SSH).

## Features

- Single Zenity dialog: **full argv always shown** in a high-visibility block (chevrons + spacing) plus password (`--forms` on Zenity 4.x).
- `--polkit` for desktop users who prefer Polkit (`pkexec`) locally.
- `--dry-run` to preview without elevation.
- `doctor` / `--doctor` runtime diagnostic mode (GUI/TTY/tools availability + fallback order).
- `--json` machine-readable output for `doctor` mode.
- `--sudo-cache` / `--no-sudo-cache` to control sudo timestamp behavior (default: secure no-cache).
- Optional `SUI_LOG=1` for `${XDG_STATE_HOME}/sui/audit.log`.
- Syslog audit via `logger -p authpriv.notice` (often merged into `/var/log/auth.log` on traditional setups).

## Requirements

- Bash, `sudo`, `zenity`, `ssh` (remote), optional `pkexec` (`--polkit`).
- A graphical session (`DISPLAY` or `WAYLAND_DISPLAY`) for password prompts.

### Install `zenity` (if missing)

- Ubuntu/Debian:
  ```bash
  sudo apt update && sudo apt install -y zenity
  ```
- Fedora:
  ```bash
  sudo dnf install -y zenity
  ```
- Arch:
  ```bash
  sudo pacman -S --needed zenity
  ```

## Install (recommended: `install(1)`)

Use **`install`** so permissions and ownership are set in one atomic, explicit step. Installing to `/usr/local/bin` requires **root** (use your normal elevation path, e.g. `sudo` once for the install only).

### From a clone of this repository

```bash
cd /path/to/sui
sudo install -o root -g root -m 0755 sui.sh /usr/local/bin/sui
```

Why this shape:

- **`-o root -g root`** — the installed binary is owned by root (expected for system-wide tools under `/usr/local`).
- **`-m 0755`** — owner read/write/execute; group and others read/execute (standard for public executables).
- **`install`** creates/overwrites the destination file in one shot; fewer mistakes than separate `cp` + `chmod` + `chown`.

### Optional: backup existing binary

If `/usr/local/bin/sui` already exists:

```bash
sudo install -b -o root -g root -m 0755 sui.sh /usr/local/bin/sui
```

`-b` creates a backup (e.g. `sui~`) before replacing.

### Verify

```bash
command -v sui
sui --help
```

## Usage (short)

```text
sui [options] [@ssh-host] <command> [args...]
sui doctor
sui --doctor --json
```

Cache mode examples:

```bash
# secure default (no sudo timestamp reuse)
sui --no-sudo-cache apt update

# allow sudo timestamp cache (fewer prompts)
sui --sudo-cache apt update
```

See `sui --help` or the header of `sui.sh`.

## Repositories

- **GitHub:** `git@github.com:KpihX/sui.git`
- **GitLab:** `git@gitlab.com:kpihx/sui.git`
- **Changelog:** see `CHANGELOG.md`.

### Remotes when embedded in `KpihX/sh`

The parent `sh` Makefile runs `git push` on each submodule using remotes named **`github`** and **`gitlab`**. After a plain clone of only `sui`, the default remote is often `origin` pointing at GitHub. Align with:

```bash
git remote rename origin github
git remote add gitlab git@gitlab.com:kpihx/sui.git
```

Then `make push` from the `sui` repo root pushes both hosts.

## CI and Release Discipline

This project is security/ops-sensitive, so keep release hygiene strict:

- CI (`.github/workflows/ci.yml`) runs:
  - `bash -n sui.sh`
  - `shellcheck sui.sh`
  - smoke checks: `./sui.sh --help` and `./sui.sh --doctor`
- SemVer policy:
  - **MAJOR**: breaking CLI/behavior changes.
  - **MINOR**: backward-compatible features.
  - **PATCH**: backward-compatible fixes/docs/internal reliability.
- Every versioned change must update:
  - `readonly SUI_VERSION` in `sui.sh`
  - `CHANGELOG.md` with a new top entry.
- Tag releases as `vX.Y.Z` after CI is green on `main`.

## Troubleshooting

### Password dialog does not show the command (Zenity 4.x)

Older examples used `zenity --password --text=…`. On Zenity **4.x**, that mode often **drops `--text`** and only shows the generic “Type your password” line, so you cannot see e.g. `apt update` in the dialog.

`sui` **v3.0.1+** uses `zenity --forms` with `--text` (full briefing) and `--add-password`. **v3.0.3+** keeps the exact command line always visible and visually emphasized in the dialog body (never concealed).

### What if `zenity` is absent or no GUI is available?

`sui` **v3.0.5+** falls back automatically:

- **Local:** try `pkexec` first, then interactive TTY password prompt for `sudo` if needed.
- **Remote:** interactive TTY password prompt, then SSH + remote `sudo -S`.

This keeps privilege elevation usable on headless/minimal systems.

### `MESA-INTEL` lines in the terminal when the dialog opens

Launching the GTK/Zenity stack may print **harmless** Intel Vulkan driver warnings to **stderr**. They are **not** from `apt` or `sudo`. After you confirm the dialog, normal command output should follow.

From **v3.0.5+**, `sui` forces `GSK_RENDERER=cairo` for Zenity and suppresses Zenity stderr by default.
To re-enable stderr for debugging:

```bash
SUI_ZENITY_STDERR=1 sui apt update
```

## Test Matrix

| Scenario | Expected password UX | Expected execution path |
|---|---|---|
| Zenity installed + GUI available (local) | Zenity forms dialog | `sudo -S -- <cmd>` |
| Zenity missing/no GUI + `pkexec` available (local) | Polkit native dialog | `pkexec -- <cmd>` |
| Zenity missing/no GUI + no `pkexec` + interactive TTY (local) | TTY hidden prompt | `sudo -S -- <cmd>` |
| Zenity missing/no GUI + no TTY (local) | Clear error | abort |
| Zenity installed + GUI available (remote) | Zenity forms dialog | `ssh ... 'sudo -S ... bash -s'` |
| Zenity missing/no GUI + interactive TTY (remote) | TTY hidden prompt | `ssh ... 'sudo -S ... bash -s'` |
| Zenity missing/no GUI + no TTY (remote) | Clear error | abort |

Quick checks:

```bash
sui doctor
sui --dry-run apt update
sui --dry-run @docker-host systemctl restart nginx
sui --doctor --json
```

Authentication retry behavior:

- After a wrong password, `sui` reopens the prompt (up to 3 attempts by default).
- This avoids the raw repeated `sudo: Authentication failed, try again.` spam in terminal.
- Popup title shows retry progress (`[1/3]`, `[2/3]`, ...).

Exit codes:

- `130` → authentication cancelled by user.
- `77`  → authentication failed after max attempts.

## License

Private / personal tooling — see repository owner policy.
