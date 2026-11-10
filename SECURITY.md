# Security

`phoenix_dev_toolbar` is a development tool. It is meant to be installed with
`only: :dev` and to run on the developer's machine; it disables itself in releases and in any
Mix env other than `:dev` unless explicitly enabled (see [ADR 01](adr/01-zero-prod-footprint-and-installation.md)).
Running it on a server reachable by others is out of scope.

In scope: anything that leaks the toolbar into production builds, lets another origin
read or drive the panel, or crashes or slows down the host application.

Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/zoten/phoenix_dev_toolbar/security/advisories/new),
not in public issues.

## Features that act on the node

They run for whoever can open the panel, so each has a safe default:

- **Process actions** (kill, suspend, message peek, state read, message trace:
  [ADR 10](adr/10-process-addressing-and-actions.md)) are off by
  default. `actions: :loopback` runs them for a browser on the same machine only;
  `actions: :any` opens them to any browser that reaches the dev server (Docker, LAN).
- **Panel socket origin**: the panel's websocket accepts only an `Origin` that is the
  page's own host (and port), whatever the host's `check_origin` says. The panel,
  its socket and the export also answer only for a Host that cannot be DNS rebound
  ([ADR 04](adr/04-ui-delivery.md)).
- **The Eval plugin** ([ADR 12](adr/12-cluster-and-eval-plugins.md)) is not
  installed by default. Once added it is read only: a fixed list of read queries,
  open like the System tab. With `allow: :eval` it runs code typed in the panel as
  the BEAM user, for a browser on this machine only (an explicit `actions: false` in
  the host config refuses code too; unset `actions` does not); with `clients: :any` too,
  **anyone who reaches the dev server can run code on your machine**. Code is
  logged as a warning when the toolbar starts, with who may run it.
- "Loopback" is the address the panel's websocket comes from, with no
  `x-forwarded-*` header: a proxy or tunnel that adds none (Docker's userland port
  proxy, a plain TCP tunnel) makes whoever reaches it look local.
- **DNS rebinding**: the panel, its socket and its downloads answer only for a host
  name that cannot be rebound (an IP address, `localhost`, the endpoint's own
  `url` host, or one you list in `allowed_hosts:`), so a hostile web page cannot
  reach them through your browser.

