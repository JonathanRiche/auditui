# Upstream compatibility baseline

Frozen on 2026-09-02. Tags were fetched from the authoritative GitHub
repositories and resolved locally with Git; no source snapshot is vendored.

| Project | Version | Commit | Tag object | License |
|---|---:|---|---|---|
| [`mkb79/audible-cli`](https://github.com/mkb79/audible-cli) | 0.6.0 | [`274539eba80a63ddccb79a9ec4f59b2fe911e232`](https://github.com/mkb79/audible-cli/commit/274539eba80a63ddccb79a9ec4f59b2fe911e232) | `9016457a56be3917791af0417ac755987dc31a63` (`v0.6.0`, annotated) | AGPL-3.0-only |
| [`mkb79/audible`](https://github.com/mkb79/audible) | 0.12.0 | [`97575861ff03528013b1c8a77e68a238ea456951`](https://github.com/mkb79/audible/commit/97575861ff03528013b1c8a77e68a238ea456951) | `v0.12.0` | AGPL-3.0-only |

The CLI's declared dependency is `audible>=0.11.0`. This project deliberately
freezes 0.12.0 for behavior study so a future dependency release cannot move
the target. The tag commits' `pyproject.toml` files are the version and license
authority. Upstream history remains available through the links above.

## Rebase procedure

1. Open a dedicated baseline-update change; never move these SHAs incidentally.
2. Verify the new tag signature/object and that its package version agrees.
3. Diff command help, defaults, config/auth formats, HTTP behavior, and licenses.
4. Add new manifest entries as `unimplemented`, then implement and test them.
5. Regenerate sanitized help snapshots/differential results. Never copy live
   credentials, response bodies, signed URLs, or owned media into the repository.
6. Update attribution and perform a license review before distribution.

Local reproduction:

```sh
git ls-remote https://github.com/mkb79/audible-cli.git refs/tags/v0.6.0 refs/tags/v0.6.0^{}
git ls-remote https://github.com/mkb79/audible.git refs/tags/v0.12.0 refs/tags/v0.12.0^{}
```
