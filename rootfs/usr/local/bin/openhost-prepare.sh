#!/bin/bash
# First-boot/every-boot preparation for openhost-immich.
#
# Tasks:
#   1. Create the persistent layout under $OPENHOST_APP_DATA_DIR so
#      every other service can find its data.
#   2. Generate (and persist) random secrets that don't exist yet:
#      - DB password (immich <-> postgres)
#      - OIDC client_id + client_secret (oidc-bridge <-> Immich)
#   3. Initialise the postgres data dir if empty, including the
#      Immich VectorChord-extended DB and the immich role.
#   4. Configure the OIDC bridge env (issuer URL, owner email).
#   5. Write Immich's `system.json` with OAuth pre-configured so the
#      admin doesn't have to click through the OIDC settings UI on
#      first boot.
#
# Idempotent: every step skips work that's already been done in a
# previous boot, so a container restart only takes a few seconds.

set -euo pipefail

log() { printf '[openhost-init] %s\n' "$*" >&2; }

DATA_DIR="${OPENHOST_APP_DATA_DIR:-/data/app_data/immich}"
# Photos live on the archive tier so the operator can back the
# bulk-media volume with S3 (via JuiceFS) without paying the latency
# tax on Postgres or the OIDC bridge.  See [data] in openhost.toml.
ARCHIVE_DIR="${OPENHOST_APP_ARCHIVE_DIR:-/data/app_archive/immich}"
PG_DIR="$DATA_DIR/postgres"
PHOTOS_DIR="$ARCHIVE_DIR/photos"
CONFIG_DIR="$DATA_DIR/config"
OIDC_DIR="$DATA_DIR/oidc"
SECRETS_DIR="$DATA_DIR/secrets"

if [[ -z "${OPENHOST_APP_DATA_DIR:-}" ]]; then
    log "FATAL: OPENHOST_APP_DATA_DIR not set"
    exit 1
fi
if [[ -z "${OPENHOST_APP_ARCHIVE_DIR:-}" ]]; then
    # The archive tier is mandatory in this manifest (app_archive=true
    # in openhost.toml).  An OpenHost runtime that doesn't honor that
    # would silently lose every photo to a directory inside the
    # container's writable layer that gets dropped on restart, so
    # fail loudly here instead of giving the operator a deceptively
    # working install on the first boot.
    log "FATAL: OPENHOST_APP_ARCHIVE_DIR not set; this manifest requires app_archive=true"
    exit 1
fi

log "DATA_DIR=$DATA_DIR"
log "ARCHIVE_DIR=$ARCHIVE_DIR"

mkdir -p "$DATA_DIR" "$PG_DIR" "$CONFIG_DIR" "$OIDC_DIR" "$SECRETS_DIR"
mkdir -p "$ARCHIVE_DIR" "$PHOTOS_DIR"
chmod 700 "$SECRETS_DIR"

# /var/run/postgresql is on tmpfs (recreated empty on every boot).
# postgres needs it for the unix socket and lock file.
install -d -o postgres -g postgres -m 0755 /var/run/postgresql

# Photos and config dirs need to be writable by the immich process.
# Under rootless podman the OpenHost volume arrives owned by host
# root, which the container's "root" (mapped to an unprivileged
# host UID) can read and write. We run immich as root via PUID=0
# so the parent dir works, but Immich's startup integrity check
# also needs the .immich marker files in each subdir
# (encoded-video, library, profile, thumbs, upload) to confirm it
# owns the directory tree -- it tries to read them before it's
# written them. Pre-create the entire tree of marker files here.
mkdir -p \
    "$PHOTOS_DIR/encoded-video" \
    "$PHOTOS_DIR/library" \
    "$PHOTOS_DIR/profile" \
    "$PHOTOS_DIR/thumbs" \
    "$PHOTOS_DIR/upload" \
    "$PHOTOS_DIR/backups"
for sub in "" encoded-video library profile thumbs upload backups; do
    marker="$PHOTOS_DIR${sub:+/$sub}/.immich"
    if [[ ! -f "$marker" ]]; then
        : > "$marker"
    fi
done
chmod -R u+rwX "$PHOTOS_DIR" "$CONFIG_DIR" 2>/dev/null || true

# DB_PASSWORD, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET are pre-set as
# environment variables by the Dockerfile (constant per image; only
# the loopback-local Postgres and OIDC bridge need them). We use
# whatever the env carries -- letting an operator override via the
# OpenHost manifest if they ever want to.
: "${DB_PASSWORD:?DB_PASSWORD must be set in env}"
: "${OIDC_CLIENT_ID:?OIDC_CLIENT_ID must be set in env}"
: "${OIDC_CLIENT_SECRET:?OIDC_CLIENT_SECRET must be set in env}"

# --- compute the public base URL ------------------------------------
# OpenHost serves us at https://<app-name>.<zone-domain>/. The
# OIDC bridge needs to know this absolute URL because it appears as
# `iss` in id_tokens and as the issuer URL in Immich's OAuth config.
APP_NAME="${OPENHOST_APP_NAME:-immich}"
ZONE="${OPENHOST_ZONE_DOMAIN:-}"
if [[ -z "$ZONE" ]]; then
    log "FATAL: OPENHOST_ZONE_DOMAIN not set"
    exit 1
