# =============================================================================
# geodeploy.yaml — Deploy descriptor for {{COMPONENT_NAME}}
# =============================================================================
# Declares how this component is deployed by the geodeploy orchestrator.
# See: Geodineum/lib/geodeploy.sh for action implementations.
#
# runtime.owner:  File owner (deploy user who runs git pull)
# runtime.group:  File group (runtime user reads via group)
# runtime.service: systemd service to restart on build
# triggers:       Match changed files → run actions
# dirty-tree:     How to handle uncommitted local changes
# =============================================================================

runtime:
  owner: august
  group: {{GROUP}}             # gnode (daemon) | www-data (PHP)
  # service: {{SERVICE_NAME}} # systemd unit name (if applicable)

triggers:
  - match: "{{MATCH_PATTERN}}"
    actions: [{{ACTIONS}}]

# build:
#   type: cargo                # cargo | composer | npm
#   working_dir: .             # relative to repo root
#   command: ""                # custom build command (overrides type)

dirty-tree:
  strategy: stash              # stash | skip | force
