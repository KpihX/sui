# sui — Sudo User Interface

Unified graphical gateway for **local** and **remote** privileged commands on Linux desktops (Zenity + `sudo` / `pkexec`, SSH for remote hosts). Preserves full `argv` (no fragile `"$*`" over SSH).

## Features

- Single Zenity dialog: full command details + password (local default path).
- `--polkit` for desktop users who prefer Polkit (`pkexec`) locally.
- `--dry-run` to preview without elevation.
- Optional `SUI_LOG=1` for `${XDG_STATE_HOME}/sui/audit.log`.
- Syslog audit via `logger -p authpriv.notice` (often merged into `/var/log/auth.log` on traditional setups).

## Requirements

- Bash, `sudo`, `zenity`, `ssh` (remote), optional `pkexec` (`--polkit`).
- A graphical session (`DISPLAY` or `WAYLAND_DISPLAY`) for password prompts.

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
```

See `sui --help` or the header of `sui.sh`.

## Repositories

- **GitHub:** `git@github.com:KpihX/sui.git`
- **GitLab:** `git@gitlab.com:kpihx/sui.git`

### Remotes when embedded in `KpihX/sh`

The parent `sh` Makefile runs `git push` on each submodule using remotes named **`github`** and **`gitlab`**. After a plain clone of only `sui`, the default remote is often `origin` pointing at GitHub. Align with:

```bash
git remote rename origin github
git remote add gitlab git@gitlab.com:kpihx/sui.git
```

Then `make push` from the `sui` repo root pushes both hosts.

## Troubleshooting

### Password dialog does not show the command (Zenity 4.x)

Older examples used `zenity --password --text=…`. On Zenity **4.x**, that mode often **drops `--text`** and only shows the generic “Type your password” line, so you cannot see e.g. `apt update` in the dialog.

`sui` **v3.0.1+** uses `zenity --forms` with `--text` (full briefing) and `--add-password` so the command stays visible.

### `MESA-INTEL` lines in the terminal when the dialog opens

Launching the GTK/Zenity stack may print **harmless** Intel Vulkan driver warnings to **stderr**. They are **not** from `apt` or `sudo`. After you confirm the dialog, normal command output should follow.

## License

Private / personal tooling — see repository owner policy.
