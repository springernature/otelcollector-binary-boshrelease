# otelcollector-binary-boshrelease

Simple Bosh release to deploy binary OpenTelemetry collector from [upstream](https://github.com/open-telemetry/opentelemetry-collector-releases/releases), allowing end users to define the full configuration file.

## Usage

Usage. See the `manifest` directory for an example of how to deploy it. Check the [Releases](https://github.com/springernature/otelcollector-binary-boshrelease/releases) for the changelog and installation references.

Normally this release will be included as a Bosh job in the [runtime-config](https://bosh.io/docs/runtime-config/) to get it deployed as an agent in all VMs (like *node-exporter*).

## Configuration

Parameters (see `jobs/otelcollector-bin/spec`):

```
  enabled:
    description: "Enable OTel Collector"
    default: true
  ingress.grpc.address:
    description: "Address to listen on to receive OTLP over gRPC, exposed as env var OTELCOL_GRPC_ADDR for configuration"
    default: 0.0.0.0
  ingress.grpc.port:
    description: "Port the collector is listening on to receive OTLP over gRPC, exposed as env var OTELCOL_GRPC_PORT for configuration"
    default: 4317
  ingress.grpc.tls.ca_cert:
    description: "CA root required for key/cert verification in gRPC ingress"
  ingress.grpc.tls.cert:
    description: "TLS server certificate for gRPC ingress"
  ingress.grpc.tls.key:
    description: "TLS server key for gRPC ingress"
  ingress.loggr-protocol:
    description: "Ingress protocol type for loggr-forwarder-agent job from loggregator-agent"
    default: otelcol
  otelcollector-bin.feature-gates:
    description: "Enable or disable additional features"
    example: ["gate1", "-gate2", "+gate3"]
    default: []
  otelcollector-bin.prom-jobs.enabled:
    description: "Autodiscover and setup other local prometheus targets"
    default: false
  otelcollector-bin.prom-jobs.glob-pattern:
    description: "Glob pattern to auto-discover local targets from other jobs"
    default: "/var/vcap/jobs/*/config/prom_scraper_config.yml"
  otelcollector-bin.prom-jobs.receiver-name:
    description: "Name for the prometheus instance to get included in the configuration file with all local targets. This name will need to get included in a pipeline"
    default: "boshjobs"
  otelcollector-bin.healthcheck-endpoint:
    description: "Health-check endpoint, exposed as env var OTELCOL_HEALTHCHECK for configuration"
    default: "127.0.0.1:13133"
  otelcollector-bin.setcap:
    description: List of capabilities to pass ot setcap command. See setcap manual (https://www.man7.org/linux/man-pages/man8/setcap.8.html)
    default:
    - cap_net_bind_service=+ep
  otelcollector-bin.env:
    description: Key/value hash of environment variables.
    default: {}
  otelcollector-bin.config:
    default: |
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: ${env:OTELCOL_GRPC_ADDR}:${env:OTELCOL_GRPC_PORT}

        # Collect own metrics
        prometheus:
          config:
            scrape_configs:
            - job_name: 'otel-collector'
              scrape_interval: 30s
              static_configs:
              - targets: ['127.0.0.1:8881']

        hostmetrics:
          collection_interval: 60s
          scrapers:
            cpu:
            disk:
            filesystem:
            load:
            memory:
            network:
            process:
            processes:
            paging:

      processors:
        batch:

      exporters:
        debug:
          verbosity: basic

      service:
        extensions: []
        logs:
          level: INFO
        metrics:
          level: basic
          address: 127.0.0.1:8881
        pipelines:
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [debug]
          logs:
            receivers: [otlp]
            processors: [batch]
            exporters: [debug]
          metrics:
            receivers: [otlp, hostmetrics, prometheus]
            processors: [batch]
            exporters: [debug]
```

# Mimir jobs

Two jobs manage Mimir with [mimirtool](https://grafana.com/docs/mimir/latest/manage/tools/mimirtool/).
Neither runs a long-running process (empty `monit`). They work the same way:

* **post-start**: runs on every start or deploy of the instance.
* **errand**: runs the same logic on demand. If the job is colocated in an instance group, run
  `bosh -d <dep> run-errand mimir-rules` or `bosh -d <dep> run-errand mimir-alertmanager`.
* **bootstrap only**: by default (`bootstrap_only: true`) they only run on the bootstrap
  instance of the instance group. The other instances log "not bootstrap" and skip.
* Entries (`rulesets` / `configs`) are hashes keyed by id, so separate ops files can add or
  replace entries without indexes. They run one after another, sorted by id, with retries and
  backoff (5s, 10s, 20s, ...) per mimirtool API call.
* If one entry fails, it is reported and **the others continue**. At the end, the job exits
  non-zero only if `fail_on_error: true` and any entry failed.
* `enabled: false` on an entry skips it. It does **not** delete anything in Mimir.
* Configuration errors (missing namespace, duplicated namespace or tenant, invalid modes...)
  are validated at render time, so the deploy fails before touching any VM.
* Logs go to `/var/vcap/sys/log/<job>/<job>.log`. API keys and receiver credentials are never printed.

## mimir-rules job

Uploads rule sets (recording rules, alerting rules or both). Each rule set has its own namespace,
tenant, mode and groups, and is rendered to its own rules file. Before uploading, each rule set
runs `mimirtool rules check` and `mimirtool rules lint --dry-run` (report only, never rewrites).

| Property | Description | Default |
|---|---|---|
| `mimir-rules.enabled` | Enable rules sync | `true` |
| `mimir-rules.address` | Default Mimir base URL for all rule sets (mimirtool calls `<address>/prometheus/config/v1/rules`) | |
| `mimir-rules.tenant_id` | Default tenant id (`X-Scope-OrgID`) for all rule sets | |
| `mimir-rules.auth.user` | Default optional basic auth user (`MIMIR_API_USER`) | |
| `mimir-rules.auth.key` | Default optional API key / password (`MIMIR_API_KEY`) | |
| `mimir-rules.sync_mode` | Default mode for all rule sets (see below) | `load` |
| `mimir-rules.rulesets` | Hash of rule sets keyed by id (see below) | `{}` |
| `mimir-rules.rules` | Legacy (v4.2.0): one rule set `{namespace, groups}`, YAML string or hash. Treated as rule set `default` | |
| `mimir-rules.fail_on_error` | If true, the job fails (and the deploy) when any rule set failed | `true` |
| `mimir-rules.bootstrap_only` | Only run on the bootstrap instance of the instance group | `true` |
| `mimir-rules.retries` | Number of attempts per API call before giving up | `5` |

Rule set fields:

| Field | Required | Default | Notes |
|---|---|---|---|
| `namespace` | yes | | Non-empty. Unique per `(address, tenant_id)` |
| `groups` | yes | | mimirtool/Prometheus groups, passed through as-is (`interval`, `source_tenants`, `evaluation_delay`, `limit`, `record`/`alert` rules, `for`, `keep_firing_for`, `labels`, `annotations`) |
| `tenant_id` | no | `mimir-rules.tenant_id` | |
| `address` | no | `mimir-rules.address` | |
| `sync_mode` | no | `mimir-rules.sync_mode` | `load`, `sync`, `delete-namespace` or `delete-groups` |
| `enabled` | no | `true` | `false` skips the rule set, nothing is deleted |
| `auth.user` / `auth.key` | no | `mimir-rules.auth.*` | Per rule set credentials |

Modes:

* `load`: creates or updates the groups of the rule set. Groups removed from the manifest stay in Mimir.
* `sync`: idempotent. Creates, updates and **prunes groups removed from the manifest**. It is always
  scoped with `--namespaces=<namespace>`, so it never touches namespaces it doesn't own.
* `delete-namespace`: deletes the rule set namespace.
* `delete-groups`: deletes only the groups listed in the rule set.

Recording rules and alerts in separate ops files, each adding a rule set:

```yaml
# 60-recording-rules.yml
- type: replace
  path: /instance_groups/name=otelcollector/jobs/name=mimir-rules/properties/mimir-rules?/rulesets?/recording?
  value:
    namespace: snpaas-key-metrics
    groups:
    - name: key-metrics
      interval: 1m
      rules:
      - record: job:up:sum
        expr: sum by (job) (up)

# 61-alerting-rules.yml
- type: replace
  path: /instance_groups/name=otelcollector/jobs/name=mimir-rules/properties/mimir-rules?/rulesets?/alerts-bosh?
  value:
    namespace: snpaas-alerts-bosh
    sync_mode: sync
    groups:
    - name: bosh
      rules:
      - alert: BoshJobDown
        expr: up{job="bosh"} == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} is down ({{ $value | humanizePercentage }})"
```

with the job defined once (see `manifest/deployment-add-mimir-rules.yml`):

```yaml
- name: mimir-rules
  release: otelcollector-binary
  properties:
    mimir-rules:
      address: ((mimir_api))
      tenant_id: ((management_tenant))
      sync_mode: sync
```

### Deleting a namespace

Removing a rule set from the manifest only **stops managing** its namespace; the rules stay in Mimir.
To delete it:

1. Set `sync_mode: delete-namespace` on the rule set (or `delete-groups` to delete only its groups) and deploy once.
2. Remove the rule set from the manifest and deploy again. Otherwise every deploy deletes it again.

### Upgrading from v4.2.0

No change is needed. `mimir-rules.rules` keeps working as rule set `default`, inheriting the top-level
`address`, `tenant_id`, `auth` and `sync_mode`. It can be combined with `rulesets`, but not with
`rulesets.default`.

## mimir-alertmanager job

Uploads the Alertmanager configuration (and its templates) for one or more tenants. Mimir holds one
Alertmanager configuration per tenant, so `tenant_id` must be unique per address across the enabled configs.

| Property | Description | Default |
|---|---|---|
| `mimir-alertmanager.enabled` | Enable Alertmanager configuration upload | `true` |
| `mimir-alertmanager.address` | Default Mimir base URL for all configs | |
| `mimir-alertmanager.auth.user` | Default optional basic auth user (`MIMIR_API_USER`) | |
| `mimir-alertmanager.auth.key` | Default optional API key / password (`MIMIR_API_KEY`) | |
| `mimir-alertmanager.configs` | Hash of configs keyed by id (see below) | `{}` |
| `mimir-alertmanager.fail_on_error` | If true, the job fails (and the deploy) when any config failed | `false` |
| `mimir-alertmanager.bootstrap_only` | Only run on the bootstrap instance of the instance group | `true` |
| `mimir-alertmanager.retries` | Number of attempts per API call before giving up | `5` |

Config fields:

| Field | Required | Default | Notes |
|---|---|---|---|
| `tenant_id` | yes | | Unique per address |
| `mode` | no | `load` | `load`: `mimirtool alertmanager verify` and then `load` (replaces the full config, idempotent). `delete`: deletes the tenant config |
| `config` | yes (`load`) | | `alertmanager.yml` as a hash (ops files can patch it) or a YAML string |
| `templates` | no | `{}` | Template file name => content, passed byte-for-byte |
| `address` | no | `mimir-alertmanager.address` | |
| `enabled` | no | `true` | `false` skips the config, nothing is deleted |
| `auth.user` / `auth.key` | no | `mimir-alertmanager.auth.*` | Per config credentials |

Example with receiver credentials from CredHub (see `manifest/deployment-add-mimir-alertmanager.yml`):

```yaml
- name: mimir-alertmanager
  release: otelcollector-binary
  properties:
    mimir-alertmanager:
      address: ((mimir_api))
      configs:
        management:
          tenant_id: ((management_tenant))
          config:
            route:
              receiver: slack
              group_by: [alertname]
            receivers:
            - name: slack
              slack_configs:
              - api_url: ((slack_webhook_url))   # CredHub
                title: '{{ template "sn.title" . }}'
          templates:
            sn.tmpl: |
              {{ define "sn.title" }}[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}{{ end }}
```

To delete a tenant configuration, set `mode: delete` on the config, deploy once, then remove it from the manifest.

The rendered configuration files are written to `/var/vcap/data/mimir-alertmanager/` only while the job
runs, and are removed afterwards because they contain receiver credentials.

## Rendering notes

* Rules, Alertmanager configs and templates are rendered from parsed data (`YAML.dump`) and passed
  base64-encoded to the scripts, so Go templates (`{{ $labels.x }}`, `{{ $value }}`), `%`, `$` and YAML
  special characters reach Mimir unchanged (covered by the specs in `spec/`).
* BOSH `((var))` interpolation happens before rendering. Rules or templates that contain a literal
  `((` / `))` are **not supported**.
* Empty groups (`rules: []`) are allowed.

## Mimir prerequisites

* Rules that use `source_tenants` need `-tenant-federation.enabled=true` and
  `-ruler.tenant-federation.enabled=true`.
* The Alertmanager must be enabled for the target tenant (`-alertmanager.*`, and
  `alertmanager_receivers_firewall_*` if it is used).
* The API credentials need ruler and alertmanager write permissions.

## Template tests

```
bundle install
bundle exec rspec
```

# Updating the collector binary

To update the collector deployed by this release:

1. In `packages/otelcollector-linux-amd64/spec` file, update the version of the tar file under `files` section and also the commented URL. You can use files with 2 extensions: `.bin` and `.tgz`.
2. Run `./update-blobs.sh`. This will read the commented URL from the previous file, and create the file specified in `files` section. This file will become a *blob* which will be uploaded/synced to the `blobstore`.
3. Upload the release to a Bosh director and test it (see below).
4. Push all blob and package resources to the repository. Check if the pipeline works and check if the generated package (bosh release) works.
5. Create a GH Release which includes a Bosh final Release artifact by triggering the pipeline with an annotated tag (see below).

# Release process

Blobs are stored in this repository as LFS objects!. Commit all blobs to `blobstore`.

## Creating and testing a non-final release

In order to test and create a "non final" (dev) release, run:

```
# Download, update or sync blobs
./update-blobs.sh
# Create a dev release
bosh  create-release --force --tarball=/tmp/release.tgz
# Upload dev release to bosh director (for testing)
bosh -e <bosh-env> upload-release /tmp/release.tgz
```

## Releasing a final version

Final versions are released by the GH Action workflow.
Please commit all changes (and blobs) and then push an annotated tag to the repository.

```
# git add config
# git add packages
# git add blobs*
# git status .
On branch main
Your branch is up to date with 'origin/main'.

Changes to be committed:
  (use "git restore --staged <file>..." to unstage)
        new file:   blobs/otelcollector-linux-amd64/otelcol_contrib_0.121.0_linux_amd64.bin
        new file:   blobstore/a632163d-15d8-41c6-4871-e45ce2153166
        modified:   config/blobs.yml
        modified:   packages/otelcollector-linux-amd64/spec

# git commit -m "update otelcol"
```

> [!WARNING]  
> Do not commit `releases` and `.final_builds` resources created when doing a final release manually. Those are commit by the pipeline

```
git tag -a v<version> -m "<comment used to commit the resources created by bosh>"
git push --tags
```

## About GitHub Credentials

Trigger a workflow with annotated tags requires a GitHub token to access the GitHub API. You configure this token via the `token` configuration option.

> [!WARNING]  
> If using GitHub Actions, you will need to specify a `token` for your workflows to run on
> tags, releases and PRs.

By default, it uses the built-in `GITHUB_TOKEN` secret. However, all resources created
by workflows (release tag or release pull request) will not trigger future GitHub actions workflows, and workflows normally triggered by `release.created` events will also not run.
From GitHub's [docs](https://docs.github.com/en/actions/using-workflows/triggering-a-workflow#triggering-a-workflow-from-a-workflow):

> When you use the repository's `GITHUB_TOKEN` to perform tasks, events triggered by the `GITHUB_TOKEN`
> will not create a new workflow run. This prevents you from accidentally creating recursive workflow runs.

You will want to configure a GitHub Actions secret with a
[Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token)
if you want GitHub Actions CI checks to run on Release Please PRs.

# License

MIT License

Copyright (c) 2024 Springer Nature Observabilty Engineering

Jose Riguera