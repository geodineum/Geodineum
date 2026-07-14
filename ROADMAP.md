# Geodineum Roadmap

What is on our plate. If you want to contribute, pick something from here,
fork, and open a pull request; we review every PR. Items closer to the wire
contract get the most scrutiny.

## In progress

- **Read/write-split ValKey replica tier.** Headless and full constellation
  nodes ship today; a worker with a local read replica (writes forwarded to the
  master) is the next tier. The `--deploy-tier replica` flag exists and is
  marked experimental until the split lands.
- **Per-domain mail deliverability.** Sites currently send through one
  SPF-verified sender; per-domain SPF/DKIM/DMARC provisioning at install time
  is the durable answer.

## Planned

- **`config.defaults` NX-seeding.** The orchestrator should seed a manifest's
  declared config defaults into ValKey at install time (SET NX, never
  clobbering operator values).
- **Per-manifest topology tier.** Services register on the 30-D service tier
  implicitly; `topology.tier` should be a manifest field.
- **Selective per-service backup.** The RDB snapshot is wholesale; a service's
  `backup.*` manifest entries should drive selective dump/restore.
- **Distribution coverage.** The install → uninstall → reinstall cycle is
  validated on Ubuntu 22.04; Debian 12 and other systemd distributions need the
  same treatment.
- **SMTP configuration at deploy time.** The installer should prompt for and
  validate a site's outbound mail settings instead of leaving the channel
  half-configured until first use.

## Under consideration

- **Topology visualizer, second iteration.** The wp-admin 3D viewer is hidden
  behind the operator console for now; it needs richer interaction and real
  analytical value before it returns as a default surface.
- **Inbound gateways for COMMS.** Outbound email/Telegram/SMS ship today;
  inbound (email-to-post and friends) returns once a hardened gateway design
  exists.

## How to propose something new

Open an issue describing the problem before the PR. Wire-contract changes
(stream field names, manifest schema, ACL grant shapes) can be proposed but
face intense scrutiny; contract changes must update both `CONTRACT.md` and
`CONTRACT.scn.md` in the affected component in the same commit.
