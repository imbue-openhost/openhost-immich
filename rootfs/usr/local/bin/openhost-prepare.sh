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
PG_DIR="$DATA_DIR/postgres"
PHOTOS_DIR="$DATA_DIR/photos"
CONFIG_DIR="$DATA_DIR/config"
OIDC_DIR="$DATA_DIR/oidc"
SECRETS_DIR="$DATA_DIR/secrets"

if [[ -z "${OPENHOST_APP_DATA_DIR:-}" ]]; then
    log "FATAL: OPENHOST_APP_DATA_DIR not set"
    exit 1
fi

log "DATA_DIR=$DATA_DIR"

mkdir -p "$DATA_DIR" "$PG_DIR" "$PHOTOS_DIR" "$CONFIG_DIR" "$OIDC_DIR" "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# --- random-secret helper -------------------------------------------
# Each secret lives in its own file under $SECRETS_DIR. We generate
# once on first boot and reuse forever after; otherwise a restart
# would invalidate the DB password.
gen_secret() {
    local name=$1 path
    path="$SECRETS_DIR/$name"
    if [[ ! -s "$path" ]]; then
        # 32 bytes of base64 = 43 chars, well over enough entropy
        # and uses only [A-Za-z0-9_-] which is safe in URLs and
        # most config-file syntaxes.
        local bytes
        bytes=$(openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
        printf '%s' "$bytes" > "$path"
        chmod 600 "$path"
    fi
    cat "$path"
}

DB_PASSWORD=$(gen_secret db-password)
OIDC_CLIENT_ID=$(gen_secret oidc-client-id)
OIDC_CLIENT_SECRET=$(gen_secret oidc-client-secret)

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

# --- export to s6 services via /etc/s6-overlay/s6-rc.d/<svc>/run ---
# The cleanest way to share these values across s6 services without
# baking them into the image is a generated env file. Each service's
# run script `set -a; source` it and continues.
ENV_FILE="$DATA_DIR/runtime.env"
cat > "$ENV_FILE" <<EOF
DB_PASSWORD='${DB_PASSWORD}'
OIDC_CLIENT_ID='${OIDC_CLIENT_ID}'
OIDC_CLIENT_SECRET='${OIDC_CLIENT_SECRET}'
OIDC_PUBLIC_BASE='${PUBLIC_BASE}'
OIDC_DATA_DIR='${OIDC_DIR}'
PUBLIC_BASE='${PUBLIC_BASE}'
PG_DATA_DIR='${PG_DIR}'
PHOTOS_DIR='${PHOTOS_DIR}'
CONFIG_DIR='${CONFIG_DIR}'
EOF
chmod 640 "$ENV_FILE"

# --- export to the imagegenius/immich expected env --------------------
# The imagegenius base image's immich-server start script reads its
# DB credentials and paths from the standard env vars. We can't set
# new env vars in /etc/environment because s6's container init
# doesn't read it on every service spawn; the cleanest path is to
# write `/etc/s6-overlay/s6-rc.d/svc-immich/run` overrides... but
# the imagegenius scripts already read from process env. Setting
# the values in the s6 stage-1 init env file works.
S6_ENV=/etc/s6-overlay/scripts/openhost-immich.env
mkdir -p /etc/s6-overlay/scripts
cat > "$S6_ENV" <<EOF
DB_PASSWORD='${DB_PASSWORD}'
DB_HOSTNAME='127.0.0.1'
DB_PORT='5432'
DB_USERNAME='immich'
DB_DATABASE_NAME='immich'
REDIS_HOSTNAME='127.0.0.1'
REDIS_PORT='6379'
SERVER_HOST='127.0.0.1'
SERVER_PORT='2283'
MACHINE_LEARNING_HOST='127.0.0.1'
MACHINE_LEARNING_PORT='3003'
IMMICH_MEDIA_LOCATION='${PHOTOS_DIR}'
EOF

# Source the env file early so subsequent services in this s6
# stage already see DB_PASSWORD etc. (s6's `with-contenv` reads
# /var/run/s6/container_environment/; we mirror our env vars in
# there for compatibility.)
mkdir -p /var/run/s6/container_environment
for var in DB_PASSWORD DB_HOSTNAME DB_PORT DB_USERNAME DB_DATABASE_NAME \
           REDIS_HOSTNAME REDIS_PORT SERVER_HOST SERVER_PORT \
           MACHINE_LEARNING_HOST MACHINE_LEARNING_PORT IMMICH_MEDIA_LOCATION \
           OIDC_PUBLIC_BASE OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_DATA_DIR; do
    case "$var" in
        DB_PASSWORD) printf '%s' "$DB_PASSWORD" > /var/run/s6/container_environment/$var ;;
        DB_HOSTNAME) printf '127.0.0.1' > /var/run/s6/container_environment/$var ;;
        DB_PORT) printf '5432' > /var/run/s6/container_environment/$var ;;
        DB_USERNAME) printf 'immich' > /var/run/s6/container_environment/$var ;;
        DB_DATABASE_NAME) printf 'immich' > /var/run/s6/container_environment/$var ;;
        REDIS_HOSTNAME) printf '127.0.0.1' > /var/run/s6/container_environment/$var ;;
        REDIS_PORT) printf '6379' > /var/run/s6/container_environment/$var ;;
        SERVER_HOST) printf '127.0.0.1' > /var/run/s6/container_environment/$var ;;
        SERVER_PORT) printf '2283' > /var/run/s6/container_environment/$var ;;
        MACHINE_LEARNING_HOST) printf '127.0.0.1' > /var/run/s6/container_environment/$var ;;
        MACHINE_LEARNING_PORT) printf '3003' > /var/run/s6/container_environment/$var ;;
        IMMICH_MEDIA_LOCATION) printf '%s' "$PHOTOS_DIR" > /var/run/s6/container_environment/$var ;;
        OIDC_PUBLIC_BASE) printf '%s' "$PUBLIC_BASE" > /var/run/s6/container_environment/$var ;;
        OIDC_CLIENT_ID) printf '%s' "$OIDC_CLIENT_ID" > /var/run/s6/container_environment/$var ;;
        OIDC_CLIENT_SECRET) printf '%s' "$OIDC_CLIENT_SECRET" > /var/run/s6/container_environment/$var ;;
        OIDC_DATA_DIR) printf '%s' "$OIDC_DIR" > /var/run/s6/container_environment/$var ;;
    esac
