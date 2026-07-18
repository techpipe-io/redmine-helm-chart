# redmine-helm-chart

Standalone Helm chart for the official `redmine:6.1.3-bookworm` image. It has no
any dependencies on any subcharts common-libraries.

## Design

The chart features:
- official redmine container image
- exact image tag, optional digest pinning, and explicit UID/GID `999` security contexts;
- `Recreate` rollout by default for a single RWO-backed instance;
- startup, readiness, and liveness probes;
- optional database wait and volume-permissions init containers;
- existing or chart-created PVCs;
- retained chart-created PVCs by default to protect data on uninstall;
- external PostgreSQL, MySQL, or SQL Server configuration;
- optional Ingress and Gateway API `HTTPRoute` exposure;
- optional HPA, PDB, NetworkPolicy, diagnostic mode, and mail receiver CronJob;
- startup migrations or an explicit Helm hook migration Job;
- validation for unsafe SQLite and multi-replica combinations.

Database migrations use the official image entrypoint and its documented
`REDMINE_NO_DB_MIGRATE` and `REDMINE_PLUGINS_MIGRATE` controls.

## Minimal installation

Default values create two 1 Gi PVCs for attachments and SQLite, skip custom
configuration/plugins/themes, and create a stable release-managed
`SECRET_KEY_BASE` Secret. A default `StorageClass` is the only cluster-side
requirement.

```bash

helm repo add searxng https://techpipe-io.github.io/redmine-helm-chart
helm repo update

helm upgrade --install redmine ./redmine \
  --namespace redmine \
  --create-namespace \
  --wait \
  --timeout 10m
```

For an ephemeral CI smoke test on a cluster without a dynamic volume
provisioner, disable both PVC mounts:

```bash
helm upgrade --install redmine ./redmine \
  --namespace redmine \
  --create-namespace \
  --wait \
  --timeout 10m \
  --set persistence.files.enabled=false \
  --set persistence.sqlite.enabled=false
```

The second form loses the SQLite database and attachments when the Pod is
recreated and must not be used for a real installation.

Install with an override file:

```bash
helm upgrade --install redmine ./redmine \
  --namespace redmine \
  --create-namespace \
  --wait \
  -f ./redmine/examples/values-first-upgrade.yaml \
  --timeout 10m
```

### Install with Helmwave

Copy [`examples/helmwave.yml`](examples/helmwave.yml) beside the chart and place your overrides in
`values.override.yaml`. The first major upgrade example intentionally disables
atomic cleanup because database changes are outside Helm rollback.

```bash
helmwave build
helmwave up
```

After a successful migration, use the regular release policy:

```yaml
atomic: true
cleanup_on_fail: true
wait: true
wait_for_jobs: true
timeout: 15m
```

## Secret management

When `secretKeyBase.existingSecret` is empty, the chart creates the Secret and
uses `lookup` to preserve its value across Helm upgrades. For migration or
production, an externally managed stable Secret can be supplied instead:


```bash
kubectl -n redmine create secret generic redmine-runtime \
  --from-literal=secret-key-base='replace-with-a-long-random-value' \
  --from-literal=database-password='replace-if-an-external-database-is-used'
```

```yaml
secretKeyBase:
  existingSecret: redmine-runtime
  key: secret-key-base
```

Changing `secret-key-base` invalidates existing sessions.

## Existing Docker volumes

Use `examples/values-first-upgrade.yaml` to attach these existing PVCs:

| Source volume | PVC | Mount in Redmine 6.1.3 |
|---|---|---|
| `/usr/src/redmine/files` | `redmine-files` | complete `files` directory |
| `/usr/src/redmine/sqlite` | `redmine-sqlite` | complete `sqlite` directory |
| `/usr/src/redmine/config` | `redmine-config` | only `configuration.yml` via `subPath` |
| `/usr/src/redmine/plugins` | `redmine-plugins` | disabled for the first core upgrade |
| `/usr/src/redmine/public` | `redmine-public` | disabled; custom paths must use `subPath` |

The chart deliberately rejects complete mounts over `/usr/src/redmine/config`
and `/usr/src/redmine/public`. Such mounts hide versioned core files, including
`config/routes.rb`, and reproduce errors such as a missing
`projects_context_menu_path` helper.

If the Docker named volumes have not yet become Kubernetes PVCs, provision and
populate them before installing this chart. A Helm chart cannot import a Docker
volume by itself.

## Migration modes

`migrations.mode=startup` is the default and best fit for the first migration
with a single replica and RWO storage. The official entrypoint runs
`db:migrate` before Puma starts.

`migrations.mode=job` creates a `pre-install,pre-upgrade` hook Job and sets
`REDMINE_NO_DB_MIGRATE=1` on the Deployment. Before an upgrade, scale the old
release to zero when SQLite or plugin migrations require the Job and old Pod to
mount the same RWO claim. Core migrations against an external database do not
mount application PVCs.

`migrations.mode=disabled` is intended for a separately controlled migration
pipeline.

Helm rollback does not roll back database migrations. For the first 5.1 to 6.1
upgrade use `atomic: false` and `cleanup_on_fail: false`, inspect any failure,
and restore the database/PVC snapshot if rollback is required. Re-enable atomic
upgrades only after the schema and plugins have been validated on 6.1.3.

## Recommended 5.x.x to 6.1.x sequence

1. Stop writes and back up the database, `files`, configuration, plugins, and
   custom themes.
2. Preserve the current session secret in `redmine-runtime`.
3. Install with one replica, `Recreate`, `migrations.mode=startup`, and plugins
   and public customizations disabled.
4. Verify login, attachments, projects, administration pages, and logs.
5. Check every plugin and theme against Redmine 6.1 and Rails 7.2, then enable
   their mounts and set `migrations.plugins=true` when plugin migrations are
   needed.
6. Prefer PostgreSQL for production. Keep SQLite at one replica and do not
   enable the mail receiver or autoscaling with it.

For MySQL, configure `transaction_isolation=READ-COMMITTED` at the database
server or provide a version-compatible `database.yml` as a single-file mount.
Redmine 6.1 requires PostgreSQL 14+, MySQL 8.0-8.4, or SQLite 3; upstream marks
SQLite as unsuitable for multi-user production.

The upstream upgrade guide requires a database and attachment backup, copying
only user configuration/customizations into the new release, and running core
and plugin migrations. It explicitly warns not to overwrite core settings files.

## Gateway API

The chart can attach an `HTTPRoute` to an existing Gateway. The Gateway API
CRDs and a compatible controller must already be installed.

```yaml
ingress:
  enabled: false

gatewayAPI:
  httpRoute:
    enabled: true
    parentRefs:
      - name: public-gateway
        namespace: gateway-system
        sectionName: https
    hostnames:
      - redmine.example.com
    rules:
      - matches:
          - path:
              type: PathPrefix
              value: /
        filters: []
        timeouts:
          request: 60s
          backendRequest: 55s
```

Each rule automatically receives a `backendRef` to the Redmine Service and its
configured `service.port`. The referenced Gateway listener must allow routes
from the Redmine namespace.



## Validation

```bash
helm lint ./redmine-helm-chart
helm template redmine ./redmine-helm-chart --namespace redmine
helm test redmine --namespace redmine
```

## Upstream references

- [Official Redmine image](https://hub.docker.com/_/redmine)
- [Official image entrypoint](https://github.com/docker-library/redmine/blob/master/docker-entrypoint.sh)
- [Redmine upgrade guide](https://www.redmine.org/projects/redmine/wiki/RedmineUpgrade)
- [Redmine requirements](https://www.redmine.org/projects/redmine/wiki/RedmineInstall)
