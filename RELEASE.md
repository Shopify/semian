# Release

Semian releases are automated by GitHub Actions (for the repo) and Shipit (for RubyGems).

## Creating a Release

### Trigger Release

Navigate to the [Release](https://github.com/Shopify/semian/actions/workflows/release.yml) GitHub Action and trigger a new workflow. You will be asked if your release is a major, minor, or patch release. For more info, see [Manually running a workflow](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).

### Confirming Changes

The workflow generate changes to `lib/semian/version.rb`, `Gemfile.lock`, and `CHANGELOG.md`. Visit the workflow run to preview and confirm the changes.

![1. Review the new version and commit changes
2. Approve the CONFIRM CHANGES workflow](https://github.com/user-attachments/assets/de113ad1-1849-4c56-b46f-49ed414afc96)
![REVIEW CHANGES](https://github.com/user-attachments/assets/8ec73d6a-0e73-42c3-8856-afbaafe283cc)

## Verify GitHub Release

After the workflow executes, your release should be at the top of Semian's [Release list](https://github.com/Shopify/semian/releases).

## Verify RubyGems release

- After detecing a new tag from the GitHub workflow, Shipit should kick off a build and release it
- Check [RubyGems](https://rubygems.org/gems/semian)
