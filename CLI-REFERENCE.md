# Geodineum CLI — Quick Reference (Ch.1)

One CLI for everything. Installed at `/usr/local/bin/geodineum` (alias: `gcli`).

---

## Service Onboarding (taxonomy)

```bash
sudo geodineum register                        # asks: NEW (a wired skeleton) or INTEGRATE (scan existing code)
sudo geodineum register example.com --new website-static --env production
sudo geodineum register app.example.com --new webapp-gcore --env production  # public PHP app on gCore, no WordPress
sudo geodineum register worker1 --new daemon --lang python --env production --yes
sudo geodineum register ml_api --new daemon --env production --node worker-node-1  # on the master; then --worker on the node
sudo geodineum register /srv/existing-app --env production                  # integrate
geodineum register --matrix                    # the types and what each sets up
sudo geodineum credential add --service ml_api --auth '<printed>' --group ml_api  # worker side of --node
```

## Site Management

```bash
sudo geodineum register example.com --new website-wp --theme gcube --env testing
sudo geodineum status example_site             # the site: shape, placements, health, intent, this host's files
sudo geodineum register /var/www/<domain>          # integrate an existing site
```

## WordPress Admin

```bash
geodineum wp example_site admin list         # list administrators
sudo geodineum wp example_site admin reset   # reset admin password (prints new one)
geodineum wp example_site theme status        # active theme
geodineum wp example_site cache flush         # flush all caches
geodineum wp example_site plugin list         # list plugins
geodineum wp example_site option get blogname # get any WP option
geodineum wp example_site <any wp-cli args>   # full wp-cli passthrough
```

## Environment & Access Control

```bash
geodineum env show example_site              # environment, viewkey, gate status
geodineum env viewkey example_site           # show viewkey
geodineum env viewkey example_site --regenerate  # generate new viewkey
sudo geodineum env set example_site production   # switch DTAP environment
```

## Configuration (ValKey-resident)

```bash
geodineum config get example_site default_ttl    # get a config value
sudo geodineum config set example_site default_ttl 7200  # set a value
geodineum config list example_site               # list all config
sudo geodineum config import example_site        # import from service files
```

## Ecosystem Updates

```bash
sudo geodineum update                          # pull + rebuild + reload ALL components
sudo geodineum update --component gcore        # update single component
sudo geodineum update --skip-build             # pull only, no rebuild
```

## Health & Monitoring

```bash
sudo geodineum status                                   # every constellation this node serves
sudo geodineum status example_site                    # one service, site, node or component
sudo geodineum status --json                            # one JSON object per constellation per line
geodineum status comms                                  # a component's own status (gflow, gschedule, bak, geodeploy, ...)
geodineum status --config --verbose                     # this host's configuration health, all checks
sudo geodineum status --config --fix                    # and fix what it can
sudo geodineum status --visitors [example_site]       # visitor counts today/7d/30d (beacon-fed)
geodineum logs -f                              # follow daemon logs (real-time)
geodineum logs -n 100                          # last 100 lines
geodineum logs --service comms                 # COMMS daemon logs
geodineum logs --service valkey                # ValKey logs
```

## Service Lifecycle

```bash
sudo geodineum register /var/www/example.site  # register again: refresh after manifest changes
sudo geodineum deregister old_service --dry-run         # preview removal
sudo geodineum deregister old_service --purge-data --force  # remove it and its data
```

## Nodes and Constellations

```bash
sudo ./geodineum constellation new mynet --components gnode-daemon --yes         # fresh machine
sudo geodineum node add worker1 203.0.113.50:51820 --tier compute                  # on the master
sudo geodineum node remove worker1                                                 # on the master
```

## Security & Maintenance

```bash
sudo geodineum harden                          # deploy web-deny rules
sudo geodineum backup                          # snapshot ValKey data
geodineum schema list                          # list config schemas
geodineum schema show example_site           # inspect a schema
```

## Install / Uninstall

```bash
sudo geodineum install --site example.com      # install + deploy site
geodineum uninstall                            # dry-run preview
sudo geodineum uninstall --commit --keep-data --keep-users  # uninstall (preserve site)
```

---

## System Services

```bash
sudo systemctl restart gnode-daemon            # restart gNode
sudo systemctl restart geodineum-comms         # restart COMMS
sudo systemctl status gnode-daemon             # check daemon status
sudo journalctl -u gnode-daemon -f             # follow daemon journal
```

---

## Site ID Convention

Site IDs are derived from domain names: dots and hyphens become underscores.

| Domain | Site ID |
|---|---|
| `example.com` | `example_com` |
| `staging.example.com` | `staging_example_com` |
| `my-app.example.org` | `my_app_example_org` |
