# Mailserver operations

## Operating principle

Make changes to the declarative store, validate them, and deploy a
complete generated generation.

Do not edit generated OpenSMTPD tables as the source of truth.

## Add a canonical domain

``` bash
sudo ./mail-domain-add.sh example.org
```

The domain must not already exist as a canonical or alias domain.

## Add an alias domain

``` bash
sudo ./mail-domain-alias-add.sh example.net example.org
```

The target must be an existing canonical domain.

Alias domains have no independent mailboxes. During generation, mailbox
and alias recipients of the canonical domain are mirrored explicitly.

## Add a mailbox

Interactive password:

``` bash
sudo ./mail-mailbox-add.sh user@example.org
```

Migration with an existing SHA512-Crypt hash:

``` bash
sudo ./mail-mailbox-add.sh --hash '$6$rounds=5000$...' user@example.org
```

A mailbox can only belong to a configured canonical domain.

The mailbox address and credential are written together. The tool is
designed to avoid leaving only one side updated if the second write
fails.

## Reset a mailbox password

Administrative reset - root sets a new password without knowing the
old one. This is not a self-service password change; a mailbox owner
authenticating with their current password is a separate, not yet
built tool (`mail-passwd`), which needs its own privileged interface
since mailbox users are not Unix accounts.

Interactive:

``` bash
sudo ./mail-mailbox-passwd.sh user@example.org
```

Non-interactive, e.g. for scripting or migration:

``` bash
sudo ./mail-mailbox-passwd.sh --hash '$6$rounds=5000$...' user@example.org
```

Only the credential in `secrets/users` is changed. The mailbox entry,
its aliases, and everything else in the store are left untouched.
After a reset, regenerate and deploy as usual so the new hash reaches
both `dovecot-users` and `smtpd-auth`:

``` bash
sudo mailserver-validate
sudo mailserver-deploy
```

## Add an alias

Local target:

``` bash
sudo ./mail-alias-add.sh contact@example.org user@example.org
```

External target:

``` bash
sudo ./mail-alias-add.sh accounting@example.org accounting@example.net
```

For a target inside a managed canonical domain, the target must be an
existing mailbox. Alias chains are not supported in v1.

## DKIM

Create a persistent DKIM keypair for a domain:

``` bash
sudo ./mail-dkim-create.sh biocodie.de
```

The selector defaults to `dkim_selector` from `config` (or a
per-domain override in `domain-overrides`); pass one explicitly if
neither is set:

``` bash
sudo ./mail-dkim-create.sh biocodie.de mail
```

This only creates the key under `/etc/mail/dkim/<domain>.<selector>.key`
(group-owned by `_rspamd`, mode 0640, so the running rspamd daemon can
read it) and prints the DNS TXT record to publish. It does not touch
DNS or rspamd's own installation - both remain manual steps. Once the
key exists, `mailserver-generate` picks it up automatically for the
domain mapping (see below) when `dkim_backend = rspamd`.

The key is long-lived state, like a certificate's private key -
`mail-dkim-create` refuses to overwrite an existing one without
`--force`, since a new key invalidates whatever is already published
in DNS.

**Signing is done by rspamd (sign-only), not `opensmtpd-filter-dkimsign`
directly - proven for two real domains with independent keys.** An
earlier approach chaining one `filter-dkimsign` instance per domain on
the submission listener was tested end-to-end and rejected: OpenSMTPD
runs every filter in a chain unconditionally, so each message got
signed by every domain's filter regardless of its actual `From:`
domain - one correct signature plus one spurious signature for an
unrelated domain, on every message. `filter-dkimsign` itself also only
supports one key/selector per filter instance (multiple `-d` values
only pick among names for the *same* key, not independent keys).

Rspamd's `dkim_signing` module selects the correct domain/key from the
message's `From:` header itself, so one filter instance handles every
domain. Host installation and rspamd's own base config remain a
one-time manual step (rspamd's config directory is outside this
store); the per-domain mapping and filter wiring are generated once
that base setup exists - see below.

Install without pulling in Redis/Valkey (not needed - the module
supports `use_redis = false`):

``` bash
sudo apt install --no-install-recommends rspamd opensmtpd-filter-rspamd
```

