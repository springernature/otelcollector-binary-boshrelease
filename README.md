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