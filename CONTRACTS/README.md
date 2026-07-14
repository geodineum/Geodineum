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
| [permission-model.md](permission-model.md) | Ownership, group access classes, and the credential model — who owns and reads what, and what must restart when group membership changes. |
| [README_STYLE.md](README_STYLE.md) | The documentation standard every repo's `README.md` follows — section order, honesty/anti-drift rules, and the mandatory author/support/disclaimer/license blocks. |

## Conventions
- **Code wins.** If a contract disagrees with the running system, the system is
  authoritative — reconcile the contract to reality.
- One contract per component or concern; keep them minimal and verifiable.
