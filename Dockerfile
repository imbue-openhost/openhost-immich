# openhost-immich
#
# A single-container Immich deployment with an in-container OIDC
# bridge that authenticates the OpenHost compute-space owner via
# OpenHost's `X-OpenHost-Is-Owner: true` header, so Immich's OAuth
# Auto Launch lands an owner straight into the app without a
# separate Immich password.
#
# What runs inside this image:
#   * postgres 14 + VectorChord + pgvectors (Immich's required DB)
#   * valkey (Redis-compatible cache that Immich requires)
#   * immich-server (Node)
#   * immich-machine-learning (Python)
#   * oidc-bridge (small Python/Starlette app implementing the
#     subset of OIDC that Immich consumes)
#   * nginx (port 8080: routes /_oidc/* to the bridge, everything
#     else to immich-server)
#
# All processes are supervised by s6-overlay. We extend
# `imagegenius/docker-immich` (a community single-container Immich
# build that already has immich-server + ML and an s6 setup) and
# add the postgres + valkey + oidc-bridge + nginx pieces on top.
#
# Postgres binaries (with VectorChord and pgvectors loaded)
# are copied from the official `ghcr.io/immich-app/postgres:14-...`
# image via a multi-stage build, so we don't have to compile or
# package the extensions ourselves.

# ---------- stage: postgres image we mine for binaries+extensions ---

FROM ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0 AS pgsrc

# ---------- final image: extend the all-in-one Immich ---------------

FROM ghcr.io/imagegenius/immich:latest

ARG DEBIAN_FRONTEND=noninteractive

