# otelcollector-binary-boshrelease

Simple Bosh release to deploy binary OpenTelemetry collector from upstream (https://github.com/open-telemetry/opentelemetry-collector-releases/releases), allowing end users to define the full configuration file.

# Release process

Blobs are stored in this repository as LFS objects!

## Creating and testing a release

In order to test and create a "non final" (dev) release, run:

```
# Update or sync blobs
./update-blobs.sh
# Create a dev release
bosh  create-release --force --tarball=/tmp/release.tgz
# Upload release to bosh director
bosh -e <bosh-env> upload-release /tmp/release.tgz
```

## Releasing a final version

Final versions are released by the GH Action workflow.
Please commit all changes and then push an annotated tag to the repository:

```
git tag -a v1.4 -m "my version 1.4"
```

## GitHub Credentials

`release-please` requires a GitHub token to access the GitHub API. You configure this token via
the `token` configuration option.

> [!WARNING]  
> If using GitHub Actions, you will need to specify a `token` for your workflows to run on
> Release Please's releases and PRs.

By default, Release Please uses the built-in `GITHUB_TOKEN` secret. However, all resources created
by `release-please` (release tag or release pull request) will not trigger future GitHub actions workflows,
and workflows normally triggered by `release.created` events will also not run.
From GitHub's
[docs](https://docs.github.com/en/actions/using-workflows/triggering-a-workflow#triggering-a-workflow-from-a-workflow):

> When you use the repository's `GITHUB_TOKEN` to perform tasks, events triggered by the `GITHUB_TOKEN`
> will not create a new workflow run. This prevents you from accidentally creating recursive workflow runs.

You will want to configure a GitHub Actions secret with a
[Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token)
if you want GitHub Actions CI checks to run on Release Please PRs.