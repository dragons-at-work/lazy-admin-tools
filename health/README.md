# health

Cron-friendly health checks for OpenBSD and Debian servers. No agent,
no dashboard, no database - just a script that mails a report.

## Status

- Stable and in daily production use
- `openbsd-health.sh` tested on OpenBSD 7.8
- `debian-health.sh` tested on Debian 12/13
- Configuration is inline using plain shell variables

## Installation

Installed below `/usr/local/libexec`:

```text
/usr/local/libexec/lazy-admin-tools/health/
```

No symlinks are created - health checks are unattended helpers
normally invoked by cron rather than interactive administrator
commands.

To install by hand instead of via the repository's `install.sh`:

```sh
doas mkdir -p /usr/local/libexec/lazy-admin-tools/health
doas cp health/openbsd-health.sh /usr/local/libexec/lazy-admin-tools/health/
doas chmod +x /usr/local/libexec/lazy-admin-tools/health/openbsd-health.sh
```

Use the analogous path for `debian-health.sh` on Debian hosts, using
`sudo` instead of `doas`.

**Before first use on any host**, create the host-local baseline
config - the scripts refuse to run without it rather than falling
back to example values that don't match your actual server:

```sh
doas mkdir -p /usr/local/etc/lazy-admin-tools
doas tee /usr/local/etc/lazy-admin-tools/health.conf <<'EOF'
MAILTO="adm-yourhost@example.org"
EXPECTED_SERVICES="httpd relayd smtpd sshd"
EXPECTED_PORTS="22 80 443"
EOF
```

Determine the real values first with `rcctl ls started` / `netstat -an
-f inet` (OpenBSD) or `systemctl list-units --type=service
--state=running` / `ss -tln` (Debian). This file is host-specific
configuration, not part of this repository - `install.sh` never
creates, edits, or deletes it, so it survives every reinstall.

## Usage

Create the host-local baseline first (see Installation above) - the
scripts refuse to run without
`/usr/local/etc/lazy-admin-tools/health.conf`:

```text
MAILTO="adm-myhost@example.com"
EXPECTED_SERVICES="httpd relayd smtpd sshd"
EXPECTED_PORTS="22 80 443"
```

The disk/service/port/update check toggles (`CHECK_DISK`,
`DISK_WARN_PCT`, etc.) remain inside the script itself - those are
behavior, not host identity, and are fine to change via a normal pull
request or by editing the installed copy the same way you'd patch any
other tool here.

Then add it to `/etc/crontab` to run daily:

```text
0 6 * * * root /usr/local/libexec/lazy-admin-tools/health/openbsd-health.sh
```

The OpenBSD script requires root (`rcctl`, `syspatch`) and mails an
error report and exits if run without it. Run it via `doas`/`sudo` when
testing manually, or via cron as root for regular operation.

### Service semantics

`EXPECTED_SERVICES` must be the complete list of services expected to be
running, not just the ones you specifically want to watch. Any running
service not listed there triggers a WARN.

Before first use, determine the actual baseline:

```sh
rcctl ls started
```

```sh
systemctl list-units --type=service --state=running --no-legend
```

Then build `EXPECTED_SERVICES` from that output.

### Status levels

- **ERROR** - act immediately: a service is not running, an expected
  port is not listening, or disk usage is above `DISK_ERROR_PCT`.
- **WARN** - check soon: an unexpected service or port is running,
  disk usage is above `DISK_WARN_PCT`, or patches/updates are pending.
- **OK** - nothing to do.

The mail subject reflects the highest level found (`[ERROR]`, `[WARN]`,
`[OK]`).

### Port semantics

`EXPECTED_PORTS` is not a complete whitelist of every port allowed to
listen. It is a list of ports that must be listening somewhere, local or
public.

The check distinguishes two binding scopes:

- **Public**: bound to `*`, a wildcard, or a real IP - reachable from
  outside.
- **Local**: bound to `127.0.0.1`, `::1`, or a loopback interface -
  reachable only locally.

Consequences:

- A missing expected port, neither public nor local, is an **ERROR**.
- Additional **local** ports do not trigger a warning.
- Additional **public** ports not listed in `EXPECTED_PORTS` trigger a
  **WARN**.

If a complete whitelist of all local ports is required, it must be
implemented separately; that is intentionally not the health tool's
scope.

## Development and Testing

Health scripts depend only on the relevant platform tools (`rcctl`,
`syspatch`, `netstat` on OpenBSD; `systemctl`, `ss`, `apt` on Debian).

To test manually:

```sh
doas sh health/openbsd-health.sh
```

```sh
sudo bash health/debian-health.sh
```

-- lazy-admin-tools - dragons@work
