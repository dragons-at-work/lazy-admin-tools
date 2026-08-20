# Mailserver tools

The `mail/` tools provide a small declarative administration layer for a
multi-domain mail server based on OpenSMTPD and Dovecot.

## Status

Version 1 is currently developed and tested on:

-   Debian 13
-   Dovecot 2.4.x
-   OpenSMTPD 7.6 portable

Other operating systems and releases, including OpenBSD, have not yet
been tested and are not currently claimed as supported.

The tools deliberately keep the host-specific OpenSMTPD configuration
outside their source of truth. They manage hosted mail domains, domain
aliases, mailboxes, mail aliases, generated OpenSMTPD tables, and
Dovecot credentials.

## Tools

-   `mailserver-init.sh` --- initialize `/etc/mailserver`
-   `mail-domain-add.sh` / `mail-domain-del.sh` --- manage canonical
    mail domains
-   `mail-domain-alias-add.sh` / `mail-domain-alias-del.sh` --- manage
    alias domains
-   `mail-mailbox-add.sh` / `mail-mailbox-del.sh` --- manage mailboxes
    and credentials
-   `mail-alias-add.sh` / `mail-alias-del.sh` --- manage mail aliases
-   `mailserver-validate.sh` --- validate the declarative store
-   `mailserver-generate.sh` --- generate OpenSMTPD/Dovecot artifacts
-   `mailserver-validate-generated.sh` --- validate generated artifacts
    with the target programs
-   `mailserver-deploy.sh` --- build, validate, promote, deploy, verify,
    and roll back generations

All administration scripts are intended to run as root.

## Documentation

-   [Architecture](docs/architecture.md)
-   [Configuration](docs/configuration.md)
-   [Installation](docs/installation.md)
-   [Operations](docs/operations.md)

## Safety model

The files below `/etc/mailserver/` are the source of truth. Generated
files are derived artifacts.

Deletion commands are conservative:

-   a mailbox cannot normally be removed while aliases still point to
    it;
-   a domain cannot normally be removed while mailboxes, aliases, or
    alias domains depend on it;
-   `--force` may deliberately leave an inconsistent store, which
    `mailserver-validate.sh` will report;
-   removing a mailbox does **not** delete its Maildir or stored mail.

`mailserver-deploy.sh` uses complete generations and an atomic symlink
promotion. It checks that the existing production OpenSMTPD and Dovecot
configuration is healthy before changing production state and rolls back
managed state if a later deployment step fails.

## License

See the repository's root `LICENSE` file.
