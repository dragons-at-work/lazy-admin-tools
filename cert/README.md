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

## Architecture

```text
cert-add.sh               frontend: argument parsing, validation,
                           DNS preflight, backend selection, uniform
                           output
backends/
  uacme.sh                 uacme-specific: account bootstrap, hook
                            probe, issue call
  acme-client.sh            planned (OpenBSD), not present yet
hooks/
  uacme-http-01.sh           http-01 hook for uacme
```

`cert-add.sh` has no knowledge of any backend's option syntax - that
is deliberately kept inside `backends/<name>.sh`. The CLI stays
identical across platforms; only the backend underneath changes
(`uacme` on Debian, `acme-client` planned for OpenBSD).

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
- DNS A/AAAA resolution (checked locally, not from the ACME server's
  point of view)
- the hook can write and remove a file in the challenge directory as
  the `uacme` user (local proof only)

A successful local check does not prove the host is reachable from
the ACME server across the internet - the actual `uacme issue` call
remains the real proof of that.

## Certificate location

`/var/lib/uacme/<primary-name>/cert.pem` (plus `key.pem` and
`chain.pem`), uacme's default layout.

## Status

- uacme backend: implemented and tested
- acme-client backend: not built yet

-- lazy-admin-tools - dragons@work
