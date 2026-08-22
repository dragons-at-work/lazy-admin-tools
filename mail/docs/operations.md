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
