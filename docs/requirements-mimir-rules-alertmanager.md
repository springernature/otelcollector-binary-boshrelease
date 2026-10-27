# Requirements: multiple rule sets and Alertmanager config in Mimir

Status: draft
Release: `otelcollector-binary` (base v4.2.0)
Consumer: `ee-cf-gcp[-test]/bosh-deployments/otelcollector`

## Background

Version 4.2.0 ships the `mimir-rules` job. It uploads exactly one rules file
(`{namespace, groups}`) to exactly one tenant. This is enough for the SNPaaS
recording rules (`60-recording-rules.yml`). It is not enough to move the
Prometheus alerts from `springernature-custom-alerts-dashboards` (used by
`prometheus-proxy`) into Mimir, for two reasons:

1. Alerts and recording rules should live in separate namespaces, and possibly
   in separate tenants. Then each one can be synced, pruned or deleted
   without touching the other.
2. Alerts are useless without an Alertmanager configuration for the tenant
   that evaluates them. The release cannot upload one.

## Goals

- G1: Upload any number of rule sets. Each rule set has its own namespace,
  tenant, sync mode and groups, and may hold recording rules, alerting rules,
  or both.
- G2: Let separate ops files add rule sets (e.g. `60-recording-rules.yml`,
  `61-alerting-rules.yml`) without overwriting each other.
- G3: Upload and sync the Alertmanager configuration (and its templates) for
  one or more tenants.
- G4: Keep backwards compatibility with the v4.2.0 `mimir-rules` properties.
- G5: Never write secrets (API keys, receiver credentials) to logs.

## Non-goals

- Templating alert thresholds inside the release. Rules are passed as literal
  PromQL. Any parameters are resolved in the manifest (ops files or vars).
- Managing Mimir runtime/limits configuration (e.g. enabling ruler tenant
  federation). This is a documented prerequisite only.
- Grafana-managed alerts.

---

## R1 - `mimir-rules`: multiple rule sets

### R1.1 New property `mimir-rules.rulesets`

This is a hash keyed by an arbitrary rule set id. It is a hash, not an array,
so that ops files can add or replace entries by key without needing an index:

```yaml
mimir-rules:
  address: ((mimir_api))          # default for all rulesets
  tenant_id: ((management_tenant)) # default for all rulesets
  sync_mode: sync                  # default for all rulesets
  rulesets:
    recording:
      namespace: snpaas-key-metrics
      groups: [ ... ]
    alerts-bosh:
      namespace: snpaas-alerts-bosh
      tenant_id: ((management_tenant))   # optional override
      sync_mode: sync                    # optional override
      enabled: true                      # optional, default true
      groups: [ ... ]
```

Each rule set accepts these fields:

| Field        | Required | Default                       | Notes |
|--------------|----------|-------------------------------|-------|
| `namespace`  | yes      | -                             | Must be non-empty. Must be unique per `(address, tenant_id)`. |
| `groups`     | yes      | -                             | mimirtool group format. Pass through as-is, including `interval`, `source_tenants`, `evaluation_delay`, `limit`. |
| `tenant_id`  | no       | `mimir-rules.tenant_id`       | |
| `address`    | no       | `mimir-rules.address`         | |
| `sync_mode`  | no       | `mimir-rules.sync_mode`       | `load`, `sync`, `delete-namespace` or `delete-groups` (same meaning as in v4.2.0). |
| `enabled`    | no       | `true`                        | `false` skips the rule set completely. It does **not** delete anything. |
| `auth.user` / `auth.key` | no | `mimir-rules.auth.*`    | Per-rule-set credentials. |

- Each group may contain `record:` rules, `alert:` rules, or a mix. The
  release must not restrict this. Alert rules must keep `for`,
  `keep_firing_for`, `labels` and `annotations` (including `{{ $labels.x }}` /
  `{{ $value }}` templates) **byte-for-byte**. See R4.1.
- Each rule set must be rendered to its own file,
  `config/rules/<ruleset-id>.yaml`.

### R1.2 Backwards compatibility

- If `mimir-rules.rules` (the v4.2.0 property) is set, treat it as a rule set
  with the id `default`, inheriting the top-level `tenant_id`, `address` and
  `sync_mode`.
- If both `rules` and `rulesets.default` are set, rendering fails with a clear
  error.
- If neither is set and `enabled: true`, rendering fails, as it does today.

### R1.3 Validation at render time (ERB) - fail the deploy early

