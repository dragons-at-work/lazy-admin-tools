# Mailserver configuration

## Directory layout

The declarative store is rooted at:

``` text
/etc/mailserver/
```

The initialized layout is conceptually:

``` text
/etc/mailserver/
├── domains
├── domain-aliases
├── config
├── domain-overrides
├── mailboxes
├── aliases
├── defaults
└── secrets/
    └── users
```

After generation/deployment, additional derived directories exist:

``` text
/etc/mailserver/
├── generated -> generations/<timestamp>/
├── generations/
└── backups/
```

`generated`, `generations`, and `backups` are derived/deployment state,
not the declarative source of truth.

## `domains`

One canonical mail domain per line.

``` text
# One canonical mail domain per line.
example.org
example.com
```

A canonical domain owns mailboxes and aliases.

A domain must not simultaneously be configured as an alias domain.

## `domain-aliases`

Format:

``` text
<alias-domain> <canonical-domain>
```

Example:

``` text
example.net example.org
```

Alias domains do not have their own mailbox definitions. The generator
mirrors the canonical domain's mailbox and alias recipient namespace
explicitly.

## `mailboxes`

One mailbox address per line:

``` text
user@example.org
sales@example.org
```

Mailbox addresses must belong to configured canonical domains.

The credential itself is stored separately in `secrets/users`.

## `secrets/users`

Format:

``` text
<address>:<password-hash>
```

The v1 credential representation is a raw SHA512-Crypt hash:

``` text
$6$...
```

Hashes using an explicit rounds field are also supported:

``` text
$6$rounds=5000$...
```

No `{SHA512-CRYPT}` prefix is stored.

The secrets directory and credential file are intentionally more
restrictive than the public store files.

## `aliases`

Format:

``` text
<alias-address> <target-address>
```

Examples:

``` text
contact@example.org user@example.org
billing@example.org accounting@example.net
```

The alias address belongs to a canonical managed domain.

A target is either:

-   an existing mailbox in a managed canonical domain; or
-   an external address.

Alias-to-alias chains are not supported in v1.

## `defaults`

Administrative role local-parts, one per line.

The initial set is:

``` text
postmaster
abuse
webmaster
hostmaster
```

These defaults are intended for domain provisioning workflows. They are
distinct from host-level system aliases such as `root`.

## `config`

Global host-level mail platform settings use:

``` text
key = value
```

The current v1 key set is:

``` text
imap_hostname_pattern = imap.%domain%
smtp_hostname_pattern = smtp.%domain%
mx_hostname_pattern = mail.%domain%
dkim_selector = mail
vmail_base = /var/vmail
smtpd_conf_path = /etc/smtpd.conf
dovecot_users_path = /etc/dovecot/users
dovecot_lmtp_socket = /run/dovecot/lmtp
```

### Hostname patterns

The standard client/service names are deliberately separate:

``` text
imap.<domain>
smtp.<domain>
mail.<domain>
```

This supports clients that guess conventional IMAP and SMTP hostnames
even when automatic client configuration is unavailable.

`mail.<domain>` is the default MX hostname pattern; it is not used as a
substitute for the separate IMAP and SMTP client names.

### Paths

The OpenSMTPD configuration path, Dovecot users path, and Dovecot LMTP
socket are configuration values rather than being permanently tied to
one installation layout.

This is important for reuse, but only the Debian 13 reference layout is
currently tested.

## `domain-overrides`

Format:

``` text
<domain> <key> <value>
```

Example:

``` text
example.org dkim_selector 2026a
```

This file is for per-domain exceptions to global defaults.

A domain/key combination must not occur more than once.

## Generated artifacts

A generation contains:

``` text
dovecot-users
smtpd-domains
smtpd-local-recipients
smtpd-forward-recipients
virtual-local
virtual-forward
smtpd-mailhosting.conf
```

These files are regenerated from the store and must not be edited as
authoritative configuration.

## Permissions

The initialization and deployment tools apply restrictive permissions to
secret/deployment material.

In particular, the deployed Dovecot users file is installed as:

``` text
root:dovecot 0640
```

on the tested Debian 13 setup so that the Dovecot authentication process
can read it while it remains unavailable to ordinary users.

Exact ownership/group assumptions are part of the currently tested
Debian implementation and must be re-evaluated before claiming support
for another platform.
