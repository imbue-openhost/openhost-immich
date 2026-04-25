# openhost-immich

[Immich](https://immich.app) photo and video management, packaged
as an OpenHost app, with an in-container OIDC bridge that gates
sign-in on the OpenHost compute-space owner session.

## What's in the box

A single container with all of:

- **Immich server** + **Immich machine-learning** (from the
  [imagegenius/immich](https://github.com/imagegenius/docker-immich)
  community single-container build).
- **Postgres 14** with **VectorChord** and **pgvectors** extensions
  (binaries copied from
  [`ghcr.io/immich-app/postgres:14-vectorchord...`](https://github.com/immich-app/base-images)
  via a multi-stage build).
- **Valkey** (Redis-compatible cache) for Immich's job queue.
- **OIDC bridge** -- a small Starlette + PyJWT service that
  implements the subset of OIDC Immich needs (discovery, JWKS,
  authorize, token, userinfo) and accepts requests as
  authenticated when OpenHost has stamped them with
  `X-OpenHost-Is-Owner: true`.
- **nginx** fronting the whole thing on port 8080: routes
  `/_oidc/*` to the bridge and everything else to immich-server.
- s6-overlay to supervise everything together.

## How the SSO flow works

1. User visits `https://immich.<zone>/`. OpenHost's perimeter does
   the usual session check; the owner's request lands at our
   nginx, with `X-OpenHost-Is-Owner: true` attached.
2. Immich is configured (via a pre-baked `system.json`) with OAuth
   *and* Auto Launch enabled, pointing its issuer URL at our own
   `/_oidc` endpoint.
3. Immich's web client redirects the user to
   `/_oidc/authorize?...`. Our OIDC bridge sees the OpenHost owner
   header, mints an authorization code, and 302s back to Immich's
   redirect URI.
4. Immich's server hits `/_oidc/token` to exchange the code, gets
   back a signed RS256 ID token + access token, calls
   `/_oidc/userinfo`, and registers the email as a local Immich
   account on first sign-in (`autoRegister: true`).
5. The user is in. Subsequent visits skip everything: the OpenHost
   session cookie keeps the request authenticated; Immich's own
   session cookie keeps the user logged in until either expires.

If the OpenHost session is missing (the user is not signed in), the
bridge bounces them to `https://<zone>/login`, OpenHost handles the
login, and the OAuth flow resumes.

The Immich password-login path is disabled by default
(`passwordLogin.enabled: false` in `system.json`), so OIDC is the
only way in.

## Constraints / known limitations

- **Single-tenant.** OpenHost itself is single-owner today, so the
  OIDC bridge derives all user identity from a single
  `OPENHOST_OWNER_EMAIL` (configurable; defaults to
  `owner@openhost.local`). Inviting other people to the Immich
  instance is not supported until OpenHost grows multi-user
  identity.
- **No mobile app SSO.** The Immich mobile apps' OAuth callback
  scheme (`app.immich:///oauth-callback`) needs the user to be
  signed into OpenHost in their mobile browser at the time, which
  works on iOS/Android but is awkward. Use the web app for now.
- **Large image (~3-4 GiB).** Immich's ML stack has CLIP +
  facial-recognition models baked in; first deploy is slow.
- **Memory hungry.** ML models load ~1.5 GiB into RAM at full tilt.
  Default manifest requests 6 GiB; bump for big libraries.

## Files

- `openhost.toml` -- OpenHost manifest (port 8080, app_data, 6 GiB
  RAM, 3 cores).
- `Dockerfile` -- multi-stage build extending `imagegenius/immich`
  with Postgres, Valkey, nginx, OIDC bridge.
- `nginx.conf` -- request router on :8080.
- `oidc-bridge/server.py` -- Starlette OIDC implementation.
- `oidc-bridge/requirements.txt` -- Python pins.
- `rootfs/usr/local/bin/openhost-prepare.sh` -- first-boot init
  (generates DB password, OIDC client_id/secret, Postgres data dir,
  Immich `system.json`).
- `rootfs/etc/s6-overlay/s6-rc.d/<svc>/...` -- s6-rc service
  definitions for postgres, valkey, oidc-bridge, nginx-front, and
  the openhost-init oneshot that runs them all.

## Security

- Everything inside the container talks over loopback only. nginx is
  the sole entry point on port 8080.
- The OIDC bridge listens on `127.0.0.1:9000` so external traffic
  cannot bypass nginx and skip the OpenHost owner check.
- The DB password and OIDC client secret are generated on first
  boot and stored in `$OPENHOST_APP_DATA_DIR/secrets/` with mode
  0600; they survive image upgrades.
- Postgres `pg_hba.conf` allows `trust` from the local socket
  (postgres user only) and `md5` from 127.0.0.1; nothing else.
- The `passwordLogin.enabled: false` Immich setting means a leaked
  Immich password cannot log anyone in -- the only path is OAuth
  through our bridge, which requires an OpenHost owner session.
