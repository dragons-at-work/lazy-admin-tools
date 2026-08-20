# Mailserver architecture

## Goal

The mailserver tools manage multiple independent mail domains without
making the administration scripts themselves specific to dragons@work
infrastructure.

A canonical domain can have its own mailbox namespace and client-facing
DNS names such as:

``` text
imap.example.org
smtp.example.org
mail.example.org
```

Alias domains can map additional domains onto a canonical domain without
creating a second mailbox namespace.

The implementation is intentionally small and file based.

## Platform status

The current implementation is tested on Debian 13 with Dovecot 2.4.x and
OpenSMTPD 7.6 portable.

OpenBSD has not yet been tested. No compatibility claim is made for
OpenBSD or other platforms at this time.

## Source of truth

The authoritative configuration lives below:

``` text
/etc/mailserver/
```

It describes:

-   canonical domains;
-   alias domains;
-   mailboxes;
-   credentials;
-   mail aliases;
-   administrative role defaults;
-   global settings;
-   per-domain overrides.

OpenSMTPD tables and the Dovecot passwd file are generated from this
store. Generated artifacts must not become a second source of truth.

## Separation from host configuration

The tools do not own the complete `/etc/smtpd.conf`.

Host-specific concerns remain in the host configuration, for example:

-   listeners;
-   system aliases such as `root`;
-   local host domains;
-   the outbound relay or smarthost;
-   relay authentication;
-   host-specific envelope sender policy.

The mailserver tools generate a mail-hosting fragment. The host
configuration includes it once:

``` text
include "/etc/mailserver/generated/smtpd-mailhosting.conf"
```

This allows hosted mail configuration to be regenerated without
rewriting unrelated OpenSMTPD configuration.

## Delivery model

### Real mailboxes

A real mailbox terminates OpenSMTPD virtual expansion at the `vmail`
system user and is delivered to Dovecot through LMTP.

Conceptually:

``` text
user@example.org
    -> virtual-local
    -> vmail
    -> LMTP
    -> Dovecot
```

### Local aliases

An alias whose target is an existing mailbox is expanded to that mailbox
before LMTP delivery:

``` text
contact@example.org
    -> user@example.org
    -> vmail
    -> LMTP
    -> Dovecot
```

Alias-to-alias chains are intentionally not supported by the declarative
store in v1.

### External aliases

An alias may target an external address. These recipients are generated
into the forward recipient set and use OpenSMTPD `forward-only`
expansion.

Testing on the Debian 13 reference host confirmed that the resulting
remote delivery uses the host's existing outbound relay path.

### Alias domains

OpenSMTPD virtual tables do not provide the dynamic local-part
substitution needed to express an alias domain as a single rule.

The generator therefore creates explicit entries for every mailbox and
alias belonging to the canonical domain.

For example, if:

``` text
example.net -> example.org
user@example.org
contact@example.org -> user@example.org
```

the generated tables contain corresponding explicit recipients for:

``` text
user@example.net
contact@example.net
```

## System aliases

System mail and hosted mail remain separate concepts.

A host may continue to use its normal `/etc/aliases` for addresses such
as `root`. OpenSMTPD can expand a system alias to a hosted virtual
address, after which the generated virtual tables continue the
expansion.

This chain was tested successfully.

## Generation model

A deploy creates a complete new directory:

``` text
/etc/mailserver/generations/<timestamp>/
```

It contains all generated OpenSMTPD tables, the generated OpenSMTPD
fragment, and the generated Dovecot user data for that generation.

The stable path is:

``` text
/etc/mailserver/generated
```

and is a symlink to the active generation.

Promotion is performed by switching this symlink atomically. This
prevents OpenSMTPD from seeing a mixture of files from two generations.

On the first generation-based deployment, an existing legacy
`generated/` directory is retained as a `pre-generations-*` generation
so that it can serve as the rollback target.

## Validation boundaries

There are three validation layers.

### Store validation

`mailserver-validate.sh` checks the internal model before generation.

Examples include:

-   duplicate objects;
-   missing credentials;
-   invalid references;
-   aliases targeting missing local mailboxes;
-   duplicate per-domain overrides;
-   recognized configuration keys.

### Generated-artifact validation

`mailserver-validate-generated.sh` validates generated OpenSMTPD and
Dovecot syntax using temporary configuration.

This is deliberately a syntax/configuration validation. A pre-deploy
`doveadm user` lookup is not used because it talks to the running
Dovecot authentication service rather than providing an isolated lookup
against the temporary configuration.

### Production and live validation

Before promotion, deployment verifies that the current production
OpenSMTPD and Dovecot configuration is already healthy. An unrelated
pre-existing configuration error therefore aborts deployment before
production state is changed.

After promotion and installation, the services are restarted and a live
Dovecot user lookup is used when at least one mailbox exists.

## Rollback boundary

The deployment mechanism owns and can roll back:

-   the active generated generation;
-   the deployed Dovecot users file.

It does not claim ownership of unrelated host configuration such as
arbitrary files below `/etc/dovecot/conf.d/`.

If an external host configuration file is already broken, pre-flight
validation stops deployment. If an external file is changed after
pre-flight and causes service startup to fail, the mailserver-managed
state is rolled back, but the external file itself is not rewritten.

## Mail data

Mailbox identity and mailbox data are deliberately separate.

`mail-mailbox-del.sh` removes the mailbox from the declarative store and
removes its credential. It does **not** remove:

``` text
/var/vmail/<domain>/<user>/
```

or any mail stored there.

Data destruction, archival, and retention are separate operational
concerns and are not implicit side effects of deleting a mailbox
definition.
