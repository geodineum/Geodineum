# Geodineum CLI — Quick Reference (Ch.1)

One CLI for everything. Installed at `/usr/local/bin/geodineum` (alias: `gcli`).

---

## Site Management

```bash
sudo geodineum new site example.com --theme gcube --env testing
geodineum info example_site                  # credentials, paths, connection details
geodineum list                                 # all registered sites
geodineum list --json                          # machine-readable output
sudo geodineum register example_site         # register existing site (ACL + streams)
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
geodineum status                               # ecosystem health check
geodineum status --verbose                     # all checks (not just failures)
geodineum status --site example_site         # single site check
sudo geodineum status --fix                    # attempt to fix detected issues
geodineum logs -f                              # follow daemon logs (real-time)
geodineum logs -n 100                          # last 100 lines
geodineum logs --service comms                 # COMMS daemon logs
geodineum logs --service valkey                # ValKey logs
```

## Service Lifecycle

```bash
sudo geodineum update-service example_site --express  # re-scan capabilities
sudo geodineum deregister old_service --dry-run         # preview removal
sudo geodineum deregister old_service --remove-acl --force  # full removal
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
| `innovagent.net` | `example_site` |
| `staging.example.com` | `staging_example_com` |
| `my-app.example.org` | `my_app_example_org` |