- Every rule set has a non-empty `namespace` and a `groups` array.
- No two enabled rule sets share the same `(address, tenant_id, namespace)`.

### R1.4 Validation at run time

- For each rule set, run `mimirtool rules check` and `mimirtool rules lint`
  (lint in dry-run mode: report only, never rewrite).
- If one rule set fails, report it and **continue with the others**. When
  `fail_on_error=true`, the job exits non-zero at the end if any rule set
  failed.

### R1.5 Sync semantics

- `sync` is always scoped with `--namespaces=<namespace>` per rule set (as in
  v4.2.0). A rule set must never prune namespaces it doesn't own.
- Rule sets run one after another in a deterministic order (sorted by id).
  Retries and backoff apply per rule set.
- Removing a namespace means setting `sync_mode: delete-namespace` on that
  rule set and deploying once. The docs must explain this flow, because
  removing the entry from the manifest only stops managing the namespace; it
  does not delete it.

### R1.6 Errand

- `bosh run-errand mimir-rules` re-syncs every enabled rule set.


---

## R2 - New job `mimir-alertmanager`

This is a separate job, so that it can be enabled, colocated and failed
independently of the rules job. It uses the same packages
(`mimirtool-linux-amd64`, `bosh-helpers`) and the same lifecycle: post-start
(bootstrap only by default) plus an errand.

### R2.1 Properties

```yaml
mimir-alertmanager:
  enabled: true
  address: ((mimir_api))
  bootstrap_only: true
  fail_on_error: false
  retries: 5
  configs:                      # hash keyed by id, like rulesets
    management:
      tenant_id: ((management_tenant))
      mode: load                # load | delete
      config:                   # alertmanager.yml as a hash or a YAML string
        route: { ... }
        receivers: [ ... ]
        inhibit_rules: [ ... ]
      templates:                # optional: file name -> content
        sn.tmpl: |
          {{ define "sn.title" }}...{{ end }}
      auth: { user: ..., key: ... }   # optional
```

- `config` takes a hash (so ops files can patch it) or a raw YAML string. It
  is rendered to `config/alertmanager/<id>/alertmanager.yaml`. Each template
  is rendered to `config/alertmanager/<id>/templates/<name>`.
- `tenant_id` must be unique across the enabled configs. Mimir holds one
  Alertmanager config per tenant.
- Go-template syntax (`{{ ... }}`) in `config` and `templates` must reach
  Mimir unchanged (see R4.1).

### R2.2 Behaviour

- `mode: load` runs
  `mimirtool alertmanager verify <file>` and then
  `mimirtool alertmanager load --address --id <file> <templates...>`.
  This is idempotent: the full config is replaced on each run.
- `mode: delete` runs `mimirtool alertmanager delete --address --id`.


### R2.3 Secrets

- Receiver credentials (Slack webhook URLs, PagerDuty/OpsGenie keys, SMTP
  passwords) come from the manifest as `((credhub_vars))`.


### R2.4 Errand

- `bosh run-errand mimir-alertmanager` re-applies all enabled configs.

---

## R4 - Rendering and escaping

- R4.1 **Go templates must survive ERB and YAML.** Strings that contain
  `{{ }}`, `$labels`, `%`, or YAML-special characters must reach Mimir
  unchanged. Render with `YAML.dump` from parsed data (not string
  interpolation), and add a spec test that round-trips an alert annotation
  such as `"{{ $labels.instance }} at {{ $value | humanizePercentage }}"`.
- R4.2 BOSH `((var))` interpolation happens before ERB. Rules that contain
  literal `((`/`))` are not supported, and the docs must say so.
- R4.3 Empty groups (`rules: []`) are allowed and render as valid YAML.

---

## R6 - Documentation

- README examples:
  - Recording rules and alerts in separate ops files, each adding to
    `rulesets`.
  - Alertmanager config with a receiver whose credentials come from CredHub.
  - How to delete a namespace or config (the `delete-namespace` /
    `mode: delete` flow).
- Mimir prerequisites:
  - Rules that use `source_tenants` need
    `-tenant-federation.enabled=true` and
    `-ruler.tenant-federation.enabled=true`.
  - The Alertmanager must be enabled for the target tenant
    (`-alertmanager.*`, `alertmanager_receivers_firewall_*` if it is used).
  - The API credentials need ruler and alertmanager write permissions.
- Upgrade notes from v4.2.0: no change is needed. `rules` keeps working as
  rule set `default`.

