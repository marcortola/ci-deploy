# Local launcher

`launcher/ci-deploy-local` runs the same revision, bundle, Kamal and hook helpers on a laptop as
CI does. Copy it unchanged into the component as `bin/ci-deploy-local`; the revision check fails
when the copy differs from the launcher at the pinned SHA.

```sh
bin/ci-deploy-local [launcher options] [--] <kamal arguments>
```

What it does:

1. Finds the nearest `.github/workflows` above the current directory and reads every
   `marcortola/ci-deploy...@<ref>` in its top-level workflows. It stops when there is none, when
   they name more than one revision, or when the revision is not a full commit SHA.
2. Fetches that SHA into `${CI_DEPLOY_CACHE:-~/.cache/ci-deploy}/<sha>` and installs its locked
   bundle there (`vendor/bundle`, frozen). Nothing is installed globally. A failed fetch or
   install removes the partial cache; an interrupted one leaves a `<sha>.lock` directory that the
   next run names. `CI_DEPLOY_REPOSITORY_URL` overrides the source (a mirror or a local clone).
3. Uses Ruby 3.3 from `PATH`, or else `nix develop <cache>` (this repository's devShell).
4. Runs `bin/ci-deploy local` in the current directory with `BUNDLE_GEMFILE`, `RUBYLIB`,
   `CI_DEPLOY_HOOKS_LIB` and `PATH` pointing at that revision, so hooks started by Kamal reach the
   same `kamal`.

## Options

Credentials are explicit: nothing is read from a default location.

| Option | Meaning |
| --- | --- |
| `--env-file FILE` | `KEY=VALUE` lines (`export`, quotes and `\n` in double quotes accepted); repeatable, later files win |
| `--config FILE` | Kamal configuration (default `etc/kamal/deploy.yml`); added as `-c` unless the Kamal arguments carry one |
| `--secrets-file FILE` | copied to `.kamal/` (default `etc/kamal/secrets-common` when present) |
| `--outputs-map FILE` | Terraform outputs map, as in the setup action |
| `--terraform-workspace ID` | workspace for the map; the token comes from `TF_API_TOKEN` |
| `--rollback auto\|off` | rollback policy for `deploy` (default `off`) |
| `--branch-policy enforce\|off` | production branch guard for `deploy` (default `enforce`) |

## Deploying

`deploy` runs the same flow as the deploy action: one version for build and deploy, a failed
build touches no host, the rollback policy applies.

```sh
bin/ci-deploy-local --env-file ~/secure/app.env -- deploy -d staging
bin/ci-deploy-local --env-file ~/secure/app.env -- deploy --skip-push --version 1a2b3c... -d production
```

`--skip-push` deploys a prebuilt image and needs `--version`; it refuses to start unless that
image is already published in the registry. `deploy` accepts `-d`, `-c`, `--version`,
`--skip-push` and `-H`/`--skip-hooks`. Every other Kamal command is passed through unchanged.
