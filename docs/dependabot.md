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

After Dependabot bumps the pins, the vendored launcher may differ from the new revision's: the
revision check then fails and names it. Copy `launcher/ci-deploy-local` from the new SHA into the
same pull request.

## In this repository

`.github/dependabot.yml` lists every action directory (`/setup`, `/deploy`, ...) and `/` for the
workflows, because an `action.yml` in an unlisted directory would keep its pins forever.
`test/unit/actions_test.rb` fails when an action directory is missing from the list. Bundler
updates (Kamal and its dependencies) are grouped weekly.
