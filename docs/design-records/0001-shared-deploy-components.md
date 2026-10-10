# 0001 Shared deploy components

Status: Accepted, 2026-10-08; amended 2026-10-08 (scope cut, see [Amendment](#amendment-2026-10-08-scope-cut)); amended 2026-10-09 (break-glass procedure documented, no launcher); amended 2026-10-10 (production branch to any destination, see [Amendment](#amendment-2026-10-10-production-branch-to-any-destination)).
Implementation: phase 1 (this repository); consumers migrated to v1.0.0 on 2026-10-09.

## Context

Several components deployed with Kamal through copies of the same composite actions, hook helpers
and scripts. The copies had drifted: different Kamal versions (2.2.2 to 2.4.0), different Terraform
output parsing, different rollback and retry behaviour, and a role-reconciliation script that
silently never ran because it compared against a configuration format Kamal no longer prints.
Fixes landed in one copy and not in the others.

## Decision

1. **One public repository of independent composite actions** (`setup`, `deploy`, `operations`,
   plus CI helpers for Node, PHP, Terraform, containers, Dependabot and a revision check;
   the Node, PHP, Terraform and container helpers are deferred by the amendment). Each
   resolves its own scripts through `github.action_path`, never through the consumer's checkout,
   so the code that runs is the code at the pinned SHA.
2. **Pinned by full commit SHA** in consumers, with the release as a comment, updated by one
   grouped weekly Dependabot pull request. References are allowed only in top-level
   `.github/workflows/*.yml`: Dependabot does not see deeper files and a reference elsewhere
   could pin a second revision. The revision check enforces a single revision and the location
   rule (the launcher comparison was removed by the amendment).
3. **Ruby 3.3 and Kamal 2.10.0 locked** by `Gemfile.lock`. (The local launcher that installed the
   same bundle on a workstation was removed by the amendment.)
4. **Deploy invariants live in one place** (`lib/ci_deploy/deploy.rb`): one explicit version for
   build and deploy; a failed build or missing prebuilt image changes no host; metadata,
   notifications and rollback are centralised; cleanup and notification run after failures and
   the original result is preserved; rollback policy is explicit (`auto` or `off`; required with
   no default since the amendment).
5. **Hook order and commands stay local.** The shared part is the mechanism (role
   reconciliation, executors for new image or live container with an explicit choice,
   parametrised host control), not the per-component sequence.
6. **The proxy is never changed by a deploy.** Kamal 2.10's default proxy version (v0.9.0) is
   used without an override in configuration; restart and reboot are catalog operations that
   require an explicit target.
7. **Operations take argument vectors.** Free Kamal arguments are split like shell words and
   passed without `eval` or a runner shell.

## Alternatives considered

- **Reusable workflows** instead of composite actions: they hide steps from the consumer's job,
  cannot share a job's checkout and SSH state with local steps, and fix the job layout. Rejected.
- **A gem** installed in each component: adds a release channel separate from the action pins and
  lets the action code and the Ruby code drift. Rejected; the bundle comes from the same SHA.
- **Moving tags** (`@v1`): convenient, but mutable and not reviewable. Rejected for SHA pins.
- **Pinning the proxy version in the shared configuration helpers**: would make every deploy an
  implicit proxy change on shared hosts. Rejected (amendment 1 of the approved plan).

## Consequences

- Behaviour changes for consumers are listed in [adoption](../adoption.md), notably that role
  reconciliation now actually removes orphaned containers.
- Hosts still on kamal-proxy older than v0.9.0 need the explicit [proxy procedure](../proxy.md)
  before their first Kamal 2.10 deploy.
- Kamal 2.10's `proxy reboot` has no `--image-version`; a specific proxy version can only come from
  the host's boot configuration or Kamal's minimum.
- A ci-deploy release is a SHA plus tag ([releasing](../releasing.md)); reverting is reverting the
  pin bump ([reverting](../reverting.md)).

## Evidence and limits

The deploy flow, hooks, operations and proxy upgrade are covered by the unit suite and by the
integration suite (`script/integration`), which deploys to disposable Docker-in-Docker hosts over
SSH, including two applications sharing one proxy upgraded from v0.8.1 to v0.9.0. Neither
exercises a real registry with authentication, Terraform Cloud, or real notification endpoints;
those paths are covered by unit tests with stubs only.

## Amendment 2026-10-08: scope cut

Approved by the user during the review of the phase 1 pull request.

- **No CI toolchain actions.** The `node`, `php`, `terraform` and `container` actions are deferred
  to phase 5 and removed from this repository with their scripts, tests and Dependabot entries.
  Each wrapped a few lines of a component's own CI around a third-party action; moving those
  lines behind a pinned shared action added a level of indirection and a release step for every
  change, for little gain over keeping them in the component. `dependabot-merge` and
  `revision-check` stay.
- **No local launcher.** `launcher/ci-deploy-local`, its Ruby code (`CiDeploy::Local`), tests,
  integration scenario, documentation and the revision check's `launcher` input are removed. The
  user never deploys from a workstation, so the launcher was code to maintain and keep identical
  in every component without a caller. Deploys and operations run only through the actions.
  (Amended 2026-10-09: a manual break-glass procedure, with no launcher, is documented in
  [adoption](../adoption.md#running-kamal-by-hand-break-glass) for when the actions cannot run.)
- **Rollback has no default.** `rollback` is required, so a component that relies on automatic
  rollback cannot lose it by omitting the input during migration.

Consequences: the revision check no longer compares a vendored file; a component adopts the
setup, deploy and operations actions, the hook helpers, `dependabot-merge` and the revision
check, and keeps its own toolchain steps. Reintroducing the deferred actions is a new decision
with its own record.

## Amendment 2026-10-10: production branch to any destination

Approved by the user.

- **Decision.** `branch-policy: enforce` guarantees only that the production destination (or no
  destination) deploys from the production branch. The rule that refused the production branch
  for any other destination is removed. The other `enforce` checks are unchanged: the checkout
  must be the workflow's commit, and a checkout whose commit git cannot read is refused.
- **Reason.** The consumers retire their long-lived `dev` branch. Staging is deployed only by
  hand, and resetting it to the production branch on demand is one of those deploys; the removed
  rule refused exactly that.
- **Consequence.** A deploy of the production branch to staging (or any non-production
  destination) now runs under `enforce` instead of being refused. Production is guarded as
  before only when `production-destination` names the production destination exactly: the
  removed rule also caught a misnamed one, by refusing the production branch's first deploy to
  it, and now nothing does. The branch no longer implies the environment, so a consumer must
  select its GitHub environment and hook behaviour by destination. Nothing that succeeded before
  fails, so it ships as a minor release (v1.1.0).
- **Alternative rejected.** Keep the rule and set `branch-policy: off` on the manual staging
  deploy: `off` also drops the workflow-commit check and the no-destination guard.
- **Evidence limits.** Covered by the unit and CLI-process tests. The remote-consumption workflow
  runs on pull requests, whose ref is never the production branch, so no remote run exercises a
  production-branch deploy to staging.
