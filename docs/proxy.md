# kamal-proxy: pre-check and upgrade

Kamal 2.10 requires kamal-proxy v0.9.0 or later. A host whose proxy was booted by an older Kamal
(2.2.x boots v0.8.1, 2.4.x boots v0.8.4) makes every Kamal 2.10 deploy to it fail early with
"kamal-proxy version ... is too old" before any application container changes. The proxy is
shared by every application on the host, so its upgrade is a separate, explicit operation, never
part of a deploy.

This repository does not pin the proxy version: it uses Kamal 2.10's default (v0.9.0). A host
can carry its own `image_version` boot setting, which `proxy-details` shows.

## Before the first Kamal 2.10 deploy

1. **List the applications on each host.** For every component that deploys to the host, run the
   `proxy-details` operation (or `bin/ci-deploy-local -- proxy details`) and note the proxy image
   version and the boot configuration (`proxy boot_config get`).
2. **If every host already runs v0.9.0 or later**, nothing else is needed.
3. **Otherwise plan the reboot** in a window acceptable to every application on the host: the
   reboot stops the proxy, so every application on it is unreachable for a few seconds.

## Upgrading

1. **Before:** check every application on the host answers (its health URL), and record
   `proxy-details` output.
2. **Reboot explicitly**, from one component that deploys to the host, with Kamal 2.10:

   ```yaml
   - uses: marcortola/ci-deploy/operations@<sha> # v1.0.0
     with:
       operation: proxy-reboot
       hosts: 192.0.2.10        # or `all` for every host of this configuration
   ```

   The operation refuses to run without `hosts`. kamal-proxy keeps its routes in its state
   volume, so the other applications' routes survive the reboot.
3. **After:** run `proxy-details` (expect v0.9.0) and check every application on the host answers
   again, not only the one whose configuration ran the reboot.
4. Then deploy with Kamal 2.10 as usual.

A later proxy version follows the same procedure once a Kamal release requires it: upgrade
ci-deploy, then reboot each host explicitly.

The integration suite (`script/integration`) exercises this: two applications on one host behind
v0.8.1, a refused Kamal 2.10 deploy, a refused untargeted reboot, the reboot to v0.9.0, and both
applications checked before and after.

## Note on `--image-version`

Kamal 2.10's `proxy reboot` has no `--image-version` option. It boots the version in the host's
boot configuration, or Kamal's minimum. `kamal proxy boot_config set --image-version` exists but
is deprecated and resets the other boot options, so the catalog does not offer it.
