# otelcollector-binary-boshrelease

Simple Bosh release to deploy binary OpenTelemetry collector from upstream (https://github.com/open-telemetry/opentelemetry-collector-releases/releases), allowing end users to define the full configuration file.

# Creating and using a release:

In order to test and create a "non final" (dev) release, run:

```
# Update or sync blobs
./update-blobs.sh
# Create a dev release
bosh  create-release --force --tarball=/tmp/release.tgz
# Upload release to bosh director
bosh -e <bosh-env> upload-release /tmp/release.tgz
```
