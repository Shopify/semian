# Release

## Before You Begin

Ensure your local workstation is configured to be able to
[Sign commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits).

## Local Release Preparation

### Checkout latest code

```shell
$ git checkout master
$ git pull origin master
```

### Bump version

Update version in [`lib/semian/version.rb`](./lib/semian/version.rb).
Check if there is required changes in [`README.md`](./README.md).
Add line after `## [Unreleased]` in [`CHANGELOG.md`][./CHANGELOG.md] with new version.

### Run Tests

Make sure all tests passed and gem could be build.
Check [`README.md`](./README.md).

### Create Release Commit and Tag

Commit changes and create a tag. Make sure commit and tag are signed.
Extract related content from [`CHANGELOG.md`][./CHANGELOG.md] for a tag message.

```shell
$ export RELEASE_VERSION=0.x.y
$ git commit -a -S -m "Release $RELEASE_VERSION"
$ git tag -s "v$RELEASE_VERSION"
```

## Release Tag

On your local machine again, push your commit and tag

```shell
$ git push origin master --follow-tags
```

## Verify rubygems release

- Shipit should kick off a build and release after new version detected.
- Check [rubygems](https://rubygems.org/gems/semian)

## Github release

- Create a new gem
    ```shell
    $ bundle exec rake build build:checksum
    ```
- Create github release. Choose either `hub` or `gh`.
  * Github CLi [gh_release_create](https://cli.github.com/manual/gh_release_create) :
    ```
    $ gh release create v$RELEASE_VERSION pkg/semian-$RELEASE_VERSION.gem checksums/semian-$RELEASE_VERSION.gem.sha512
    ```
  * Hub:
    ```
    $ hub release create -a pkg/semian-$RELEASE_VERSION.gem -a checksums/semian-$RELEASE_VERSION.gem.sha512 v$RELEASE_VERSION
    ```
