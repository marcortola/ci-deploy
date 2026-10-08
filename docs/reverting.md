# Reverting

## A bad ci-deploy release in a component

Pin the component back to the previous release's SHA: revert the pull request that bumped the
pins (all references and the vendored launcher change together, so the revert restores both).
The revision check confirms one revision. Nothing on the hosts depends on the ci-deploy version,
except:

- **kamal-proxy.** A proxy upgraded for a newer Kamal stays upgraded; older Kamal versions still
  deploy behind a newer proxy within the same major series. Do not downgrade the proxy unless the
  older Kamal refuses it.
- **Kamal version changes.** A release that changes the locked Kamal can change container labels
  or naming. Read the release notes before reverting across a Kamal upgrade, and redeploy after
  the revert so the running containers match the Kamal that manages them.

## Undoing an adoption

Adoption replaces local workflow files, hook helpers and scripts in one pull request per component.
To undo it, revert that pull request: the component's previous composite actions, scripts and
`Gemfile` come back unchanged. Then:

1. If the component deployed with Kamal 2.10 meanwhile, its hosts may run kamal-proxy v0.9.0;
   older Kamal versions deploy behind it, so leave it.
2. If `ci-deploy-reconcile-removed-roles` removed orphaned containers, nothing needs restoring:
   those roles were no longer in the configuration.
3. Remove the ci-deploy entries from the component's `dependabot.yml`.

## A failed deploy

The deploy action's `rollback-result` output says what happened:

| Result | Meaning | Action |
| --- | --- | --- |
| `succeeded` | every host reports the previous version | investigate the failure, fix forward |
| `failed` | the rollback did not complete or could not be confirmed | the failed version may be serving: run `kamal rollback <previous-version>` (the `previous-version` output) through the `kamal` operation, then check `kamal app version` |
| `disabled` | the policy is `off` | decide between fixing forward and a manual rollback; migrations may make older code unsafe |
| `no-target` | nothing was serving, or only the same or a `_replaced_` version | fix forward |
| `not-attempted` | the build failed, the image was missing or the before-deploy command failed | no host changed (apart from the before-deploy command's own effect) |
