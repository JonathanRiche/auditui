# Yoto provider

Auditui integrates with Yoto only through the documented public API. It does
not scrape Yoto services, discover private endpoints, or retain signed media
URLs beyond the request that starts playback.

## Supported surface

- OAuth 2.0 Authorization Code with PKCE through a loopback callback.
- Rotating refresh tokens stored in an owner-only credential file.
- Make Your Own (MYO) content from `GET /content/mine`.
- Cards returned by documented family-library group endpoints.
- Cover art, descriptions, chapters, and track metadata returned by Yoto.
- Local streaming through mpv when the documented content endpoint returns a
  playable signed URL.

Yoto is intentionally capability-driven in Auditui. Yoto items are marked
streamable when Yoto supplies playable media; they are not presented as
offline-downloadable. Audible's existing AAXC download behavior is unchanged.

## Authentication

Create a **Public Client** in the [Yoto developer dashboard](https://dashboard.yoto.dev/)
and register this exact redirect URL:

```text
http://127.0.0.1:8787/callback
```

Set the issued client identifier for the current command, then connect:

```sh
YOTO_CLIENT_ID=your-public-client-id auditui auth login --provider yoto
```

The option form is equivalent, and is useful for one command without exporting
an environment variable:

```sh
auditui auth login --provider yoto --client-id your-public-client-id
```

Use `--account NAME` to keep multiple local Yoto accounts separate. Login
immediately performs the first refresh. Later refreshes reuse the stored client
ID and rotating refresh token, so `YOTO_CLIENT_ID` is not required again:

```sh
auditui library refresh --provider yoto --account default
auditui library list --provider yoto --account default
```

The client identifier is public by design; no client secret is used or shipped.
Auditui opens Yoto's login page, accepts one callback on the IPv4 loopback
interface, validates OAuth state and PKCE, exchanges the one-time code, and
stores the resulting rotating refresh token with mode `0600` permissions.

The provider requests only `user:content:view`, `family:library:view`,
`offline_access`, and `profile`. It does not request content-edit,
family-library-manage, device-management, media-upload, or icon-upload scopes.

## Library limits

Yoto's documented `/content/mine` operation returns the authenticated user's
MYO cards. The documented family-library operations expose cards assigned to
groups. The public documentation does not currently provide a general endpoint
that enumerates every purchased commercial card, so Auditui does not attempt to
reconstruct that list through undocumented requests.

## Current capability boundary

Supported:

- Read-only MYO and family-group library refreshes.
- Metadata, covers, chapters, and documented signed S3 playback URLs.
- Local streaming through the existing mpv player.

Not currently supported:

- Enumerating all purchased commercial cards when they are not returned by an
  official endpoint used above.
- Permanent offline downloads of Yoto media.
- Creating or editing MYO cards or family-library groups.
- Device discovery, configuration, commands, or telemetry.
- Uploading media, covers, family images, or icons.
- Reporting Yoto accounts through `auditui auth status` (that command currently
  reports Audible-compatible profiles only).

These boundaries are deliberate. Auditui will not substitute undocumented or
reverse-engineered endpoints for unavailable public API operations.

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
