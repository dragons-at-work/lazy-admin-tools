# Mailserver installation

## Scope

These instructions describe the currently tested environment:

-   Debian 13
-   Dovecot 2.4.x
-   OpenSMTPD 7.6 portable

OpenBSD and other platforms have not yet been tested.

The tools do not install or fully configure OpenSMTPD or Dovecot. They
manage the hosted-mail portion after the underlying services and
required system users exist.

## Prerequisites

The reference setup expects:

-   OpenSMTPD installed and operational;
-   Dovecot installed and operational;
-   LMTP enabled in Dovecot;
-   a `vmail` system user/group suitable for virtual mail ownership;
-   a working host-level outbound mail path;
-   root access for administration;
-   the mailserver scripts installed together so `mailserver-deploy.sh`
    can invoke the validator/generator scripts from the same directory.

Before introducing hosted domains, verify the existing services
independently.

## Dovecot model

The tested Dovecot storage model is Maildir with a virtual-mail base:

``` text
mail_driver = maildir
mail_home = /var/vmail/%{user | domain}/%{user | username}
mail_path = %{home}
mail_uid = vmail
mail_gid = vmail
```

Authentication uses a passwd-file with SHA512-Crypt credentials and a
static user database.

The exact surrounding Dovecot configuration remains host configuration.
The mailserver tools deploy the generated users file to the configured
`dovecot_users_path`.

## Initialize the store

Run:

``` bash
sudo ./mailserver-init.sh
```

The command is idempotent: existing files are preserved rather than
overwritten.

Inspect the resulting configuration:

``` bash
sudo find /etc/mailserver -maxdepth 2 -printf '%M %u:%g %p\n'
sudo cat /etc/mailserver/config
```

Adjust host-level paths in `/etc/mailserver/config` if necessary before
deployment.

## OpenSMTPD integration

The mailserver tools deliberately do not replace `/etc/smtpd.conf`.

The host configuration remains responsible for the local system-mail
listener, system aliases, local host mail, and outbound relay
configuration.

Add the generated fragments once:

``` text
include "/etc/mailserver/generated/smtpd-mailhosting.conf"
include "/etc/mailserver/generated/smtpd-mailtls.conf"
```

`smtpd-mailtls.conf` also generates the listeners for ports 25 and
587 covering all hosted domains (SNI-multiplexed) - do not add
separate host-level `listen ... port 25`/`port 587` lines for hosted
mail, or the two will conflict at bind time (`Address already in
use`) even though `smtpd -n` parses both individually without
complaint.

Before this fragment will generate successfully, every canonical
domain needs a certificate already issued and deployed under
`/etc/ssl/local/<mx-hostname>/` - see the separate `cert/` toolset
(`cert-add`, `cert-deploy`).

Do not copy host-specific relay credentials or relay hosts into the
lazy-admin-tools scripts.

The generated fragments reference their generation's OpenSMTPD
tables.

## Dovecot integration

Unlike OpenSMTPD, no manual `include` line is needed - Dovecot's own
default `dovecot.conf` already wildcard-includes `conf.d/*.conf`.
`mailserver-deploy` installs the generated per-domain TLS/SNI config
directly to the path configured as `dovecot_sni_conf_path` (default
`/etc/dovecot/conf.d/90-mailserver-sni.conf`).

`dovecot_sni_conf_path` is a required config key, same as
`dovecot_users_path` - `mailserver-init` only writes it into a fresh
`/etc/mailserver/config`, so an existing installation predating this
key must add it by hand once before the next `mailserver-generate`/
`mailserver-deploy`:

``` text
dovecot_sni_conf_path = /etc/dovecot/conf.d/90-mailserver-sni.conf
```

Without a per-domain SNI match, Dovecot silently falls back to
whichever certificate a host-level default names - correct for
exactly one domain and wrong for every other. This was found
manually (Thunderbird presenting the wrong domain's certificate) and
is why this integration exists as generated, deployed configuration
rather than a one-off manual fix.

## Existing system aliases

A normal host `/etc/aliases` setup can remain in place.

For example, host administration may forward `root` to a hosted address.
OpenSMTPD can expand the system alias first and then continue through
the generated virtual-mail tables.

Keep system aliases conceptually separate from hosted-domain aliases in
`/etc/mailserver/aliases`.

## First test domain

Create a canonical domain:

``` bash
sudo ./mail-domain-add.sh example.org
```

Add a mailbox:

``` bash
sudo ./mail-mailbox-add.sh user@example.org
```

The command asks for the password twice and generates a SHA512-Crypt
hash using Dovecot tooling.

For migration from an existing compatible system, an existing hash can
be supplied:

``` bash
sudo ./mail-mailbox-add.sh --hash '$6$rounds=5000$...' user@example.org
```

Add an alias:

``` bash
sudo ./mail-alias-add.sh contact@example.org user@example.org
```

Optionally add an alias domain:

``` bash
sudo ./mail-domain-alias-add.sh example.net example.org
```

## Validate before deployment

First validate the source of truth:

``` bash
sudo ./mailserver-validate.sh
```

Then generate artifacts:

``` bash
sudo ./mailserver-generate.sh
```

Then validate the generated artifacts:

``` bash
sudo ./mailserver-validate-generated.sh
```

A normal production deployment performs these checks again as part of
its own workflow.

## First deploy

Run:

``` bash
sudo ./mailserver-deploy.sh
```

The generation-based deploy:

1.  validates the store;
2.  verifies that the current production OpenSMTPD, Dovecot, and (if
    enabled) rspamd/nginx configuration is healthy;
3.  builds a fresh generation;
4.  validates that generation independently;
5.  backs up the current Dovecot users file and SNI config;
6.  atomically promotes the new generation through
    `/etc/mailserver/generated`;
7.  validates production OpenSMTPD against the promoted generation;
8.  installs the generated Dovecot users file;
9.  installs the generated Dovecot per-domain TLS/SNI config
    (mandatory, same as the users file - not opt-in);
10. installs the generated rspamd DKIM config, only when
    `dkim_backend = rspamd`;
11. installs the generated autoconfig nginx vhost and per-domain XML
    files, only when `autoconfig_backend = nginx`;
12. restarts Dovecot, (if installed) rspamd, and OpenSMTPD, then
    reloads nginx if the autoconfig vhost was installed;
13. performs a live Dovecot user lookup when a mailbox exists;
14. retains the previous generation and credential/config backups for
    rollback/audit purposes.

Steps 10 and 11 are skipped without error when their respective
backend is not enabled - the total step count shown by the script
adjusts accordingly (12 steps with both disabled, up to 14 with both
enabled).

An existing legacy `/etc/mailserver/generated/` directory is preserved
during the first generation-based deploy as a `pre-generations-*`
generation.

## Functional verification

After deployment, test both a direct mailbox and a local alias.

For example:

``` bash
echo "direct test" | mail -s "mailserver test" user@example.org
echo "alias test" | mail -s "mailserver alias test" contact@example.org
```

Verify delivery in the expected Maildir or through IMAP.

The reference implementation has also been tested for:

-   local alias to mailbox delivery;
-   alias-domain recipient expansion;
-   external alias forwarding through the existing outbound relay;
-   system alias -\> hosted alias/mailbox expansion.

## DNS, certificates, and client autoconfiguration

The data model already defines conventional hostname patterns for MX,
IMAP, and SMTP.

Automatic DNS provisioning, certificate provisioning, DKIM/SPF/DMARC
automation, and client autoconfiguration are not documented here as
completed v1 behavior unless corresponding tools are present and tested.

Do not infer those features merely from the configuration keys.
