# certs

Request TLS certificates through one uniform frontend, independent of
which ACME client is available on the platform.

## Usage

```bash
sudo cert-add primary.example.org alias1.example.org alias2.example.org
```

The first name is the primary identifier and determines where the
certificate is stored. Any further names are requested as additional
SANs on the same certificate.

The backend is auto-detected (currently only `uacme`). If more than
one backend is installed, or to select one explicitly:

```bash
sudo cert-add --backend uacme primary.example.org
```

### First-time account setup

The first certificate request on a host creates the ACME account.
With a terminal attached, `cert-add` asks for the account email
interactively:

```text
$ sudo cert-add primary.example.org
[OK] all names resolve in DNS
[INFO] using backend: uacme
[OK] local HTTP-01 challenge path works
[INFO] no ACME account found under /var/lib/uacme
ACME account email:
```

For non-interactive or automated use, set it up front instead:

```bash
sudo ACME_ACCOUNT_EMAIL=admin@example.org cert-add primary.example.org
```

Once the account exists, later runs skip this step entirely - there
is no default email baked into the tool.

## Deploying certificates to their consumers

`cert-add` only issues the certificate into the ACME backend's own
store (e.g. `/var/lib/uacme/<primary-name>/`). Services like Dovecot
or OpenSMTPD do not read from there directly. `cert-deploy` copies the
certificate and key to a service-neutral location and optionally
restarts services:

```bash
sudo cert-deploy primary.example.org dovecot opensmtpd
```

This installs:

```text
/etc/ssl/local/primary.example.org/cert.pem   (0644 root:root)
/etc/ssl/local/primary.example.org/key.pem    (0600 root:root)
```

then restarts each named service and confirms it is active afterward.
`cert-deploy` is idempotent - if the destination certificate and key
already match the source, nothing is copied and no service is
restarted. Before deploying anything, it also verifies the
certificate and key actually belong together (public key comparison,
RSA and EC) - a corrupted or mismatched backend state is refused
rather than deployed.

## Scheduling renewal

```bash
sudo cert-renew-install
```

Installs a daily run of `cert-renew`, using whichever mechanism fits
the host, so a new server does not depend on remembering how this was
set up elsewhere:

- systemd hosts (Debian and similar): `/etc/cron.d/lazy-admin-tools-cert-renew`
  - requires a running `cron` daemon; `/etc/cron.d` existing is not
    enough on a minimal install. `cert-renew-install` checks for this
    explicitly (`apt install cron` if missing) rather than writing an
    entry that might silently never run.
- rcctl hosts (OpenBSD): an entry in root's crontab

Idempotent - running it again does not create duplicate entries or
touch unrelated existing crontab content. Output is logged to
`/var/log/cert-renew.log` (0640 root:root).

`cert-deploy`'s service restart step is similarly OS-neutral: it uses
`systemctl restart`/`is-active` where available, `rcctl restart`/
`check` otherwise.

## Renewing certificates

```bash
sudo cert-renew
```

Iterates every certificate the backend knows about, asks it to renew
(the ACME client itself decides whether a renewal is actually due),
and deploys + reloads only the certificates that were genuinely
renewed. Intended for cron.

Reload targets per certificate are read from an optional manifest:

```text
/etc/cert-deploy/<primary-name>.services
```

One service name per line, `#` comments and blank lines ignored. No
manifest means files are deployed but nothing is restarted.

## Removing certificates

```bash
sudo cert-del primary.example.org
```

Removes the ACME backend's local state and the deployed copy under
`/etc/ssl/local/primary.example.org/`. Does **not** revoke the
certificate at the CA - that is a separate, more destructive
operation for cases like a compromised key, not implemented here.
Does not touch any service configuration that might reference this
certificate.

Refuses to delete if a service-reload manifest
(`/etc/cert-deploy/<primary-name>.services`) exists for this
certificate - that manifest is this toolset's own record of a known
consumer on this host. Override with `--force`, which also removes
the manifest itself as part of the cleanup:

```bash
sudo cert-del --force primary.example.org
```

## Architecture

```text
cert-add.sh                frontend: request a new certificate -
                            argument parsing, validation, DNS
                            preflight, backend selection, uniform
                            output
cert-deploy.sh              frontend: install a certificate for its
                             consumers - asks the backend where the
                             files are, copies them, restarts services
                             (OS-neutral: systemctl or rcctl)
cert-renew.sh                 frontend: renew every known certificate
                               and deploy the ones that changed (cron)
cert-renew-install.sh          frontend: schedule cert-renew for this
                                host (cron.d or root's crontab,
                                whichever fits)
cert-del.sh                     frontend: remove a certificate's local
                                 state - refuses if a service manifest
                                 marks it as still in use (no revoke)
backends/
  uacme.sh                 uacme-specific: account bootstrap, hook
                            probe, issue call. Also answers "paths"
                            (where are this certificate's files),
                            "list" (which certificates exist, with
                            their SANs), "renew" (renew + report
                            whether the certificate file actually
                            changed), and "del" (remove local state
                            only, no revoke) for the other frontends.
  acme-client.sh            planned (OpenBSD), not present yet
hooks/
  uacme-http-01.sh           http-01 hook for uacme
```

