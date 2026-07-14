# Security Model

Geodineum is a multi-component ecosystem (a Rust daemon, a PHP framework and
client library, background services, and web themes) that share one ValKey
backend. The deployment is designed so that compromising any single component
yields the least possible additional access. This document describes that model
so it can be reviewed and reasoned about.

## Principles

1. **One group, one access class.** Every system group grants exactly one kind
   of read, to exactly the identities that need it. Reading shared *source code*
   and reading *credentials* are always different groups — they are never
   conflated, so a grant of one can never imply the other.
2. **Credentials are root-owned, group-readable, never group-writable.** A
   credential file is `root:<group>` mode `0640`. The runtime user reads it
   through its group but cannot modify or replace it.
3. **Least privilege by default; the web user is contained.** The web server
   user (`www-data`) can read what it must serve and its own sites' credentials —
   and nothing else. It is a member of no service-credential group and no
   service-runtime group.
4. **Services are isolated from the web tier.** A network-facing service never
   joins the web server's group, so a service compromise cannot read website
   content or any site credential, and a web compromise cannot reach a service
   identity.
5. **No world-readable secrets, ever.** Files default to `0640`, directories and
   executables to `0750`/`2750`. The "other" permission bit is denied.

## Credential ownership

| Credential | Owner:group | Mode | Who can read |
|---|---|---|---|
| Daemon / admin backend password | `root:` daemon group | `0600` | the daemon only |
| Per-site web credential | `root:` (web-cred group) | `0640` | the web user, via group |
| Per-service credential | `root:<service>` | `0640` | that one service, via a single-member group |

Each credential carries a sibling ownership descriptor that the deployment layer
treats as the source of truth, so a deploy can never silently re-own a service
credential to the web user. Credentials live under a directory that permits
traversal but not listing.

## Backend access control

The ValKey backend uses per-identity ACL users with scoped command grants.
Dangerous capabilities are denied to client identities — there is no access to
debugging commands (which can crash the server), no unbounded key-scanning, and
connection-management is limited to a client's own handshake and observability.
Each component authenticates as its own ACL user.

## Shared source and the web tier

Deployed framework, library, and theme source is owned by a dedicated
source-read group whose members are exactly the processes that load that code
(the web user and any in-process service consumer). It is **not** owned by a
credentials group, so source-read access never implies credential access.

Web roots are readable by the web user and writable only in the specific
directories that must accept uploads; executable content is blocked in those
directories. Every `.htaccess` is root-owned and web-readable (so the web server
never fails closed) and is set immutable so it cannot be overwritten by a
compromised web process.

## Threat model summary

- A compromise of the **web user** can read public framework source, the
  credentials of the sites it already serves, and web content — but no service
  identity, no daemon/admin credential, and no other component.
- A compromise of a **service** can read public framework source and its own
  credential — but no web content, no site credential, and no other service.
- A compromise that gains the **daemon/admin** credential is the high-value
  target and is held to the narrowest possible membership.

## Known limitations

- WordPress sites currently share a single web-user identity, so co-hosted sites
  can read each other's files. Per-site process-pool isolation is the planned
  hardening; until then, treat co-hosted sites as a shared trust boundary.

## Reporting a vulnerability

Please report security issues privately to the maintainer rather than opening a
public issue. We aim to acknowledge reports promptly and will coordinate
disclosure once a fix is available.