fi
PUBLIC_BASE="https://${APP_NAME}.${ZONE}"
log "PUBLIC_BASE=$PUBLIC_BASE"

# Most env vars are pre-set in the Dockerfile (DB_PASSWORD,
# DB_HOSTNAME, etc.) so the imagegenius image's init scripts see
# them at process spawn time. We only need to surface the small
# set of values that depend on $OPENHOST_APP_DATA_DIR (which is
# only known at container start) into /var/run/s6/container_environment/
# so subsequent s6 services see them too.
mkdir -p /var/run/s6/container_environment
printf '%s' "$PHOTOS_DIR"     > /var/run/s6/container_environment/IMMICH_MEDIA_LOCATION
printf '%s' "$PUBLIC_BASE"    > /var/run/s6/container_environment/OIDC_PUBLIC_BASE
printf '%s' "$OIDC_DIR"       > /var/run/s6/container_environment/OIDC_DATA_DIR

# --- ensure permissions on the persistent volume ---------------------
# The persistent OpenHost volume arrives owned by the host root
# (mapped to container root under rootless podman). The postgres,
# abc (immich), and oidc-bridge processes all need to read/write
# their respective subtrees. Recursive chmod is safer than chown
# under rootless because chown to non-host-mapped UIDs can fail.
#
# ARCHIVE_DIR is in its own bind mount — when backed by JuiceFS the
# chmod is a no-op for the underlying S3 storage but does apply to
# the FUSE mount metadata, which is what the in-process Immich
# permission checks see, so it still matters here.
chmod 0755 "$DATA_DIR" "$PG_DIR" "$ARCHIVE_DIR" "$PHOTOS_DIR" "$CONFIG_DIR" "$OIDC_DIR"
chmod 0700 "$SECRETS_DIR"
# Postgres requires its data dir to be 0700 owned by the postgres
# user. We do best-effort chown -- it'll succeed in most rootless
# setups because postgres user has uid 999 and the volume root is
# already root-owned.
chown -R postgres:postgres "$PG_DIR" 2>/dev/null || \
    log "warn: chown postgres:postgres $PG_DIR failed; postgres may refuse to start"
chmod 0700 "$PG_DIR"

# --- initialise postgres if empty ------------------------------------
if [[ -z "$(ls -A "$PG_DIR" 2>/dev/null)" ]]; then
    log "Initialising postgres data dir at $PG_DIR"
    su - postgres -s /bin/bash -c "/usr/lib/postgresql/14/bin/initdb -D '$PG_DIR' --auth=trust --auth-host=md5 --data-checksums --encoding=UTF8 --no-locale" \
        || { log "initdb failed"; exit 1; }
    log "Postgres initialised; will create immich role on first run via the postgres service"
fi

# Always (re-)write postgresql.conf and pg_hba.conf, so changes
# between image versions take effect on the next restart. We
# overwrite the config rather than append so an image rollback
# cleanly takes the prior config back.
log "Writing postgres config"
cat > "$PG_DIR/postgresql.conf" <<'PGCONF'
listen_addresses = '127.0.0.1'
port = 5432
# Both vchord (VectorChord) and vectors (pgvecto.rs) require their
# shared libraries to be preloaded; pgvecto.rs in particular
# refuses to load via CREATE EXTENSION without it.
shared_preload_libraries = 'vchord.so,vectors.so'
# Reasonable defaults for a personal-scale Immich instance.
max_connections = 100
shared_buffers = 256MB
work_mem = 16MB
maintenance_work_mem = 64MB
PGCONF
cat > "$PG_DIR/pg_hba.conf" <<'PGHBA'
local   all             all                                     trust
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
PGHBA
chown postgres:postgres "$PG_DIR/postgresql.conf" "$PG_DIR/pg_hba.conf" 2>/dev/null || true
chmod 0640 "$PG_DIR/postgresql.conf" "$PG_DIR/pg_hba.conf" 2>/dev/null || true

# --- preconfigure Immich's system.json with our OAuth ---------------
# Immich reads its system config from $IMMICH_CONFIG_FILE (set in
# the Dockerfile ENV so it's available at process spawn time, before
# this script runs). We write the file on every boot so config
# updates from image upgrades take effect, and so we always reflect
# the current PUBLIC_BASE / OIDC_CLIENT_* values.
SYSTEM_CONFIG="$CONFIG_DIR/system.json"
log "Writing Immich system.json with OIDC pre-configured"
cat > "$SYSTEM_CONFIG" <<EOF
{
  "oauth": {
    "enabled": true,
    "autoLaunch": true,
    "autoRegister": true,
    "buttonText": "Sign in with OpenHost",
    "issuerUrl": "${PUBLIC_BASE}/_oidc",
    "clientId": "${OIDC_CLIENT_ID}",
    "clientSecret": "${OIDC_CLIENT_SECRET}",
    "scope": "openid email profile",
    "signingAlgorithm": "RS256",
    "profileSigningAlgorithm": "none",
    "storageLabelClaim": "preferred_username",
    "roleClaim": "immich_role",
    "mobileOverrideEnabled": false
  },
  "passwordLogin": {
    "enabled": false
  },
  "newVersionCheck": {
    "enabled": false
  }
}
EOF
chmod 0644 "$SYSTEM_CONFIG"

log "openhost-init complete"
