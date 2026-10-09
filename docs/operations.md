# Operations

The `operations` action runs one entry of the catalog against the configuration the setup action
prepared, as Kamal argument vectors: no input is ever parsed by the runner's shell.

```yaml
on:
  workflow_dispatch:
    inputs:
      operation: { type: choice, options: [accessory-details, accessory-reboot, host-exec, app-exec, console, logs, proxy-details, proxy-reboot, kamal] }
      target: { type: string, default: "" }
      command: { type: string, default: "" }
      hosts: { type: string, default: "" }
      container-mode: { type: choice, options: ["", new-image, live-container] }

jobs:
  operate:
    runs-on: ubuntu-latest
    steps:
      - uses: marcortola/ci-deploy/setup@<sha> # v1.0.0
        with: { ... }
      - uses: marcortola/ci-deploy/operations@<sha> # v1.0.0
        with:
          operation: ${{ inputs.operation }}
          target: ${{ inputs.target }}
          command: ${{ inputs.command }}
          hosts: ${{ inputs.hosts }}
          container-mode: ${{ inputs.container-mode }}
          destination: production
```

| Operation | Inputs | Runs |
| --- | --- | --- |
| `accessory-boot`, `-reboot`, `-start`, `-stop`, `-restart`, `-details` | `target`: accessory name or `all` | `kamal accessory <verb> <target>` |
| `host-exec` | `command`; `server` (`primary` default, or `all`), `roles`, `hosts` | `kamal server exec` |
| `app-exec` | `command`, `container-mode` (required); `stack`, `server`, `roles`, `hosts` | `kamal app exec [--reuse]` |
| `console` | as `app-exec`, `stack` required: `symfony` (`bin/console`), `node`, `python` | `kamal app exec` with the stack's runner |
| `logs` | `target`: `app`, `proxy` or an accessory; `lines`, `since`, `grep` | `kamal app/proxy/accessory logs` |
| `proxy-details` | `hosts` | `kamal proxy details` and `kamal proxy boot_config get` |
| `proxy-restart` | `hosts` (required: a list, or `all`) | `kamal proxy restart` |
| `proxy-reboot` | `hosts` (required: a list, or `all`) | `kamal proxy reboot -y` |
| `kamal` | `args`: free Kamal arguments | `kamal <args>` |

Guards:

- **Container mode is never defaulted** for `app-exec` and `console` (see [hooks](hooks.md)).
- **The proxy is never restarted or rebooted implicitly.** `proxy-restart` and `proxy-reboot` need
  `hosts`. Through `kamal` free arguments, `proxy reboot|restart|upgrade|stop|remove` and the
  top-level `remove` and `upgrade` need `--hosts`/`-h` with at least one host. A proxy reboot
  interrupts every application on the host; follow [the proxy procedure](proxy.md).
- **An empty filter is refused.** `--hosts=,`, `--hosts ""`, `-h ""`, `--roles=` and the like would
  select every host or role, so they are rejected, in free arguments and in the `hosts` and
  `roles` inputs alike. Free arguments are checked as Kamal's option parser (Thor) reads them:
  squished short options count (`-yh ""` is `-y -h ""`, and a later filter replaces an earlier
  one), and `-h` or `--hosts` followed by another option or by nothing gives no host list.
- **Free arguments are split like shell words** (quotes group) and passed as a vector: `;`, `|`,
  `$()` and backticks reach Kamal as plain characters. A command that Kamal runs inside a
  container (`app exec`, `server exec`) is still interpreted by the shell there, as Kamal always
  does. `-c`/`-d` cannot be given there, squished (`-yc`) or not; use the `config` and
  `destination` inputs.
- Roles, hosts, names and log filters are validated before Kamal runs.
- The action refuses to run if the setup action came from another revision.
