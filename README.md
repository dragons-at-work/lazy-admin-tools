# lazy-admin-tools

Small, readable Unix administration tools.

lazy-admin-tools provides focused administration helpers for small
servers - no framework, no database, no container stack, and no
unnecessary infrastructure.

The repository currently contains cron-friendly server health checks and
a declarative multi-domain mail administration toolset.

**Status:** Active · **Platforms:** see individual tool sections ·
**License:** ISC

❤️ [Contribute and support our
work](https://dragons-at-work.co.uk/en/support/)

## What is lazy-admin-tools?

lazy-admin-tools is a collection of small shell-based Unix
administration tools. Each tool focuses on a concrete operational task
and is designed to remain readable, inspectable, and usable without
introducing a larger administration framework.

Tools are grouped by function first and, where necessary, by platform
second.

The repository currently contains:

-   `health/` - cron-friendly health checks for OpenBSD and Debian
    servers
-   `mail/` - declarative multi-domain mail administration for OpenSMTPD
    and Dovecot

## What problem does it solve?

Small servers often need reliable administration without the operational
cost of another platform.

Disk usage, service state, listening ports, pending patches, mail
domains, mailboxes, aliases, and deployment safety are all real
administration problems. Solving each of them with a large management or
monitoring stack can mean running more software than the actual task
justifies.

lazy-admin-tools provides deliberately small tools for these jobs: plain
configuration, explicit behavior, readable scripts, and no background
infrastructure unless the underlying service itself requires it.

## Status

### Health checks

-   Stable and in daily production use
-   `health/openbsd-health.sh` tested on OpenBSD 7.8
-   `health/debian-health.sh` tested on Debian 12/13
-   Configuration is inline using plain shell variables
-   `EXPECTED_PORTS` is not a complete port whitelist; see [Health
    checks](#health-checks)

### Mail administration

-   Functional v1 toolset
-   Currently tested on Debian 13
-   Tested with Dovecot 2.4.x and OpenSMTPD 7.6 portable
-   OpenBSD and other platforms have not yet been tested and are not
    currently claimed as supported
-   Uses a declarative source of truth under `/etc/mailserver`
-   Generates and validates OpenSMTPD/Dovecot artifacts
-   Deploys complete generations with rollback support

See [`mail/README.md`](mail/README.md) for the mail toolset's detailed
status, architecture, configuration, installation, and operations
documentation.

## Repository structure

``` text
lazy-admin-tools/
├── README.md
├── LICENSE
├── health/
│   ├── openbsd-health.sh
│   └── debian-health.sh
└── mail/
    ├── README.md
    ├── mailserver-init.sh
    ├── mail-domain-add.sh
    ├── mail-domain-del.sh
    ├── mail-domain-alias-add.sh
    ├── mail-domain-alias-del.sh
    ├── mail-mailbox-add.sh
    ├── mail-mailbox-del.sh
    ├── mail-alias-add.sh
    ├── mail-alias-del.sh
    ├── mailserver-generate.sh
    ├── mailserver-validate.sh
    ├── mailserver-validate-generated.sh
    ├── mailserver-deploy.sh
    └── docs/
        ├── architecture.md
        ├── configuration.md
        ├── installation.md
        └── operations.md
```

The repository is grouped by function first, platform second.
Platform-specific variants belong together below their function rather
than duplicating the repository structure per operating system.

## Installation

Installation depends on the tool family.

### Health checks

Install cron-driven health helpers below `/usr/local/libexec`:

``` sh
doas mkdir -p /usr/local/libexec/lazy-admin-tools/health
doas cp health/openbsd-health.sh /usr/local/libexec/lazy-admin-tools/health/
doas chmod +x /usr/local/libexec/lazy-admin-tools/health/openbsd-health.sh
```

Use the analogous path for `health/debian-health.sh` on Debian hosts,
using `sudo` instead of `doas`.

`/usr/local/libexec` is intentional: health checks are unattended
helpers normally invoked by cron rather than interactive administrator
commands.

### Mail administration

Keep the mail toolset together below:

``` text
/usr/local/lib/lazy-admin-tools/mail/
```

Administrator-facing commands can additionally be exposed through
`/usr/local/sbin` using symlinks.

The mail tools have additional OpenSMTPD/Dovecot prerequisites and
deployment requirements. Follow
[`mail/docs/installation.md`](mail/docs/installation.md) before using
them on a server.

## Usage

### Health checks

Edit the variables at the top of the appropriate script:

``` sh
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

``` text
0 6 * * * root /usr/local/libexec/lazy-admin-tools/health/openbsd-health.sh
```

The OpenBSD script requires root (`rcctl`, `syspatch`) and mails an
error report and exits if run without it. Run it via `doas`/`sudo` when
testing manually, or via cron as root for regular operation.

#### Service semantics

`EXPECTED_SERVICES` must be the complete list of services expected to be
running, not just the ones you specifically want to watch. Any running
service not listed there triggers a WARN.

Before first use, determine the actual baseline:

``` sh
rcctl ls started
```

``` sh
systemctl list-units --type=service --state=running --no-legend
```

Then build `EXPECTED_SERVICES` from that output.

#### Status levels

-   **ERROR** - act immediately: a service is not running, an expected
    port is not listening, or disk usage is above `DISK_ERROR_PCT`.
-   **WARN** - check soon: an unexpected service or port is running,
    disk usage is above `DISK_WARN_PCT`, or patches/updates are pending.
-   **OK** - nothing to do.

The mail subject reflects the highest level found (`[ERROR]`, `[WARN]`,
`[OK]`).

#### Port semantics

`EXPECTED_PORTS` is not a complete whitelist of every port allowed to
listen. It is a list of ports that must be listening somewhere, local or
public.

The check distinguishes two binding scopes:

-   **Public**: bound to `*`, a wildcard, or a real IP - reachable from
    outside.
-   **Local**: bound to `127.0.0.1`, `::1`, or a loopback interface -
    reachable only locally.

Consequences:

-   A missing expected port, neither public nor local, is an **ERROR**.
-   Additional **local** ports do not trigger a warning.
-   Additional **public** ports not listed in `EXPECTED_PORTS` trigger a
    **WARN**.

If a complete whitelist of all local ports is required, it must be
implemented separately; that is intentionally not the health tool's
scope.

### Mail administration

The mail toolset manages canonical domains, alias domains, mailboxes,
aliases, generation, validation, and deployment.

Typical administration commands include:

``` sh
sudo mail-domain-add example.org
sudo mail-mailbox-add user@example.org
sudo mail-alias-add contact@example.org user@example.org
sudo mailserver-validate
sudo mailserver-deploy
```

Do not treat these examples as a substitute for initial setup. Read
[`mail/README.md`](mail/README.md) and
[`mail/docs/installation.md`](mail/docs/installation.md) before the
first deployment.

## Documentation

Health-check usage is documented in this README and in the scripts
themselves.

The mail administration toolset has separate documentation because its
configuration, validation, deployment, and rollback model is
substantially larger:

-   [`mail/README.md`](mail/README.md)
-   [`mail/docs/architecture.md`](mail/docs/architecture.md)
-   [`mail/docs/configuration.md`](mail/docs/configuration.md)
-   [`mail/docs/installation.md`](mail/docs/installation.md)
-   [`mail/docs/operations.md`](mail/docs/operations.md)

## Development and Testing

There is no build system or framework.

Health scripts depend only on the relevant platform tools (`rcctl`,
`syspatch`, `netstat` on OpenBSD; `systemctl`, `ss`, `apt` on Debian).

To test health checks manually:

``` sh
doas sh health/openbsd-health.sh
```

``` sh
sudo bash health/debian-health.sh
```

The mail toolset has been tested end-to-end on Debian 13 with Dovecot
2.4.x and OpenSMTPD 7.6 portable. Its validation and deployment tools
check the declarative store, generated configuration, current production
configuration, service restart, and live Dovecot user resolution.

OpenBSD support for the mail toolset has not yet been tested.

## Contributing

Bug reports, tests on other platforms, and feedback are welcome.

The primary development repository is on Forgejo: [Development
repository](https://smida.dragons-at-work.de/DAW/lazy-admin-tools)

The GitHub repository is a public mirror for discoverability. GitHub
Issues are also accepted for external bug reports, questions,
suggestions, and feedback.

## Open Knowledge Needs People

We develop ideas, share knowledge, and build open-source software and
tools. Projects like this one don't grow by themselves - they live
because people ask questions, experiment, share knowledge, find bugs,
and help make things better.

You can contribute in different ways:

-   report bugs
-   review code
-   test on other platforms
-   improve documentation
-   translate content
-   or, if you like, support us financially

Every contribution helps us develop open knowledge and open-source
software further in the long run.

[Contribute and support our work
→](https://dragons-at-work.co.uk/en/support/)

## License

This project is licensed under the ISC License. See [LICENSE](LICENSE).
