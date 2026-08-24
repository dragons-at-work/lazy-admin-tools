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

A single alias address may appear on multiple lines with different
targets - this is how multi-recipient aliases are declared:

``` text
wir@example.org sandra@example.org
wir@example.org michael@example.org
```

`mailserver-generate` aggregates all lines for the same alias address
into one generated table entry with a comma-separated value, matching
OpenSMTPD's `table(5)` aliasing format (one key, one-or-many
recipients per line - not repeated keys). The exact same
`(alias, target)` pair twice is rejected as a duplicate; different
targets for the same alias address are not.

All targets for one alias address must be the same kind - either all
existing local mailboxes, or all external addresses, never a mix.
`virtual_local` (local delivery) and `virtual_forward` (external
relay) are two separate OpenSMTPD actions; only one fires per
recipient, so a mixed alias would silently deliver to only half its
targets. Both `mailserver-validate` and `mailserver-generate` reject
this.

A domain-alias mirror of a multi-recipient alias (see
[`domain-aliases`](#domain-aliases) above) reuses this same
aggregated result under its mirrored address - it is not
reclassified or re-aggregated separately, so the mirror always
matches the canonical alias's target list exactly.

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
autoconfig_hostname_pattern = autoconfig.%domain%
dkim_selector = mail
dkim_backend = none
autoconfig_backend = none
vmail_base = /var/vmail
smtpd_conf_path = /etc/smtpd.conf
dovecot_users_path = /etc/dovecot/users
dovecot_sni_conf_path = /etc/dovecot/conf.d/90-mailserver-sni.conf
dovecot_lmtp_socket = /run/dovecot/lmtp
```

`dkim_backend` is `none` (or unset) by default - DKIM signing is
opt-in. The only other supported value is `rspamd`; any other value
fails generation. See [`operations.md`](operations.md) for setup.

`autoconfig_backend` is `none` (or unset) by default - Thunderbird/
client autoconfiguration is opt-in. The only other supported value is
`nginx`; any other value fails generation. `autoconfig_hostname_pattern`
is only required when it is enabled. See [`operations.md`](operations.md)
for setup.

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

`smtpd-auth` is generated from `secrets/users`, independently of
`dovecot-users` rather than derived from it - both trace back to
`secrets/users` directly. It reshapes the same mailbox credentials
into OpenSMTPD's `table(5)` credentials format (`user password`,
space-separated) instead of Dovecot's passwd-file format
(`user:password`), so the same SHA512-Crypt hash authenticates both
IMAP (Dovecot) and SMTP submission (OpenSMTPD `listen ... auth`)
without a second password store. Confirmed empirically: OpenSMTPD
accepts these hashes directly for listener auth (`235 2.0.0
Authentication succeeded`).

Only mailbox credentials go into `smtpd-auth` in v1. Relay/service
credentials (e.g. for other hosts relaying through this one) are a
separate future source; a later version of this script will merge
them in here without needing to be real mailboxes.

`smtpd-mailtls.conf` generates a `pki` block and SNI-multiplexed
listeners (ports 25 and 587) for every canonical domain, using
`mx_hostname_pattern`/`smtp_hostname_pattern`/`imap_hostname_pattern`
(global or per-domain via `domain-overrides`) to compute the expected
hostnames. Generation fails closed: every domain must already have a
matching, name-complete certificate deployed under `/etc/ssl/local/`
(by the separate `cert/` toolset) - missing, mismatched (checked via
public key comparison), or incomplete (checked via the certificate's
SANs) fails the entire run rather than producing a domain without
TLS. See [`../docs/architecture.md`](architecture.md) for how this
fragment relates to `smtpd-mailhosting.conf`.

`rspamd-dkim_signing.conf` and DKIM filter wiring in
`smtpd-mailtls.conf` are opt-in via the global `dkim_backend` config
key (`rspamd` or unset/`none`). When enabled, generation fails closed
the same way: every canonical domain must already have a DKIM private
key at `/etc/mail/dkim/<domain>.<selector>.key` (created separately
via `mail-dkim-create`) that is actually readable by the `_rspamd`
system user and parses as a valid private key - checked by running
`openssl pkey` as `_rspamd` itself, not just checked for readability
by the root process running the generator. `mailserver-deploy`
installs the generated file to rspamd's own
`local.d/dkim_signing.conf` on the host, with backup and rollback, as
part of its normal deploy sequence - it is not a separate manual step
for routine changes. See [`operations.md`](operations.md) for the
full setup, including why `opensmtpd-filter-dkimsign` (a
single-instance-per-domain filter chained on the listener) was tested
and rejected in favor of rspamd.

`smtpd-senders` restricts which envelope-from addresses an
authenticated submission user may use, via OpenSMTPD's own `senders
<table>` listener option (not a filter). Derived entirely from
`virtual-local` rather than a separate permission list: a mailbox may
send as itself and as any local address (a direct alias, or a
domain-alias mirror of the mailbox or one of its aliases) that
`virtual-local` already resolves to it. Addresses only reachable via
`virtual-forward` (external targets) are never included. This closes
a real gap found in production: without it, a user authenticated as
one mailbox could successfully submit mail claiming to be a different
local mailbox - not signed with that domain's DKIM key (rspamd
correctly declines when the authenticated user doesn't match), but
still accepted and relayed unsigned.

`nginx-autoconfig.conf` and the per-domain `autoconfig/<domain>/mail/
config-v1.1.xml` files are opt-in via the global `autoconfig_backend`
config key (`nginx` or unset/`none`). When enabled, generation fails
closed the same way as the TLS fragment: every canonical domain's
certificate must also cover its autoconfig hostname (checked in the
same SAN loop as mx/smtp/imap) - a missing SAN aborts the entire run.
Uses the domain's existing mail certificate rather than a separate
one; no additional certificate lifecycle just for autoconfig. See
[`operations.md`](operations.md) for the full setup, including the
real Thunderbird test this was proven against.

A generation contains:

``` text
dovecot-users
smtpd-auth
smtpd-senders
smtpd-domains
smtpd-local-recipients
smtpd-forward-recipients
virtual-local
virtual-forward
smtpd-mailhosting.conf
smtpd-mailtls.conf
dovecot-ssl-sni.conf
rspamd-dkim_signing.conf
nginx-autoconfig.conf
autoconfig/<domain>/mail/config-v1.1.xml (one per canonical domain)
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