`local.d/dkim_signing.conf`:

``` text
use_domain = "header";
use_redis = false;
sign_authenticated = true;
sign_local = true;

domain {
    biocodie.de {
        selector = "mail";
        path = "/etc/mail/dkim/biocodie.de.mail.key";
    }
    frederike-amalia-sinclair.de {
        selector = "mail";
        path = "/etc/mail/dkim/frederike-amalia-sinclair.de.mail.key";
    }
}
```

`local.d/settings.conf` (sign-only rule, applied via `-settings-id`,
per the `opensmtpd-filter-rspamd` project's own documented usage):

``` text
outgoing {
    id = "outgoing";
    apply {
        groups_enabled = ["dkim"];
        actions {
            reject = 100.0;
            greylist = 100.0;
            "add header" = 100.0;
        }
    }
}
```

`opensmtpd-filter-rspamd` speaks rspamd's native HTTP protocol against
the `normal` worker (port 11333 by default) - it does not use the
Milter protocol, so the `rspamd_proxy` worker's documented "self-scan"
mode (which serves Milter on port 11332) does not apply here and the
`normal` worker must stay enabled.

Once rspamd is installed and configured as above (a one-time, manual
host setup step - not derived from the store), enable the store-driven
domain mapping and filter wiring with a single config key:

``` bash
sudo tee -a /etc/mailserver/config << 'EOF'
dkim_backend = rspamd
EOF
sudo mailserver-validate
sudo mailserver-deploy
```

From here on, `mailserver-generate` produces `rspamd-dkim_signing.conf`
(the `domain{}` block from every canonical domain's key) and adds
`filter "rspamd_outgoing" proc-exec "filter-rspamd -settings-id
outgoing"` to the port 587 (submission) listeners only in
`smtpd-mailtls.conf` - never port 25, so only mail entering via
authenticated submission is signed, not mail merely relayed through
the host. Generation fails closed the same way as the TLS fragment:
every canonical domain must already have a key at
`/etc/mail/dkim/<domain>.<selector>.key` (via `mail-dkim-create`) that
is actually readable by the `_rspamd` system user and parses as a
valid private key - checked by running `openssl pkey` as `_rspamd`
itself via `runuser`, not just checked for readability by the root
process running the generator, since those can differ.

`mailserver-deploy` installs the generated `rspamd-dkim_signing.conf`
to `/etc/rspamd/local.d/dkim_signing.conf` itself when
`dkim_backend = rspamd` - backed up and rolled back the same way as
`dovecot-users` if anything fails. Installed and validated (via
`rspamadm configtest` against the real, running rspamd configuration)
before dovecot, rspamd, and opensmtpd are restarted, and opensmtpd is
restarted last of the three - so submission on port 587 never starts
accepting mail again before the rspamd instance it depends on for
signing is already running with the new domain-to-key mapping. No
manual `cp`/`configtest`/`restart` step is needed for routine changes
(a new domain, a rotated key) - only the one-time rspamd installation
above is manual.

Proven end-to-end with two independent domains and independent keys:
each domain's outgoing mail carries exactly one `DKIM-Signature`
header with the correct `d=` value for its own `From:` domain, no
spurious signature for the other domain, verified against a real
mailbox's raw headers.

## Sender authorization on submission

Generated automatically as `smtpd-senders`, wired to the port 587
listeners via OpenSMTPD's own `senders <table>` listener option -
requires no manual step once the mail store is deployed.

**Found in production, not designed in advance:** DKIM alone does not
stop an authenticated user from submitting mail that claims to be a
different local mailbox. Rspamd correctly declines to sign with a
domain the authenticated user doesn't own (`allow_username_mismatch`
defaults to `false`), but OpenSMTPD still accepted and relayed the
message anyway - just unsigned. Whether that unsigned mail gets
rejected, quarantined, or delivered then depends entirely on the
recipient's own SPF/DMARC policy, which is not something to rely on
for a problem that should be stopped at the source.

`senders` closes this at the SMTP level, before rspamd is even
involved: an authenticated user may only use `MAIL FROM` addresses
listed for them in `smtpd-senders`. The table is derived entirely
from `virtual-local` (see [`configuration.md`](configuration.md)) -
no separate permission list to maintain, and no address only reachable
via `virtual-forward` (an external forward target) is ever included.
Proven for real: the exact spoofing attempt above (authenticated as
one mailbox, `MAIL FROM` claiming a different mailbox's domain) was
retested against the deployed table and rejected with
`530 Sender rejected` at the `MAIL FROM` stage - the message never
reaches rspamd or the queue.

**Verified for real:** `senders` treats a null envelope sender
(`MAIL FROM:<>`) like any other address - it must be explicitly
listed to be allowed, and it is not. `smtpd.conf(5)`/`table(5)` do not
document this special case; it was confirmed by testing it live:
authenticated as one mailbox, `MAIL FROM:<>` was rejected with the
same `530 Sender rejected` as any other unlisted address, alongside
the sender-spoofing attempt this table exists to stop
(`MAIL FROM:<info@other-domain>`) and a legitimate own-alias address
(`250 2.0.0 Ok`) tested in the same session.

This means an authenticated submission user cannot generate a DSN/
bounce (which requires a null sender) through port 587. This does not
affect the server's own outbound bounce handling, which goes through
the `outbound` relay action directly, not through an authenticated
submission session - `senders` only applies to the port 587
listeners. Deliberately left as-is rather than special-casing `<>`
into the generated table: this is stricter than necessary for the
common case, and there is no real path in this setup that needs an
authenticated submission client to send with a null sender.

## Client autoconfiguration (Thunderbird/Outlook)

Generated automatically as `nginx-autoconfig.conf` and one
`config-v1.1.xml` per canonical domain, wired to nginx once
`autoconfig_backend = nginx` is set - no manual step for routine
changes (a new domain, a certificate renewal).

**Proven manually on two real domains before automating, on purpose:**
Thunderbird is picky about the exact XML structure, authentication
type, and socket type - a real client test is worth more than
generating it blind. `biocodie.de`'s and
`frederike-amalia-sinclair.de`'s autoconfig were built by hand first
(own `autoconfig.<domain>` certificate, own nginx vhost, hand-written
XML) and confirmed with a real Thunderbird client: "Settings found at
your provider" instead of "found by guessing typical server names",
followed by a successful login. Only once that worked for real was
the mechanism generalized into the generator.

**One certificate per domain, not two.** The first working version
used a separate `autoconfig.<domain>` certificate. This was
consolidated into the domain's existing mail certificate (now covering
mx/smtp/imap/autoconfig as SANs) after the manual proof, since a
domain that promises Thunderbird autoconfig should own its autoconfig
hostname as part of one certificate lifecycle - one `cert-add`, one
`cert-deploy`, one renewal, instead of a second independent ACME
object just for this. The old standalone `autoconfig.biocodie.de`
certificate was removed with `cert-del` once the consolidated
certificate was deployed and confirmed working.

Setup, once per host:

``` bash
sudo apt install --no-install-recommends nginx
```

(nginx itself, and its use for the ACME http-01 challenge webroot, is
already covered in `cert/README.md` - the same nginx installation is
reused here, not a second one.)

Enable generation with two config keys:

``` bash
sudo tee -a /etc/mailserver/config << 'EOF'
autoconfig_hostname_pattern = autoconfig.%domain%
autoconfig_backend = nginx
EOF
sudo mailserver-validate
sudo mailserver-deploy
```

For each canonical domain, generation fails closed if that domain's
certificate does not also cover its autoconfig hostname as a SAN -
reissue with all four names together:

``` bash
sudo cert-add mail.<domain> imap.<domain> smtp.<domain> autoconfig.<domain>
sudo cert-deploy mail.<domain> dovecot opensmtpd nginx
```

`autoconfig.<domain>` needs its own DNS A/AAAA record pointing at this
host - it is a separate hostname from `mail.<domain>`, just covered by
the same certificate.

`mailserver-deploy` installs the generated nginx vhost fragment to
`/etc/nginx/sites-available/lazy-admin-tools-autoconfig.conf`
(symlinked into `sites-enabled`) and each domain's XML to
`/var/www/autoconfig/<domain>/mail/config-v1.1.xml`, validating against
the real, running nginx configuration before reloading - with backup
and rollback matching the rspamd DKIM config handling.

## Validate the store

Run after administrative changes:

``` bash
sudo ./mailserver-validate.sh
```

The validator reports all detected problems before returning failure
where practical.

A successful result means the declarative store is internally
consistent. It does not by itself prove that the production mail
services are correctly configured.

## Generate

For manual inspection:

``` bash
sudo ./mailserver-generate.sh
```

The deploy workflow normally builds a fresh timestamped generation
itself rather than relying on a previously generated directory.

## Validate generated artifacts

``` bash
sudo ./mailserver-validate-generated.sh
```

This checks that OpenSMTPD and Dovecot accept the generated
configuration syntax without modifying production configuration.

## Deploy

``` bash
sudo ./mailserver-deploy.sh
```

Deployment is generation based.

The stable path:

``` text
/etc/mailserver/generated
```

points to the active directory below:

``` text
/etc/mailserver/generations/
```

The complete OpenSMTPD generation is activated with one symlink swap.

Before changing production state, deployment also validates the
currently active OpenSMTPD and Dovecot configuration. If the host is
already broken, deployment aborts without trying to repair or overwrite
that unrelated state.

If a failure occurs after promotion, the deploy script reverts the
generated symlink and restores the previous Dovecot users file.

## Remove an alias

``` bash
sudo ./mail-alias-del.sh contact@example.org
```

Removing an alias changes only the declarative store. Run validation and
deployment afterwards to make the change effective in production.

## Remove a mailbox

``` bash
sudo ./mail-mailbox-del.sh user@example.org
```

By default, removal is refused while aliases still point to the mailbox.

Remove those aliases first.

A forced removal is possible:

``` bash
sudo ./mail-mailbox-del.sh --force user@example.org
```

This intentionally leaves dependent aliases dangling.
`mailserver-validate.sh` will then report the inconsistency.

### Mail data is not deleted

Removing a mailbox removes:

-   its entry from `mailboxes`;
-   its credential from `secrets/users`.

It does **not** delete its Maildir.

For the default layout, data such as:

``` text
/var/vmail/example.org/user/
```

is left untouched.

Archiving or deleting mailbox data must be a separate deliberate
operation.

## Remove an alias domain

``` bash
sudo ./mail-domain-alias-del.sh example.net
```

This removes the alias-domain relationship from the store.
Regenerate/deploy afterwards.

## Remove a canonical domain

``` bash
sudo ./mail-domain-del.sh example.org
```

The command normally refuses removal while the domain still has:

-   mailboxes;
-   aliases;
-   alias domains pointing to it.

This forces the operator to dismantle the domain deliberately in
dependency order.

A forced removal is available:

``` bash
sudo ./mail-domain-del.sh --force example.org
```

`--force` removes only the domain entry. It does not cascade-delete
dependent mailboxes, aliases, or alias-domain relationships.

The resulting inconsistencies are intentional and are reported by
`mailserver-validate.sh`.

## Recommended removal order

For a complete domain retirement:

``` text
1. remove aliases
2. remove mailboxes
3. remove alias domains
4. remove canonical domain
5. validate
6. deploy
7. handle retained Maildir data separately
```

The exact first three steps can vary with dependencies, but the
canonical domain should be removed only after its dependents have been
handled.

## Failure handling

### Existing production configuration is invalid

Deployment stops during pre-flight.

Fix the existing host configuration first. The mailserver deployment
must not hide unrelated configuration damage.

### New generation is invalid

Deployment stops before promotion. The active generation remains
unchanged.

### Failure after promotion

The deploy script rolls back the active generation and the managed
Dovecot users file.

External host configuration is outside that rollback boundary.

### Empty mailbox set

A deployment with no mailbox users can still be valid. In that case
there is no sample Dovecot user for the final live lookup, and the
deploy reports that fact rather than inventing a test identity.

## Backups and retention

Deployment retains previous generated state and Dovecot-user backups
required for rollback.

This is not a substitute for a complete mail-data backup strategy.
Maildir backup, retention policy, restore testing, and off-host backup
remain separate operational work.