`cert-add.sh`, `cert-deploy.sh`, and `cert-renew.sh` have no knowledge
of any backend's option syntax or on-disk layout - that is
deliberately kept inside `backends/<name>.sh`. The CLI stays identical
across platforms; only the backend underneath changes (`uacme` on
Debian, `acme-client` planned for OpenBSD).

## Requirements (uacme backend)

- `uacme` installed
- a system user `uacme`, member of the webserver's group so the hook
  can write into the challenge directory
- a challenge directory, e.g. `/var/www/acme-challenge/.well-known/acme-challenge`,
  served on port 80 by the webserver for all requested hostnames
- port 80 (IPv4 and IPv6) reachable from the internet - both on the
  host firewall and on any upstream/provider firewall in front of it

## Preflight scope

`cert-add` only checks what it can actually verify:

- domain syntax of every requested name
- DNS A/AAAA resolution, checked twice: via the local/system resolver
  (`dig` if available, `host` otherwise - `dig` is not installed on
  every host this runs on), and directly against the name's own
  authoritative nameservers, using whichever of the two tools is
  present. The local resolver alone is not sufficient - a caching or
  split-horizon resolver can report success even when the
  authoritative nameservers, which is what Let's Encrypt actually
  sees, do not have the record. This was found for real in two parts:
  a name with no DNS record at all was still reported as resolving,
  because `host`'s own "not found" message is non-empty text on
  stdout, not an empty result - checking for empty output treated
  that message itself as a successful resolution. Fixed by checking
  `host`'s exit status instead. The authoritative-nameserver check was
  added on top for the same underlying concern (local view diverging
  from the public one) and confirmed against the same real name.
- the hook can write and remove a file in the challenge directory as
  the `uacme` user (local proof only)

A successful local check does not prove the host is reachable from
the ACME server across the internet - the actual `uacme issue` call
remains the real proof of that.

## Certificate location (uacme backend)

```text
/var/lib/uacme/<primary-name>/cert.pem          (0444 uacme:uacme)
/var/lib/uacme/private/<primary-name>/key.pem   (0400 uacme:uacme)
```

Permissions above are uacme's own behavior, not this repo's contract -
listed here only as what was actually observed on a real issuance, not
as something `cert-add` sets or guarantees.

`cert.pem` already contains the full chain (leaf plus intermediates) -
there is no separate `chain.pem` in v1's observed layout. Confirmed
against a real Let's Encrypt issuance: `grep -c 'BEGIN CERTIFICATE'
cert.pem` returned 3.

Use `cert-deploy`, not these paths directly, to get a certificate to
where a service can actually read it - see below.

## Status

- uacme backend: implemented and tested (issuance)
- `list`/`renew` logic: tested end-to-end against a real self-signed
  certificate and the real `uacme` binary for all three outcomes -
  "still valid, nothing to do", "real failure", and the renewed case
  verified via hash comparison. Found and fixed along the way: `uacme
  issue` exits non-zero both on a genuine failure and on its normal
  "not due for renewal yet" skip - the exit code alone cannot
  distinguish them, so `renew` treats a changed certificate file as
  the primary signal and only falls back to uacme's own wording as a
  secondary check when the file did not change.
- The same skip-vs-failure ambiguity was found in `add` (not just
  `renew`) via a real case: re-running `cert-add` for a certificate
  that already existed and was not yet due for renewal was wrongly
  reported as "[ERROR] uacme issue failed" even though nothing was
  wrong. Fixed the same way - the certificate file's existence after
  the call is the source of truth, not the exit code alone.
- cert-renew: the "certificate still valid, nothing to do" path has
  been proven end-to-end in production against the real Let's Encrypt
  API - real ARI renewal window read from the CA, correct RENEWED=no,
  no deploy, no restart. Only a genuine renewal event (a certificate
  actually due) has not been observed live yet.
- cert-deploy: implemented and tested (idempotency on cert+key,
  service restart failure handling), including a real production run
  confirming idempotency (identical cert+key already deployed by hand
  earlier -> no copy, no restart)
- OS-neutral service restart (systemctl/rcctl) and scheduling
  (cron.d/root's crontab) implemented and tested against both real
  and stand-in `systemctl`/`rcctl`/`crontab`; not yet exercised on a
  real OpenBSD host
- acme-client backend: not built yet

-- lazy-admin-tools - dragons@work
