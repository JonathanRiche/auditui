# Third-party notices

Auditui itself is distributed under AGPL-3.0-only. The packaged binaries
include or use the following direct runtime/build dependencies. Their own
licenses remain in effect:

| Dependency | Pinned version | License |
|---|---:|---|
| Bun | 1.4.0 | MIT |
| OpenTUI core and Linux native packages | 0.5.10 | MIT |
| TypeScript | 5.9.2 | Apache-2.0 |
| Zig | 0.16.0 | MIT |
| SQLite | system package | Public domain |
| mpv | system package | GPL-2.0-or-later (with optional components) |

Development-only packages are recorded by the root and TUI lockfiles. Run
`mise run license:check` before distribution to confirm that every installed
package declares an allowlisted license and to regenerate the evidence after
dependency changes. This inventory is a compliance aid, not legal advice.
