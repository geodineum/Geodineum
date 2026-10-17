# Changelog

All notable changes to this project are documented here. The format follows Keep a Changelog.

## [0.2.0] — unreleased

### Breaking: the one topology

- The installer declares components by name on the one topology; the manifest `gnode:` block and a constellation-aware ACL policy replace the old registration.
- A new constellation asks for its name at install; an existing host keeps its own.
- Cross-site discovery is GNODE_TOPO_QUERY on the constellation key; GNODE_TENANT_DISCOVER is retired.
- Generic probe-gated heartbeat wrapper with units; the http probe accepts `http:<url>` and bare URLs.
- Registration recipes rewritten for the one topology.