# Install the bits we need on top of the imagegenius base:
#   - postgresql-14 client+server (we ship our own server binaries
#     copied from `pgsrc` below; libpq for the immich client)
#   - valkey for the Redis-compatible cache
#   - nginx for the request router on :8080
#   - python3 + venv tools for the OIDC bridge
#
# imagegenius/immich is Ubuntu noble (24.04). Ubuntu's main repo
# doesn't have postgresql-14 (they're on 16); we install only the
# postgres client libraries from apt and rely on the binaries we
# copy from the upstream Immich postgres image for the server.
#
# Valkey is in Ubuntu noble as `valkey-server`.
RUN \
  apt-get update && \
  apt-get install -y --no-install-recommends \
    libpq5 \
    valkey-server \
    nginx \
    python3 \
    python3-venv \
    python3-pip \
    procps \
    ca-certificates && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/* && \
  rm -rf /etc/nginx/sites-enabled/default

# ---------- copy postgres-14 + extensions from the upstream image ---
#
# The upstream Immich postgres image is Debian-based and ships a
# customized PostgreSQL 14 with the VectorChord and pgvectors
# extensions enabled. We pull the binary tree, the extension files,
# and the runtime libraries out of that image so we can spawn the
# server inside our s6 setup.
COPY --from=pgsrc /usr/lib/postgresql /usr/lib/postgresql
COPY --from=pgsrc /usr/share/postgresql /usr/share/postgresql

# Some VectorChord extensions link against liblz4, libxxhash etc. The
# upstream image's libraries are newer than Ubuntu 24.04's defaults;
# install Ubuntu equivalents to satisfy the dynamic linker.
RUN \
  apt-get update && \
  apt-get install -y --no-install-recommends \
    libxxhash0 \
    liblz4-1 \
    libxslt1.1 \
    libxml2 \
    libldap2 \
    libsasl2-2 \
    libgssapi-krb5-2 \
    libcurl4 && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

# The postgres binaries are built against Debian bookworm; Ubuntu
# noble has different versions of several runtime libraries. Pull
# the entire Debian-bookworm version of each shared library postgres
# pins via SONAME from the pgsrc image. We list explicit library
# basenames rather than copying all of /usr/lib/x86_64-linux-gnu so
# we don't accidentally overwrite Ubuntu's own libraries that other
# parts of the image rely on (e.g. nginx, python, the imagegenius
# Node binary).
COPY --from=pgsrc /usr/lib/x86_64-linux-gnu/libldap-2.5.so.0* /usr/lib/x86_64-linux-gnu/
COPY --from=pgsrc /usr/lib/x86_64-linux-gnu/liblber-2.5.so.0* /usr/lib/x86_64-linux-gnu/
COPY --from=pgsrc /usr/lib/x86_64-linux-gnu/libicui18n.so.72* /usr/lib/x86_64-linux-gnu/
COPY --from=pgsrc /usr/lib/x86_64-linux-gnu/libicuuc.so.72* /usr/lib/x86_64-linux-gnu/
COPY --from=pgsrc /usr/lib/x86_64-linux-gnu/libicudata.so.72* /usr/lib/x86_64-linux-gnu/
COPY --from=pgsrc /usr/lib/x86_64-linux-gnu/libxml2.so.2* /usr/lib/x86_64-linux-gnu/
COPY --from=pgsrc /usr/lib/x86_64-linux-gnu/libxslt.so.1* /usr/lib/x86_64-linux-gnu/
RUN ldconfig 2>&1 | grep -v "is not a symbolic link" || true

# Add postgres binaries to PATH and create the postgres user that
# matches the upstream image's expectations. uid=999 mirrors what
# the upstream Debian package uses; pick something else if the
# imagegenius base already claims it (it doesn't on the noble base).
ENV PATH="/usr/lib/postgresql/14/bin:${PATH}"
# imagegenius/immich already has gid/uid 999 (the abc group) and may
# already have a `postgres` user from a transitive base layer. Be
# tolerant of either: only create the group/user if they don't exist,
# and don't insist on a specific uid. Make sure the home directory
# exists either way -- some su invocations warn if it doesn't.
RUN \
  if ! getent group postgres >/dev/null 2>&1; then \
    groupadd --system postgres; \
  fi && \
  if ! id postgres >/dev/null 2>&1; then \
    useradd --system -g postgres -d /var/lib/postgresql -s /bin/bash postgres; \
  fi && \
  install -d -o postgres -g postgres -m 0700 /var/lib/postgresql && \
  install -d -o postgres -g postgres -m 0755 /var/run/postgresql

# ---------- OIDC bridge (Python) ------------------------------------

COPY oidc-bridge/requirements.txt /usr/local/share/oidc-bridge/requirements.txt
COPY oidc-bridge/server.py /usr/local/share/oidc-bridge/server.py
# The imagegenius/immich base ships Python at /lsiopy (a uv-managed
# venv used by immich-machine-learning) and that's what `python3`
# resolves to on the PATH. uv-created venvs do NOT include pip by
# default, so we use uv (already present in the base image at /tmp
# during build, but not always in the final layer) to install our
# bridge deps directly into the /lsiopy venv. If uv isn't on PATH
# we download a one-off copy.
RUN \
  set -eux; \
  if ! command -v uv >/dev/null 2>&1; then \
    UV_VERSION=$(curl -fsSL https://api.github.com/repos/astral-sh/uv/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1); \
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" -o /tmp/uv.tgz; \
    tar -xzf /tmp/uv.tgz -C /tmp; \
    cp /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv; \
    chmod 0755 /usr/local/bin/uv; \
    rm -rf /tmp/uv.tgz /tmp/uv-x86_64-unknown-linux-gnu; \
  fi; \
  uv pip install --python /lsiopy/bin/python --no-cache \
    -r /usr/local/share/oidc-bridge/requirements.txt

# ---------- nginx config --------------------------------------------

COPY nginx.conf /etc/nginx/nginx.conf

# ---------- s6-overlay services --------------------------------------
#
# imagegenius/immich uses s6-overlay v3 (s6-rc). Each service is a
# directory under /etc/s6-overlay/s6-rc.d/<name>/ with at least
# `type` and `run` files. We add four services:
#   - openhost-init  (one-shot: prepares the persistent volume)
#   - postgres       (long-running)
#   - valkey         (long-running)
#   - oidc-bridge    (long-running)
#   - nginx          (long-running, depends on all of the above)
#
# Add each to the user bundle so s6 brings them up alongside the
# upstream services (immich-server, machine-learning).
COPY rootfs/ /

RUN \
  set -eux; \
  chmod 0755 \
    /etc/s6-overlay/s6-rc.d/openhost-init/run \
    /etc/s6-overlay/s6-rc.d/postgres/run \
    /etc/s6-overlay/s6-rc.d/postgres/finish \
    /etc/s6-overlay/s6-rc.d/valkey/run \
    /etc/s6-overlay/s6-rc.d/oidc-bridge/run \
    /etc/s6-overlay/s6-rc.d/oidc-bridge/finish \
    /etc/s6-overlay/s6-rc.d/nginx-front/run \
    /etc/s6-overlay/s6-rc.d/nginx-front/finish \
    /usr/local/bin/openhost-prepare.sh; \
  for svc in openhost-init postgres valkey oidc-bridge nginx-front; do \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/$svc; \
  done

# ---------- runtime config ------------------------------------------
#
# These environment variables are read by the imagegenius base
# image's existing s6 services and by ours. The values we set here
# are static at build time; openhost-prepare.sh fills in the rest
# (database password, OIDC client_secret) on first boot from the
# persistent volume, so they survive image updates.
ENV \
  # Immich points at our in-container Postgres + Valkey.
  DB_HOSTNAME="127.0.0.1" \
  DB_PORT="5432" \
  DB_USERNAME="immich" \
  DB_DATABASE_NAME="immich" \
  REDIS_HOSTNAME="127.0.0.1" \
  REDIS_PORT="6379" \
  # The DB and OIDC bridge live in the same container as immich,
  # accessible only over loopback. The "secret"-ness of these
  # values doesn't add security: anything that can read them is
  # already inside the container. Hardcoding lets us avoid the
  # tricky problem of getting random values generated at first
  # boot to be visible to the imagegenius init scripts that read
  # DB_PASSWORD before our own init runs.
  DB_PASSWORD="immich-loopback-only" \
  OIDC_CLIENT_ID="openhost-immich" \
  OIDC_CLIENT_SECRET="openhost-immich-loopback-only" \
  # Move Immich's HTTP server off 8080 (which is nginx) and ML off
  # 3003 (its default).
  SERVER_HOST="127.0.0.1" \
  SERVER_PORT="2283" \
  MACHINE_LEARNING_HOST="127.0.0.1" \
  MACHINE_LEARNING_PORT="3003" \
  # Tell Immich to read its system config (with OAuth pre-baked) from
  # this path. openhost-init writes the file on every boot so the
  # OAuth settings come from the pre-baked client_id/client_secret/
  # issuer URL rather than requiring an admin to fill them in.
  IMMICH_CONFIG_FILE="/data/app_data/immich/config/system.json" \
  # Run immich as the container's root user (UID 0 inside the
  # container). Under rootless podman that maps to an unprivileged
  # host UID, so it's not a privilege escalation; and it sidesteps
  # the rootless-volume permissions issue where the OpenHost-mounted
  # volume comes in owned by host root and a different in-container
  # UID cannot write to it.
  PUID="0" \
  PGID="0"

EXPOSE 8080
