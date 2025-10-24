# Release

Semian releases are automated by GitHub Actions (for the repo) and Shipit (for RubyGems).

## Creating a Release

### Trigger Release

Navigate to the [Create Release](https://github.com/Shopify/semian/actions/workflows/create-release.yml) GitHub Action and trigger a new workflow. You will be asked if your release is a major, minor, or patch release. For more info, see [Manually running a workflow](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).

### Confirming Changes

The workflow generates a PR with changes to `lib/semian/version.rb`, `Gemfile.lock`, and `CHANGELOG.md`. You can amend the PR to make changes to `CHANGELOG.md`. After approving the changes, merge the PR to continue the workflow.

## Verify GitHub Release

After the workflow executes, your release should be at the top of Semian's [Release list](https://github.com/Shopify/semian/releases).

## Verify RubyGems release

- After detecting a new version tag from the GitHub workflow, Shipit should kick off a build and release it
- Check [RubyGems](https://rubygems.org/gems/semian)
