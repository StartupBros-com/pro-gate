**pro-gate now lives at [`plugins/pro-gate/` in StartupBros-com/hov-stack](https://github.com/StartupBros-com/hov-stack/tree/main/plugins/pro-gate).**

This repository is retired. It keeps the history and releases up to v0.65.2.
Releases from v0.65.3 on, issues and pull requests are in
[StartupBros-com/hov-stack](https://github.com/StartupBros-com/hov-stack).
Its open issues were re-filed there with the `plugin:pro-gate` label, or closed
with a reason; each one here links to where it went.

## Install

From the [House of Vibe marketplace](https://github.com/StartupBros-com/hov-stack):

```
/plugin marketplace add StartupBros-com/hov-stack
/plugin install pro-gate@hov
```

An existing install from the marketplace picks up the new home on its next
plugin update. There is nothing to reinstall.

## Upgrading a host from v0.65.2

The v0.65.2 runtime's hourly auto-updater downloads releases from this
repository, which publishes none after v0.65.2, so it cannot move a host to
v0.65.3 on its own. To move a host across, update the plugin and run the gate
once:

```
claude plugin update pro-gate@hov
```

then run `/pro-gate` in Claude Code. That run installs the v0.65.3 runtime from
hov-stack, and the v0.65.3 updater follows hov-stack releases from then on.