done

# --- ensure permissions on the persistent volume ---------------------
# The persistent OpenHost volume arrives owned by the host root
# (mapped to container root under rootless podman). The postgres,
# abc (immich), and oidc-bridge processes all need to read/write
# their respective subtrees. Recursive chmod is safer than chown
# under rootless because chown to non-host-mapped UIDs can fail.
chmod 0755 "$DATA_DIR" "$PG_DIR" "$PHOTOS_DIR" "$CONFIG_DIR" "$OIDC_DIR"
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
    # Enable listening on localhost for the immich client.
    cat >> "$PG_DIR/postgresql.conf" <<'PGCONF'
listen_addresses = '127.0.0.1'
port = 5432
shared_preload_libraries = 'vchord.so'
PGCONF
    cat > "$PG_DIR/pg_hba.conf" <<'PGHBA'
local   all             all                                     trust
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
PGHBA
    chown postgres:postgres "$PG_DIR/postgresql.conf" "$PG_DIR/pg_hba.conf" 2>/dev/null || true
    log "Postgres initialised; will create immich role on first run via the postgres service"
fi

# --- preconfigure Immich's system.json with our OAuth ---------------
# Immich reads /usr/src/app/config/<file>.json (or wherever
# IMMICH_CONFIG_FILE points). We point Immich at a config file we
# manage on the persistent volume so the OAuth settings are baked in
# from the very first boot, and survive image updates.
SYSTEM_CONFIG="$CONFIG_DIR/system.json"
if [[ ! -f "$SYSTEM_CONFIG" ]]; then
    log "Writing default Immich system.json with OIDC pre-configured"
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
    "userinfoSigningAlgorithm": "none",
    "storageLabelClaim": "preferred_username",
    "mobileOverrideEnabled": false,
    "profileSigningAlgorithm": "none"
  },
  "passwordLogin": {
    "enabled": false
  },
  "newVersionCheck": {
    "enabled": false
  }
}
EOF
fi
# Tell Immich to read this config file. The imagegenius image's
# immich-server start script honours IMMICH_CONFIG_FILE.
echo -n "$SYSTEM_CONFIG" > /var/run/s6/container_environment/IMMICH_CONFIG_FILE

log "openhost-init complete"
