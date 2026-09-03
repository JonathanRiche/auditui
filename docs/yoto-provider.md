# Yoto provider

Auditui integrates with Yoto through Yoto's public API host, authenticated
only with the user's own OAuth token. Library reads use documented operations.
Playback of purchased cards uses one card operation on the same host that the
public reference does not list (see "Playback" below). Auditui does not scrape
Yoto services, bypass access controls, or retain signed media URLs beyond the
request that starts playback.

## Supported surface

- OAuth 2.0 Authorization Code with PKCE through a loopback callback.
- Rotating refresh tokens stored in an owner-only credential file.
- Make Your Own (MYO) content from `GET /content/mine`.
- Cards returned by documented family-library group endpoints.
- Cover art, descriptions, chapters, and track metadata returned by Yoto.
- Local streaming through mpv when the documented content endpoint returns a
  playable signed URL.

Yoto is intentionally capability-driven in Auditui. Yoto items are marked
streamable only when Yoto supplies signed playable media, which today means
Make Your Own cards. Purchased cards placed in Library groups are listed with
full metadata but the documented playable-content operation answers 403 for
them, so they appear as "in your library" rather than streamable. Nothing is
presented as offline-downloadable. Audible's existing AAXC download behavior is
unchanged.

## Authentication

Create a **Public Client** in the [Yoto developer dashboard](https://dashboard.yoto.dev/)
and register this exact redirect URL:

```text
http://127.0.0.1:8787/callback
```

The README's [illustrated Yoto setup](../README.md#connect-yoto) shows every
dashboard field, the scopes to select, and which optional fields to leave
blank during development. Every scope Auditui requests must be approved for
the application; when Yoto denies a login the CLI prints Yoto's exact reason.
If only `offline_access` is unapproved, Auditui automatically retries the
login without it, stores a session with no refresh token, and reports
`YotoSessionExpired` when the access token lapses so you can sign in again.

Copy the issued client identifier into this one-line setup command. No `.env`
file and no exported shell variable are required:

```sh
auditui auth login --provider yoto --client-id YOUR_CLIENT_ID
```

Sign into the browser prompt with an adult account belonging to the Yoto
family you want to connect, even if a different email owns the developer
application. Auditui forces a fresh login so an unrelated developer-dashboard
session cannot be reused silently. Explicitly accept the warning shown for an
unverified application.

To connect a second account while keeping its library and playback state
separate, add a memorable account name:

```sh
auditui auth login --provider yoto --client-id YOUR_CLIENT_ID --account kids-room
```

Login immediately performs the first refresh. Auditui stores the public client
ID with that account's private credentials, so later commands need neither the
ID nor an environment variable:

```sh
auditui library refresh --provider yoto --account default
auditui library list --provider yoto --account default
auditui
```

The client identifier is public by design; no client secret is used or shipped.
Auditui opens Yoto's login page, accepts one callback on the IPv4 loopback
interface, validates OAuth state and PKCE, exchanges the one-time code, and
stores the resulting rotating refresh token with mode `0600` permissions.

The provider requests only `user:content:view`, `family:library:view`, and
`offline_access` (dropping `offline_access` when Yoto has not approved it). It does not request profile data, content-edit,
family-library-manage, device-management, media-upload, or icon-upload scopes.

### Development checkout

When running from source, Mise builds the Zig engine before each provider task.
No `.env` file is involved:

```sh
mise install
mise run install
mise run yoto:connect -- --client-id YOUR_CLIENT_ID
mise run yoto:refresh
mise run yoto:list
mise run tui:start
```

For a named account, pass the same name after the task separator, for example
`mise run yoto:connect -- --client-id YOUR_CLIENT_ID --account kids-room` and
`mise run yoto:refresh -- --account kids-room`.

## Library limits

Yoto's documented `/content/mine` operation returns the authenticated user's
MYO cards. The documented family-library group operations expose cards assigned
to groups; the list operation returns item IDs only, so Auditui fetches each
group individually, which is where Yoto expands the full card metadata. The public documentation does not currently provide a general endpoint
that enumerates every purchased commercial card, so Auditui does not attempt to
reconstruct that list through undocumented requests.

**To see purchased cards in Auditui**, put them in a Library group: in the Yoto
app open *Library*, create a group (for example "Auditui"), add every card you
want available, then run `auditui library refresh --provider yoto`. Auditui
fetches every card in every group and fills in metadata for group items whose
card details Yoto did not expand inline. When a refresh finds no groups at all,
the CLI prints this reminder.

## Current capability boundary

Supported:

- Read-only MYO and family-group library refreshes.
- Metadata, covers, chapters, and signed playback URLs.
- Local streaming of Make Your Own cards and of purchased cards placed in a
  Library group, through the existing mpv player.

Not currently supported:

- Enumerating purchased cards that are not in any Library group.
- Permanent offline downloads of Yoto media.
- Creating or editing MYO cards or family-library groups.
- Device discovery, configuration, commands, or telemetry.
- Uploading media, covers, family images, or icons.
- Reporting Yoto accounts through `auditui auth status` (that command currently
  reports Audible-compatible profiles only).

### Playback

For a card, Auditui first calls the documented
`GET /content/{cardId}?playable=true&signingType=s3`. Yoto answers that with
signed URLs for Make Your Own cards but `403` for purchased cards, and group
responses carry only `yoto:#` track references. Only after that refusal does
Auditui call `GET /card/{cardId}` on the same `api.yotoplay.com` host with the
same token; for cards the family owns it returns the same card document with
short-lived CloudFront-signed track URLs, which are handed to mpv in memory and
never persisted. This operation is absent from the public reference, so Yoto
may change it without notice; if it stops working, purchased cards will again
show as library-only items rather than failing loudly. Auditui does not use any
other unlisted endpoint, does not circumvent rate limits or access controls,
and never downloads or caches purchased media.

## Data handling

- Access and refresh tokens are secret and never enter RPC messages, logs, or
  command arguments.
- Rotated refresh tokens replace the previous credential file atomically.
- Signed playback URLs remain in engine memory only and are refreshed when
  playback starts.
- Provider metadata is cached only for the local library experience and can be
  removed with the associated local account.
- Auditui does not permanently download commercial Yoto media.

See Yoto's [CLI authentication guide](https://yoto.dev/authentication/headless-cli-auth/),
[scope reference](https://yoto.dev/authentication/scopes/),
[API guidelines](https://yoto.dev/get-started/api-guidelines/), and
[API terms](https://yoto.dev/reference/terms-and-conditions/).
