# CONTRACTS

Canonical, inspectable contracts and interfaces for every Geodineum component
and moving part — so any operator, adopter, or auditor can see exactly what each
piece promises and expects, without reading the implementation.

A contract here defines the **stable surface**: ownership/permission invariants,
wire formats, command names and fields, stream layouts, and the guarantees each
component upholds. Implementation may change; the contract is what others build
against.

## Index

| Contract | Scope |
|---|---|
| [NODE_ONBOARDING.md](NODE_ONBOARDING.md) | Joining a **machine** (server, workstation, laptop, GPU box) to a constellation end-to-end: get the bundle, run the join, set exposure, verify, and the intermittent/reconnect model. Agent twin: `NODE_ONBOARDING.scn.md`. |
| [REGISTRATION.md](REGISTRATION.md) | Registering, checking and deregistering a **node**, the **ecosystem components**, a **site**, a **service** (daemon or headless app) and a **non-Geodineum service** on the one topology: exact commands, what is written, how health works, common refusals. Agent twin: `REGISTRATION.scn.md`. |
| [SERVICE_ONBOARDING.md](SERVICE_ONBOARDING.md) | Bringing a **service** (workload) into the mesh: registration, ValKey ACL identity, grants, and the permission layers. Agent twin: `SERVICE_ONBOARDING.scn.md`. |
| [permission-model.md](permission-model.md) | Ownership, group access classes, and the credential model — who owns and reads what, and what must restart when group membership changes. |
| [receipt-stream.md](receipt-stream.md) | The signed record of a command's outcome on `{site}:gnode:receipts:{env}`: producers, wire fields, the exact signed bytes, the key registry, retention and the shared test vectors. Agent twin: `receipt-stream.scn.md`. |
| [README_STYLE.md](README_STYLE.md) | The documentation standard every repo's `README.md` follows — section order, honesty/anti-drift rules, and the mandatory author/support/disclaimer/license blocks. |

## Conventions
- **Code wins.** If a contract disagrees with the running system, the system is
  authoritative — reconcile the contract to reality.
- One contract per component or concern; keep them minimal and verifiable.
