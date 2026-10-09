# ci-deploy

Shared GitHub Actions for deploying and operating applications with
[Kamal](https://kamal-deploy.org). One pinned revision of this repository provides the Kamal
version, the deploy flow, the hook helpers and the operations catalog.

Released under the MIT licence; see `LICENSE`.

## Components

| Directory | What it does |
| --- | --- |
| `setup/` | Checks out the component at the workflow's commit, installs Ruby 3.3 and the locked Kamal (2.10.0), loads the SSH key, exports variables, secrets and Terraform outputs, copies the Kamal secrets file, puts this revision's helpers on `PATH` and exports `BUNDLE_GEMFILE` and `RUBYLIB` for the rest of the job. Given the deploy's destination (`report-destination`), it reports its own failure to Rollbar as a failed deploy, since GitHub then skips the deploy action. |
| `deploy/` | Builds (or checks) one explicit image version, deploys exactly that version, rolls back if the required `rollback` input says so, then always runs cleanup and Rollbar reporting and re-raises the deploy's own result. |
| `operations/` | The operations catalog: accessories, commands on hosts or in the app, consoles per stack, logs, proxy details, restart and reboot (explicit target only), free Kamal arguments. |
| `dependabot-merge/` | Merges a Dependabot security fix inside the caret range with an open alert; optionally dispatches the deploy workflow. |
| `revision-check/` | Fails unless a component references this repository only from top-level workflows (every file git knows about is scanned), all pinned to one full SHA. |
| `lib/sh/hooks.sh` | Helpers Kamal hooks source to run a command from the incoming image or in the live container. |
| `bin/` | `kamal` (the locked version), `ci-deploy-reconcile-removed-roles`, `ci-deploy-host-control`; on `PATH` after setup. |

Every action finds its scripts through `github.action_path`, never through the consumer's checkout,
so a component pinned to a SHA runs exactly that SHA's code.

## Usage

Pin every reference to the same full commit SHA, with the release as a comment, in top-level
workflows only (`.github/workflows/*.yml`, never `.github/workflows/shared/**`):

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: marcortola/ci-deploy/setup@<sha> # v1.0.0
        with:
          config: etc/kamal/deploy.yml
          vars: ${{ toJSON(vars) }}
          secrets: ${{ toJSON(secrets) }}
          outputs-map: |
            WEB_SERVER_IPS=web_server_ips
            DATABASE_SERVER_IPS=database_server_ips[0]
          terraform-token: ${{ secrets.TF_API_TOKEN }}
          terraform-workspace: ${{ vars.TF_WORKSPACE_ID }}
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}
          ssh-user: deploy
          report-destination: staging   # the deploy's destination: a setup failure reaches Rollbar

      - uses: marcortola/ci-deploy/deploy@<sha> # v1.0.0
        with:
          destination: staging
          rollback: "off"   # required: auto or off

  revision:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha> # v7.0.1
      - uses: marcortola/ci-deploy/revision-check@<sha> # v1.0.0
```

Each action's `action.yml` documents its inputs and outputs. The guides:

- [Adopting ci-deploy in a component](docs/adoption.md), with every place the existing
  implementations diverge and the input that covers each.
- [Hooks](docs/hooks.md): the helpers, container selection and examples.
- [Operations](docs/operations.md): the catalog and its guards.
- [kamal-proxy pre-check and upgrade](docs/proxy.md).
- [Dependabot](docs/dependabot.md): the consumer template.
- [Reverting](docs/reverting.md): undoing an adoption or a bad release.
- [Releasing](docs/releasing.md).
- [Design records](docs/design-records/README.md).

## Development

The devShell (`nix develop`) provides Ruby 3.3, Bundler, ShellCheck, actionlint, git and jq.

```sh
nix develop --command bundle install
nix develop --command script/lint          # ShellCheck and actionlint
nix develop --command script/test          # unit suite (Minitest), includes a real `kamal config` render
nix develop --command script/integration   # slow: Docker-in-Docker servers, registry, two apps, proxy upgrade
script/check-remote-pin                     # the remote-consumption pin carries HEAD's action code
```

The integration suite needs Docker with privileged containers and binds 127.0.0.1:55000,
127.0.0.2:2222 and 127.0.0.3:2222. It removes everything it starts (`cid-it-*`) on exit;
`CI_DEPLOY_IT_KEEP=1` keeps the environment for inspection.
