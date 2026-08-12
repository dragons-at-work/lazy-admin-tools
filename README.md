# lazy-admin-tools

Small, readable health-check scripts for OpenBSD and Debian servers.

lazy-admin-tools provides cron-friendly health checks that report
disk usage, service status, listening ports, and pending patches by
mail - no daemon, no database, no framework.

**Status:** Stable · **Platforms:** OpenBSD, Debian · **License:** ISC

❤️ [Contribute and support our work](https://dragons-at-work.co.uk/en/support/)

## What is lazy-admin-tools?

lazy-admin-tools is a small collection of shell scripts that check
the operational state of a server - disk space, expected services,
expected ports, pending OpenBSD patches or Debian updates - and
mail a single report. Each check compares the actual state of the
host against a small, explicit expectation defined in a handful of
variables at the top of the script.

There is one script per platform (`openbsd-health.sh`,
`debian-health.sh`), each self-contained, POSIX-friendly where
possible, and meant to be copied, adapted, and run from cron.

## What problem does it solve?

A server rarely fails loudly. Disk fills up slowly, a service dies
quietly, a patch sits unapplied for weeks, or a port starts
listening that nobody intended. Full monitoring stacks solve this,
but they are often too much for a handful of small servers - a
daemon, a database, a web UI, another thing to maintain.

lazy-admin-tools is the smallest useful step above "nothing": a
daily cron job that answers "is anything different from what I
expect?" and mails the result. It scales down to a single VPS and
up to a handful of hosts without any additional infrastructure.

## Status

- Stable, in daily production use
- Two scripts: `openbsd-health.sh` (tested on OpenBSD 7.8),
  `debian-health.sh` (tested on Debian 12/13)
- Configuration is inline (plain shell variables), no external
  config file
- Known limitation: `EXPECTED_PORTS` is not a full port whitelist,
  see [Usage](#usage)

## Repository structure

```text
lazy-admin-tools/
├── README.md
├── LICENSE
└── health/
    ├── openbsd-health.sh
    └── debian-health.sh
```

Grouped by function first, platform second - so future tools
(backups, mail, certs, ...) get their own top-level folder instead
of duplicating per platform.

## Installation

```sh
doas mkdir -p /usr/local/libexec/lazy-admin-tools/health
doas cp health/openbsd-health.sh /usr/local/libexec/lazy-admin-tools/health/
doas chmod +x /usr/local/libexec/lazy-admin-tools/health/openbsd-health.sh
```

(analogous for `health/debian-health.sh` on Debian hosts, using
`sudo` instead of `doas`)

`/usr/local/libexec` rather than `/usr/local/bin`, because this is a
cron-driven script, not an interactive command. It is meant to run
as root (via cron or `doas`/`sudo`), not to be called directly by a
regular user - the path is intentionally outside what a login shell
normally has in `PATH`.

## Usage

Edit the variables at the top of the script:

```sh
MAILTO="adm-myhost@example.com"

CHECK_DISK=yes
DISK_WARN_PCT=80
DISK_ERROR_PCT=95

CHECK_SERVICES=yes
EXPECTED_SERVICES="httpd relayd smtpd sshd"

CHECK_PORTS=yes
EXPECTED_PORTS="22 80 443"
```

Then add it to `/etc/crontab` to run daily:

```
0 6 * * * root /usr/local/libexec/lazy-admin-tools/health/openbsd-health.sh
```

The OpenBSD script requires root (`rcctl`, `syspatch`) and mails an
error report and exits if run without it. Run it via `doas`/`sudo`
when testing manually, or via cron as root for regular operation.

### Status levels

- **ERROR** - act immediately: a service is not running, an
  expected port is not listening, disk usage is above
  `DISK_ERROR_PCT`.
- **WARN** - check soon: an unexpected service or port is running,
  disk usage is above `DISK_WARN_PCT`, patches or updates are
  pending.
- **OK** - nothing to do.

The mail subject reflects the highest level found (`[ERROR]`,
`[WARN]`, `[OK]`).

### Port semantics

`EXPECTED_PORTS` is not a complete whitelist of every port allowed
to listen - it is a list of ports that must be listening
*somewhere*, local or public.

The check distinguishes two binding scopes:

- **Public**: bound to `*`, a wildcard, or a real IP - reachable
  from outside.
- **Local**: bound to `127.0.0.1` / `::1` / a loopback interface -
  reachable only locally.

Consequences:

- A missing expected port (neither public nor local) is an
  **ERROR**.
- Additional **local** ports (e.g. internal API processes on
  `127.0.0.1`) do **not** trigger a warning - these are normal
  internal connections.
- Additional **public** ports not listed in `EXPECTED_PORTS`
  trigger a **WARN**.

If a complete whitelist of all local ports is required, this needs
to be added separately - that is intentionally not this tool's
scope.

## Documentation

This README is the documentation. The scripts are short and
commented; read them directly for details.

## Development and Testing

No build step, no dependencies beyond the platform's base tools
(`rcctl`, `syspatch`, `netstat` on OpenBSD; `systemctl`, `ss`,
`apt` on Debian).

To test a script without waiting for cron:

```sh
doas sh health/openbsd-health.sh
```

```sh
sudo bash health/debian-health.sh
```

Check the resulting mail for correct status levels and port
classification.

## Contributing

Bug reports, tests on other platforms, and feedback are welcome.

The primary development repository is on Forgejo:
[Development repository](https://smida.dragons-at-work.de/DAW/lazy-admin-tools)

The GitHub repository is a public mirror for discoverability.
Please submit issues and contributions on the primary repository.

## Open Knowledge Needs People

We develop ideas, share knowledge, and build open-source software
and tools. Projects like this one don't grow by themselves - they
live because people ask questions, experiment, share knowledge,
find bugs, and help make things better.

You can contribute in different ways:

- report bugs
- review code
- test on other platforms
- improve documentation
- translate content
- or, if you like, support us financially

Every contribution helps us develop open knowledge and open-source
software further in the long run.

[Contribute and support our work →](https://dragons-at-work.co.uk/en/support/)

## License

This project is licensed under the ISC License.
See [LICENSE](LICENSE).
