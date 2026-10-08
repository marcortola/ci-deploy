# Adopting ci-deploy in a component

A component adopts ci-deploy by replacing its own deploy plumbing (local composite actions,
inline scripts, hook helpers) with the shared actions, pinned to one SHA. Its commands, hook
phases and their order stay in the component.

## Steps

1. **Pick a release.** Use the SHA of a release tag (see [releasing](releasing.md)). Every
   reference in the component uses that full SHA with the release as a comment:
   `uses: marcortola/ci-deploy/deploy@<40-character sha> # v1.0.0`.
2. **Move every reference to a top-level workflow.** References belong in
   `.github/workflows/*.yml`. A local composite action under `.github/workflows/shared/` must not
   reference this repository: Dependabot's workflow entry would never update it, and the
   revision check rejects it. Inline the steps into the workflow, or keep the local action for
   component-specific steps only.
3. **Replace the setup.** One `setup` step replaces checkout, Ruby, Kamal installation, SSH agent,
   variable and secret export, Terraform output lookup and secrets file copy. Remove the
   component's `Gemfile` entry for Kamal (or the `gem install kamal` step); the locked Kamal comes
   from this repository. The secrets file is copied to `.kamal/`; keep that copy git-ignored, or
   the working tree is dirty and the derived version carries an `_uncommitted_` suffix.
4. **Map Terraform outputs.** Translate the component's output lookups into an `outputs-map`:

   | Lookup in the component | Map entry |
   | --- | --- |
   | a list joined with commas or spaces | `NAME=output` (always written comma-separated) |
   | the first element only (`.value[0]`) | `NAME=output[0]` |
   | an output that may be absent | `NAME=output?` (exported empty) |

5. **Read hosts with `CiDeploy::Hosts`.** In the Kamal configuration, replace any split of a host
   variable (`split(",")`, `split(" ")`, a partial that loops over lines) with
   `<% require "ci_deploy/hosts" %>` and `<%= CiDeploy::Hosts.list("WEB_SERVER_IPS").to_json %>`
   (or `.first` for one host). It accepts commas, spaces and newlines, drops duplicates and
   fails the render naming the variable when it is empty. `RUBYLIB` points at this revision's
   `lib/` after setup.
6. **Replace the deploy.** One `deploy` step replaces version capture, build, deploy, rollback,
   metadata, cleanup and Rollbar reporting. `rollback` is required (`auto` or `off`): carry over
   the component's current behaviour, `auto` where it rolled back automatically. Choose
   `build-mode` and the branch policy explicitly (see the divergences below).
7. **Port the hooks.** Source `lib/sh/hooks.sh` and replace the component's helper calls with
   `ci_deploy_exec MODE CMD` or a stack wrapper, choosing `new-image` or `live-container` for each
   command (see [hooks](hooks.md)). Keep each hook's commands, order and failure handling. Replace
   a copied `reconcile-removed-roles` with `ci-deploy-reconcile-removed-roles`, then do step 9
   before the first deploy.
8. **Replace operations workflows** with the `operations` action (see [operations](operations.md)).
9. **Review what the role reconcile will remove (mandatory, before the first deploy).** The
   copied script never ran (see below); the shared one does, so on the component's first deploy
   it removes every running container of the service whose role is no longer configured. List
   both sides with the `operations` action of the release being adopted, for every destination:

   ```yaml
   # The roles Kamal will keep
   - uses: marcortola/ci-deploy/operations@<sha> # v1.0.0
     with:
       operation: kamal
       args: config
       destination: production
   # The roles running on every host of that destination
   - uses: marcortola/ci-deploy/operations@<sha> # v1.0.0
     with:
       operation: host-exec
       server: all
       destination: production
       command: >-
         docker ps --filter label=service=<service> --filter label=destination=production
         --format '{{.Label "role"}} {{.Names}}'
   ```

   Drop `--filter label=destination=...` (and `destination`) for a configuration without
   destinations. Every running container whose role is not in the `:roles:` list of the first
   output will be stopped and removed. Review that list with the component's owner; stop the
   adoption if any of them must keep running, and add its role back to the configuration first.
10. **Add the revision check** to CI (`revision-check` after `actions/checkout`; it scans every file
    git knows about in the component).
11. **Update Dependabot** with the [template](dependabot.md).
12. **Check the proxy** on every host before the first deploy with Kamal 2.10 (see [proxy](proxy.md)).

