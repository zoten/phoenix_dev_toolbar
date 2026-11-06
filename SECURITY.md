# Security

`phoenix_dev_toolbar` is a development tool. It is meant to be installed with
`only: :dev` and to run on the developer's machine; it disables itself in releases
unless explicitly enabled (see [ADR 01](adr/01-zero-prod-footprint-and-installation.md)).
Running it on a server reachable by others is out of scope.

In scope: anything that leaks the toolbar into production builds, lets another origin
read or drive the panel, or crashes or slows down the host application.

Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/zoten/phoenix_dev_toolbar/security/advisories/new),
not in public issues.
