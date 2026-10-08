# 0001 Shared deploy components

Status: Accepted, 2026-10-08. Implementation: phase 1 (this repository); consumers not yet
migrated.

## Context

Several components deployed with Kamal through copies of the same composite actions, hook helpers
and scripts. The copies had drifted: different Kamal versions (2.2.2 to 2.4.0), different Terraform
output parsing, different rollback and retry behaviour, and a role-reconciliation script that
silently never ran because it compared against a configuration format Kamal no longer prints.
Fixes landed in one copy and not in the others.

## Decision

1. **One public repository of independent composite actions** (`setup`, `deploy`, `operations`,
   plus CI helpers for Node, PHP, Terraform, containers, Dependabot and a revision check). Each
   resolves its own scripts through `github.action_path`, never through the consumer's checkout,
   so the code that runs is the code at the pinned SHA.
2. **Pinned by full commit SHA** in consumers, with the release as a comment, updated by one
   grouped weekly Dependabot pull request. References are allowed only in top-level
   `.github/workflows/*.yml`: Dependabot does not see deeper files and a reference elsewhere
   could pin a second revision. The revision check enforces a single revision, the location rule
   and the vendored launcher's identity.
3. **Ruby 3.3 and Kamal 2.10.0 locked** by `Gemfile.lock`; the local launcher installs the same
   bundle per revision in a cache, never globally.
4. **Deploy invariants live in one place** (`lib/ci_deploy/deploy.rb`): one explicit version for
   build and deploy; a failed build or missing prebuilt image changes no host; metadata,
   notifications and rollback are centralised; cleanup and notification run after failures and
   the original result is preserved; rollback policy is explicit (`auto` or `off`, default `off`).
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
