# Dependabot

## In a consumer

Dependabot updates action references per directory, without descending into subdirectories.
References to ci-deploy live only in top-level workflows, so one entry for
`/.github/workflows` updates every pin together, weekly, as one grouped pull request; the root
entry keeps the component's usual cadence for every other action and ignores ci-deploy, so the
two never race.

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /.github/workflows
    schedule:
      interval: weekly
    allow:
      - dependency-name: "marcortola/ci-deploy*"
    groups:
      ci-deploy:
        patterns: ["marcortola/ci-deploy*"]

  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly          # keep the component's current cadence
    ignore:
      - dependency-name: "marcortola/ci-deploy*"
```

## In this repository

`.github/dependabot.yml` lists every action directory (`/setup`, `/deploy`, ...) and `/` for the
workflows, because an `action.yml` in an unlisted directory would keep its pins forever.
`test/unit/actions_test.rb` fails when an action directory is missing from the list. The
entry ignores `marcortola/ci-deploy*`: the remote-consumption workflow pins this repository's own
action-code commit, which only the release procedure moves.

Bundler updates are grouped weekly, except Kamal minor and major versions, which Dependabot
ignores: a Kamal minor can raise `Kamal::Configuration::Proxy::Run::MINIMUM_VERSION`, the oldest
kamal-proxy it deploys behind, and so needs the [proxy procedure](proxy.md) on every host before
consumers move. Kamal patch versions still arrive through Dependabot. A Kamal minor or major
upgrade is done by hand as a release (see [releasing](releasing.md)).
