# Authentication design

Authentication is not a stable public Audible API. This design is based on the
pinned upstream source in [upstream-baseline.md](upstream-baseline.md), especially
`audible/login.py`, `register.py`, and `auth.py`; it must be revalidated before a
release claiming live compatibility.

## Observed upstream flow

The preferred flow constructs a marketplace-specific Amazon OAuth/OpenID URL,
opens it in an external browser, and receives the final response URL. The
library exchanges the authorization result while registering a device. The
registration response can include an access token, refresh token, ADP token,
RSA device private key, website cookies, and device/customer metadata.

API clients refresh an expiring access token using the refresh token. Some
requests are bearer-authenticated; others are signed with the ADP token and
device private key. Website-only operations use cookies. These are all secrets.
Activation bytes and AAXC voucher material are secrets too even if their storage
or use differs.

## Version-1 policy

1. Default to external-browser authentication. The terminal never accepts or
   stores an Amazon password in this path; MFA and CAPTCHA stay in the browser.
2. Import existing auth JSON non-destructively. Resolve and validate the source,
   refuse group/world-readable files, copy through a private temporary file,
   validate structure without logging values, then atomically install it.
3. Create credential directories as `0700` and files as `0600`. Reject unsafe
   existing ownership, symlinks, and multi-link files. Never “fix” ownership.
4. Prefer Secret Service/keyring storage. The fallback is an authenticated
   encrypted file whose passphrase is read from a TTY or inherited file
   descriptor, never an ordinary argument or environment variable.
5. Refresh under a per-profile lock. Write replacement credentials to a private
   same-directory temporary file, fsync it, rename it, then fsync the directory.
   Preserve the last known-good file on any failure.
6. Redact header values, cookies, URL query strings, token/key/voucher fields,
   auth bodies, and suspicious high-entropy values before logging.
7. Logout defaults to local credential removal only. Remote device revocation is
   a separate, explicit, confirmed action because it changes external state.

The general SQLite database contains profile name, marketplace, credential
backend identifier, and timestamps only. It never contains tokens, cookies,
private keys, activation bytes, vouchers, passwords, or signed URLs.

## Recovery

An expired access token is refreshed once and the original safe request retried
once. A revoked refresh token transitions the profile to `reauthentication
required`; it does not loop. Interrupted credential writes leave the previous
file usable. A lost encryption passphrase cannot be recovered; create a new
browser-authenticated profile and explicitly revoke the old device if desired.

Live tests are opt-in and read-only by default. They fail before reading a local
profile unless the directory and file permissions are safe. Test output records
only pass/fail, response shape, HTTP status class, and timing.

During interactive browser authentication, encryption passphrases are read with
terminal echo disabled. The final one-time callback URL is echoed so the user
can verify that a long paste completed correctly; it is kept only in mutable
memory, wiped after use, and never written to logs or profile storage.

## Authenticated library sync

`audible-zig library refresh --profile NAME` prompts when the selected profile
is encrypted, decrypts that auth document only in memory, refreshes an expiring
bearer token through the pinned marketplace's `api.amazon` host, and sends the
`/1.0/library` request with Audible's supported `x-amz-access-token` header.
Authenticated redirects are disabled. A rotated token is written back only as
a mode-`0600` atomic replacement, preserving the profile's selected storage
mode. The library cache is also replaced atomically with mode `0600`. RPC method
`library.refresh` returns `PASSWORD_REQUIRED` for encrypted profiles because
protocol v1 never transports passphrases; the TUI directs the user to this
interactive command and continues using the last good cache.
