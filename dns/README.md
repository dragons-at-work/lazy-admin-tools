# dns

Show the actual authoritative DNS state of a domain, queried directly
against its own nameservers - not the local resolver's cached view.

## Usage

```bash
dns-domain-info.sh schwarzer-genealogie.de
```

Determines the domain's authoritative nameservers, then queries a
fixed set of mail-relevant records (SOA, NS, A, AAAA, MX, TXT, plus
`mail`/`imap`/`smtp`/`autoconfig` subdomains, `_dmarc`, the two common
DKIM selectors, and the submission/imaps SRV records) against each
nameserver individually. Nameservers that return an identical answer
are grouped under one heading; nameservers that disagree are shown
separately with a `[WARN]`.

This is an information tool, not a validator: it does not judge
whether an answer is "correct", and it never changes DNS. A missing
record (NXDOMAIN or no record of that type) is shown as `(kein
Record)` - normal output, not an error. Only an actual query or
network failure is treated as an error (non-zero exit).

The backend is auto-detected (currently only `host`). If more than one
backend is installed, or to select one explicitly:

```bash
dns-domain-info.sh --backend host schwarzer-genealogie.de
```

## Backend status

-   `host` - implemented and tested against real authoritative
    nameservers on Debian 13 (terrador)
-   `drill` (OpenBSD/ldns) - not implemented yet; selecting it
    explicitly fails clearly rather than silently falling back to
    `host` (same pattern as `cert-add --backend acme-client`). What is
    actually installed on the project's OpenBSD hosts has not been
    inventoried yet - this is deliberately not guessed at.

## Architecture

Same split as `cert/`: the frontend (`dns-domain-info.sh`) owns the
record list, which nameservers to ask, and how to group/display
results. Each `backends/<name>.sh` owns one tool's actual query syntax
and its own "no record vs. real failure" distinction - the frontend
never parses a backend tool's raw output itself.

Backend contract:

```text
<backend>.sh ns <domain>
    Authoritative nameservers for <domain>, one hostname per line,
    found by walking up the domain's labels until an NS record is
    found. Empty output (exit 0) if none could be determined at all.
    Non-zero exit only on a real query/network failure.

<backend>.sh query <type> <name> [nameserver]
    Records of <type> for <name>, optionally against a specific
    nameserver. One record per line. Empty output (exit 0) means no
    record (NXDOMAIN or no record of that type) - normal information,
    not an error. Non-zero exit only on a real query/network failure.
```
