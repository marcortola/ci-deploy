# 0002 Push the env files before kamal deploy

Status: Accepted, 2026-11-21.
Implementation: `bin/ci-deploy-push-env` and step 5 of `CiDeploy::Deploy`
(marcortola/ci-deploy#10); not released when this record was written.

## Context

Kamal 2.10.0, the version `Gemfile.lock` fixes, runs the pre-deploy hook before it writes the
role env files the new containers read:

- `kamal deploy` runs the pre-deploy hook inside the deploy lock, then `app boot`
  (`lib/kamal/cli/main.rb:33-34`).
- `app boot` is the only step of a deploy that uploads a role's secret env file: `execute
  *app.ensure_env_directory` then `upload! role.secrets_io(host), role.secrets_path, mode:
  "0600"` (`lib/kamal/cli/app/boot.rb:50-51`).
- Every app container, including the disposable one `kamal app exec` starts, gets that file as
  `--env-file` (`lib/kamal/configuration/role.rb:94-108`), at
  `.kamal/apps/<service>[-<destination>]/env/roles/<role>.env` (`lib/kamal/configuration.rb:234-248`).

So a hook that runs a command in a new container of the incoming image (`ci_deploy_exec
new-image`, the documented way to run migrations) reads the env file of the previous deploy: a
secret added or rotated in this deploy is missing or stale there, while the containers that boot
a moment later see the new value. Upstream has two proposed fixes, neither in 2.10.0: a hidden
`kamal app boot_env` that uploads the env files (basecamp/kamal#1870) and `kamal app exec
--push-secrets` (basecamp/kamal#1742).

## Decision

1. **The deploy pushes every app role's env file right before `kamal deploy`**, after the build
   or image check and the before-deploy command, and also with `skip-hooks`, so the hook-free
   path boots from the same file. `bin/ci-deploy-push-env` adds #1870's `app boot_env` to
   Kamal's app CLI, hidden from its help, with #1870's body: on every app host, for each role on
   it, `ensure_env_directory` then the same `upload!` as `app boot`.
2. **It runs through Kamal's own CLI**, so the configuration, destination, secret resolution
   (`.kamal/secrets*`, adapters included), the pre-connect hook and SSH setup are Kamal's, not a
   copy. It starts `Kamal::Cli::App` with `boot_env` first, not `Kamal::Cli::Main` with `app`
   first: Thor gives a subcommand the options `Main` parsed only as class options, so
   `--skip-hooks` never reached Kamal's hook check and the pre-connect hook ran anyway, and
   `KAMAL_SUBCOMMAND` was missing from the hook's environment. A unit test pins both.
3. **Inside Kamal's deploy lock** (`with_lock`, as `kamal deploy` takes it). A lock held by
   another deploy fails the push before any env file is written, instead of changing the file a
   running deploy's hooks read.
4. **A failed push stops the deploy** with `deploy-result: env-push-failed` and
   `rollback-result: not-attempted`: `kamal deploy` does not run and nothing is rolled back,
   because nothing was booted. There is no retry; re-running the deploy pushes again, and the
   push is idempotent.
5. **Only app roles.** Accessory env files are uploaded by the accessory commands, which no
   deploy hook precedes; #1870 leaves them out too.
6. **Removed when Kamal ships the fix.** Once ci-deploy adopts a Kamal release that ships #1870
   or #1742, the push goes (or becomes that release's own command) and this record is amended.
   The unit test `test_boot_env_is_registered_on_kamals_app_cli_and_hidden` fails as soon as the
   locked Kamal defines `boot_env` itself.

## Alternatives considered

- **Waiting for upstream.** Leaves every pre-deploy migration reading stale secrets until a
  release ships either fix; neither had shipped in the locked version. Rejected for the interim.
- **A patched or forked Kamal.** A second release channel for Kamal itself, against
  [0001](0001-shared-deploy-components.md)'s single pinned bundle. Rejected.
- **Uploading the files with plain SSH from ci-deploy's Ruby.** Would duplicate Kamal's SSH
  options, pre-connect hook and secret resolution, and drift from them. Rejected.
- **`kamal app boot` before the deploy.** Boots containers of the new version before the hooks
  run, which is exactly what the pre-deploy hook must precede. Rejected.
- **A push inside each component's pre-deploy hook.** Every component would carry it, it would not
  run with `skip-hooks`, and it would run a nested Kamal command against the lock the deploy
  holds. Rejected.
- **Pushing without the lock.** Could replace the env file under another deploy that is running
  its hooks. Rejected.
- **Retrying a failed push.** The likely failures are configuration, secrets, SSH or a held lock;
  none clears by retrying within the step, and a re-run is cheap. Rejected.

## Consequences

- Hooks' `new-image` containers read this deploy's secrets ([hooks](../hooks.md)).
- Between the push and the boot, the hosts the push reached hold this deploy's env file while the
  previous version still serves. Running containers do not reread it, and Docker reads
  `--env-file` only when it creates a container, so restarts keep their environment; a new
  container of the old version started in that window (a manual `kamal app exec`, say) would get
  the new secrets. After a failed push the window stays open until the next deploy; the
  `env-push-failed` error says so.
- Kamal resolves the secrets twice per deploy, once for the push and once for `kamal deploy`, so
  adapter-backed secrets (`kamal secrets fetch`) are fetched twice. The pre-connect hook also
  runs twice, unless `skip-hooks` is set: once for the push, with `KAMAL_COMMAND=app` and
  `KAMAL_SUBCOMMAND=boot_env`, and once for `kamal deploy`.
- The push and `kamal deploy` take the lock separately. A deploy that takes it in between makes
  this one's `kamal deploy` fail on the held lock, as any lock conflict does. When no
  per-destination concurrency group serializes the deploy runs, another run's push can also land
  between this deploy's push and its `kamal deploy`, so this deploy's pre-deploy hook reads that
  run's env files; its own `app boot` still writes its own.
- Only the deploy action pushes. A `kamal deploy`, `kamal redeploy` or `kamal rollback` run by
  hand, or through the operations action's free `kamal` arguments, does not; the break-glass
  procedure in [adoption](../adoption.md#running-kamal-by-hand-break-glass) runs
  `ci-deploy-push-env` first.

## Evidence and limits

The Kamal behaviour above is read from the 2.10.0 gem's source at the lines cited. Unit tests
cover the order (after the build, image check and before-deploy command, right before `kamal
deploy`, also with `skip-hooks`), that no push runs after a failed build, missing image or failed
before-deploy command, and `env-push-failed` with no deploy and no rollback
(`test/unit/deploy_test.rb`, `test/unit/cli_test.rb`). `test/unit/push_env_test.rb` runs the
script against the locked Kamal with no server: the command Kamal dispatches, the hook
environment, `--skip-hooks` and the error reporting. The remote-consumption workflow checks the
published action calls the push right before `deploy`. The integration suite changes a secret
between two deploys to two Docker-in-Docker hosts. Its pre-deploy hook starts a new container of
the incoming image on each host, the primary through `ci_deploy_exec new-image` and the second
host through `kamal app exec --hosts`, and the suite checks that both read the new value. Those
reads run before `app boot`, which rewrites the env files after the hook, so only the push can
have written the value they see; the second host's env file is also checked after the deploy,
which alone would pass without the push.

Not exercised by a test: the push meeting a held lock (Kamal's own `with_lock` path), a push that
reaches some hosts and fails on others, more than one role per host, and adapter-backed secrets.
The tripwire test catches #1870 landing in Kamal, not #1742, whose `exec --push-secrets` has to
be noticed in the Kamal changelog when the locked version is bumped.
