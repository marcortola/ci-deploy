# Hooks

Kamal hooks stay in the component (`.kamal/hooks/` or wherever `hooks_path` points). They decide
which commands run, in which phase, in which order and what a failure means. This repository only
provides the helpers that run one command on the primary host.

```sh
#!/bin/sh
set -eu
. "${CI_DEPLOY_HOOKS_LIB:?run through the ci-deploy setup action}/hooks.sh"

if ci_deploy_is_rollback; then
    exit 0
fi

ci_deploy_symfony new-image "doctrine:migrations:migrate -n -v"
ci_deploy_symfony new-image "app:messaging:setup"
```

`CI_DEPLOY_HOOKS_LIB`, `PATH` (this revision's `bin/` first) and `BUNDLE_GEMFILE` are set by the
setup action, so a hook that calls `kamal` runs the locked Kamal with
the same bundle as the deploy that started it.

## Choosing the container

Every call names the container explicitly; there is no default.

| Mode | Runs in | Use it |
| --- | --- | --- |
| `new-image` | a disposable container from the image being deployed (`--version $KAMAL_VERSION`) | before boot, when the live container still runs the old code; for anything that must not share the live container's state |
| `live-container` | the running container of the incoming version (`--reuse --version $KAMAL_VERSION`) | in the post-deploy hook only, once that container runs; before boot no such container exists, so the helper refuses it unless `KAMAL_RUNTIME` is set, which Kamal sets for post-deploy only |

Symfony: the live web container usually has no `USER`, so `bin/console` there runs as root and
can leave `var/cache/prod` owned by root, after which php-fpm fails every request. Use
`new-image` for console commands.

## Functions

| Function | Runs |
| --- | --- |
| `ci_deploy_exec MODE COMMAND` | `COMMAND` as given |
| `ci_deploy_symfony MODE ARGS` | `bin/console ARGS` |
| `ci_deploy_node MODE COMMAND` | a Node command line (`npm run ...`, `node dist/...`) |
| `ci_deploy_python MODE ARGS` | `python ARGS` |
| `ci_deploy_retry ATTEMPTS SLEEP CMD...` | `CMD` until it succeeds, at most `ATTEMPTS` times |
| `ci_deploy_is_rollback` | true while Kamal runs the hooks of `kamal rollback` |

Each passes `COMMAND` to Kamal as one argument and exits with Kamal's status (64 for a usage
error), so `set -e` stops the hook at the first failure.

Settings, read when a function runs:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CI_DEPLOY_HOOK_CONFIG` | `CI_DEPLOY_CONFIG`, else `./etc/kamal/deploy.yml` | Kamal configuration |
| `CI_DEPLOY_HOOK_ROLES` | `web` | role filter; set it empty to run without `--roles` |
| `KAMAL_DESTINATION` | set by Kamal | passed as `-d` only when set |
| `KAMAL_VERSION` | set by Kamal | required |

## Removed roles

`ci-deploy-reconcile-removed-roles` (on `PATH`) removes running containers whose role is no
longer in the configuration, for example after lowering a worker count. Call it from
`post-deploy`, best-effort:

```sh
ci-deploy-reconcile-removed-roles || echo "[reconcile] skipped (non-fatal)"
```

It skips (and exits 0) whenever the rendered configuration lacks roles, hosts or a service name
ending in the version. Read [adoption](adoption.md#behaviour-changes-to-review-before-adopting)
before enabling it on a component that copied the earlier script.

## Pausing a service around a rollout

`ci-deploy-host-control` runs one action of a fixed control command on the primary host:

```yaml
- uses: marcortola/ci-deploy/deploy@<sha> # v1.0.0
  with:
    destination: production
    before-deploy-command: ci-deploy-host-control --command /usr/local/sbin/<control> pause
    cleanup-command: ci-deploy-host-control --command /usr/local/sbin/<control> resume
```

The pause runs once the image exists (a failed build leaves the service running), even with
`skip-hooks`; its failure stops the deploy. The resume runs whatever happened; its failure only
warns. Options: `--actions` (allowed actions), `--hosts-var` (default `SERVER_IPS`),
`--destinations` (default `production`; others exit 0 without connecting), `--no-sudo`.