## Divergences between existing implementations

The implementations this repository consolidates differ in the points below. Each is an input or
a setting; none is decided silently.

| Point | Variants found | How it is chosen here |
| --- | --- | --- |
| Kamal version | 2.2.2, 2.4.0, 2.10.0 | Fixed to 2.10.0 by `Gemfile.lock`. Components on older versions must pass the [proxy pre-check](proxy.md) first. |
| Build and deploy | one `kamal deploy` that builds; `kamal build push` then `kamal deploy --skip-push`; an image built by a separate Buildx step and deployed with `--skip-push` | `build-mode: kamal` (build push, then deploy `--skip-push`, one version) or `build-mode: prebuilt` (deploy an image already published, checked before any host is touched). |
| Version | Kamal's own (derived per process, so a dirty tree drew two versions); the commit SHA | One version, fixed once: the `version` input, or the commit with one `_uncommitted_` suffix. |
| Rollback | automatic rollback on; off | `rollback: auto` or `off`, required with no default, so a migration cannot silently drop it. Keep `off` where hooks run migrations older code cannot run against. |
| Rollback verification | exit status only; exit status, missing-container text and every host's version | Always the full verification. |
| Rollback target | first version seen; first version excluding `_replaced_` and the version being deployed | Always the latter, published only after the image exists. |
| Skipping hooks | supported in one component | `skip-hooks` input, warned. |
| Pausing a service around a rollout | a pause before the deploy and a resume after it, in one component | `before-deploy-command` (runs after the build, even with `skip-hooks`; failure stops the deploy) and `cleanup-command` (always runs; failure only warns), usually with `ci-deploy-host-control`. |
| Terraform output lookup | jq without status checks; status checks and retries; lists as `.value[]` (newlines), `.value[0]` or joined | The checked, retried lookup for everyone; `outputs-map` entries cover each list form. |
| Host list separator in the configuration | commas, spaces | `CiDeploy::Hosts` accepts both, and newlines. |
| Kamal environment for later steps | exported to the job in some components | Always exported by setup, so rollback and version reads see it. |
| Branch and destination pairing | production only from the default branch, that branch only to production; no destination meaning production | `branch-policy` (`enforce` or `off`), `production-branch`, `production-destination`; no destination counts as production. |
| Rollbar token variable | several names | `rollbar-token` input, else the first of `ROLLBAR_TOKEN`, `ROLLBAR_SERVER_TOKEN`, `ROLLBAR_ACCESS_TOKEN`, `LOG_ROLLBAR_ACCESS_TOKEN`. |
| Hook runner | console from a fresh container with `bin/console`; Node in the live container (post-deploy) or a fresh one; Python with a `python` prefix and no role filter; one configuration file per environment with no destination | `ci_deploy_exec MODE`, `ci_deploy_symfony`, `ci_deploy_node`, `ci_deploy_python`; `CI_DEPLOY_HOOK_ROLES` (empty for none), `CI_DEPLOY_HOOK_CONFIG`; `-d` only when Kamal sets a destination. |
| Hook retries | a local `retry` helper | `ci_deploy_retry ATTEMPTS SLEEP CMD...`. |
| Dependabot security merge | merge only; merge and dispatch the deploy workflow | `deploy-workflow` input of `dependabot-merge`. |
| Toolchain versions and CI steps (Node, PHP, Terraform, container builds) | per component | Not shared: they stay in each component (see design record 0001, amendment). |

## Behaviour changes to review before adopting

- **Removed-role reconciliation now runs.** The copied `reconcile-removed-roles` compared
  `roles:` while Kamal 2.10 prints `:roles:`, so it always skipped (fail-safe). The shared
  `ci-deploy-reconcile-removed-roles` parses Kamal's real output (covered by a test against
  `kamal config`) and renders the deployed version (`--version $KAMAL_VERSION`, so explicit and
  prebuilt versions reconcile too), so on its first run it **removes** running containers of
  roles no longer in the configuration. Step 9 above is mandatory for that reason.
- **Prebuilt images need the `service` label.** Kamal refuses an image without
  `LABEL service=<service>`; images built by Kamal carry it, images built elsewhere must add it.
- **A refused branch/destination pairing reports `refused`** and still sends the Rollbar report.
