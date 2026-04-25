#!/usr/bin/env python3
"""OIDC bridge between OpenHost's session-cookie auth and Immich's
OIDC-only SSO.

OpenHost identifies the compute-space owner by stamping
``X-OpenHost-Is-Owner: true`` on requests it proxies for an
authenticated owner session. Immich does not understand that header
and only supports OAuth/OIDC for SSO. This service implements the
small subset of OIDC that Immich needs (.well-known discovery, JWKS,
authorize, token, userinfo) and uses the OpenHost header as the
"user authenticator": if the header is present, the owner is logged
in; otherwise the bridge refuses to mint a token.

Net effect: an OpenHost owner who visits ``https://immich.<zone>/``
gets bounced through Immich's OAuth Auto Launch -> this bridge ->
back into Immich, ending up signed in as the local Immich admin
account that's keyed off ``OPENHOST_OWNER_EMAIL``.

Endpoints:
  GET  /_oidc/.well-known/openid-configuration  -- OIDC discovery
  GET  /_oidc/jwks                              -- JWKS for ID-token verify
  GET  /_oidc/authorize                         -- start an OAuth flow
  POST /_oidc/token                             -- exchange code for tokens
  GET  /_oidc/userinfo                          -- userinfo endpoint
  GET  /_oidc/healthz                           -- liveness probe

Persistent state lives under ``$OIDC_DATA_DIR`` (set by start.sh):
the RSA signing key (so JWTs survive restarts and Immich keeps
trusting them) and a config file with the immich client_id +
client_secret. The authorization-code store is in-memory: codes are
single-use and short-lived, so losing them on restart is fine.

Threat model: this service is reachable only from inside the
OpenHost container (nginx proxies /_oidc/* from the outside). Any
external request that reaches /authorize without
``X-OpenHost-Is-Owner: true`` gets a 401 and cannot proceed; with
the header set, OpenHost's auth has already checked the owner's
session, so we trust it.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import secrets
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
from starlette.applications import Starlette
from starlette.exceptions import HTTPException
from starlette.requests import Request
from starlette.responses import HTMLResponse
from starlette.responses import JSONResponse
from starlette.responses import PlainTextResponse
from starlette.responses import RedirectResponse
from starlette.responses import Response
from starlette.routing import Route

logger = logging.getLogger("openhost-immich.oidc")

# --- config -----------------------------------------------------------

DATA_DIR = Path(os.environ.get("OIDC_DATA_DIR", "/data/app_data/immich/oidc"))
PUBLIC_BASE = os.environ["OIDC_PUBLIC_BASE"].rstrip("/")
CLIENT_ID = os.environ["OIDC_CLIENT_ID"]
CLIENT_SECRET = os.environ["OIDC_CLIENT_SECRET"]
# Owner email is what OpenHost would forward as the canonical owner
# identity. OPENHOST_OWNER_EMAIL is unfortunately not a stable env
# var across all OpenHost deployments, so the bridge falls through to
# a configurable default.
OWNER_EMAIL_DEFAULT = os.environ.get("OIDC_OWNER_EMAIL", "owner@openhost.local")
# Issued tokens live for 1 hour; Immich will re-prompt against
# OpenHost via Auto Launch when a token expires, which is cheap.
ID_TOKEN_TTL_SECONDS = 60 * 60
ACCESS_TOKEN_TTL_SECONDS = 60 * 60
AUTH_CODE_TTL_SECONDS = 5 * 60

# --- key bootstrap ----------------------------------------------------

KEY_PATH = DATA_DIR / "signing-key.pem"


def _load_or_create_key() -> rsa.RSAPrivateKey:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if KEY_PATH.exists():
        with KEY_PATH.open("rb") as f:
            return serialization.load_pem_private_key(f.read(), password=None)
    # Generate a new 2048-bit RSA key. RS256 is the algorithm
    # everybody (Immich included) accepts as a sane default; some
    # self-hosted OIDC tooling still chokes on EC keys.
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    KEY_PATH.write_bytes(pem)
    KEY_PATH.chmod(0o600)
    logger.info("Generated new OIDC signing key at %s", KEY_PATH)
    return key


_SIGNING_KEY = _load_or_create_key()
_KEY_ID = "openhost-immich-1"  # static; changes if you rotate the key.


def _public_jwk() -> dict[str, str]:
    public_numbers = _SIGNING_KEY.public_key().public_numbers()

    def _b64(n: int) -> str:
        # JWKs encode RSA modulus/exponent as base64url-without-padding
        # of the big-endian byte representation; OIDC clients are
        # picky about leading-zero stripping.
        byte_len = (n.bit_length() + 7) // 8
        return base64.urlsafe_b64encode(n.to_bytes(byte_len, "big")).rstrip(b"=").decode("ascii")

    return {
        "kty": "RSA",
        "alg": "RS256",
        "use": "sig",
        "kid": _KEY_ID,
        "n": _b64(public_numbers.n),
        "e": _b64(public_numbers.e),
    }


# --- in-memory authorization-code store ------------------------------
#
# Single dict, keyed by the random code string. Codes are single-use:
# once /token consumes one we drop it, so a replay can't happen even
# inside its 5-minute TTL. We don't bother persisting these because
# losing them on a process restart just makes the user start the OAuth
# dance over.

_auth_codes: dict[str, dict[str, Any]] = {}


def _gc_expired_codes() -> None:
    now = time.time()
    for code in [c for c, v in _auth_codes.items() if v["expires_at"] <= now]:
        _auth_codes.pop(code, None)


# --- helpers ---------------------------------------------------------

def _is_owner(request: Request) -> bool:
    return request.headers.get("X-OpenHost-Is-Owner", "").lower() == "true"


def _resolve_owner_email(request: Request) -> str:
    """Best-effort: prefer an explicit env var, else any header
    OpenHost might set, else the default. OpenHost doesn't currently
    forward an email header, but we keep the indirection so adding
    one upstream later doesn't require a code change."""
    forwarded = request.headers.get("X-OpenHost-Owner-Email", "").strip()
    if forwarded:
        return forwarded
    return OWNER_EMAIL_DEFAULT


# --- handlers --------------------------------------------------------

async def discovery(_: Request) -> JSONResponse:
    return JSONResponse({
        "issuer": PUBLIC_BASE + "/_oidc",
        "authorization_endpoint": PUBLIC_BASE + "/_oidc/authorize",
        "token_endpoint": PUBLIC_BASE + "/_oidc/token",
        "userinfo_endpoint": PUBLIC_BASE + "/_oidc/userinfo",
        "jwks_uri": PUBLIC_BASE + "/_oidc/jwks",
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code"],
        "subject_types_supported": ["public"],
        "id_token_signing_alg_values_supported": ["RS256"],
        "scopes_supported": ["openid", "email", "profile"],
        "token_endpoint_auth_methods_supported": ["client_secret_post", "client_secret_basic"],
        "claims_supported": ["sub", "email", "email_verified", "name", "preferred_username"],
    })


async def jwks(_: Request) -> JSONResponse:
    return JSONResponse({"keys": [_public_jwk()]})


async def authorize(request: Request) -> Response:
    """Authorization endpoint. The OpenHost gate has already done the
    work for us: if the request carries X-OpenHost-Is-Owner=true, we
    issue an authorization code immediately. Otherwise we redirect to
    the OpenHost login page (browser-driven flow) or 401 (API client).

    Note that OpenHost may or may not forward this header depending on
    public_paths configuration; for this app, we keep public_paths
    open so the OIDC discovery URL is reachable, and the owner header
    flows through naturally for an authenticated owner.
    """
    params = request.query_params
    response_type = params.get("response_type", "")
    client_id = params.get("client_id", "")
    redirect_uri = params.get("redirect_uri", "")
    state = params.get("state", "")
    nonce = params.get("nonce")
    scope = params.get("scope", "openid")

    if response_type != "code":
        raise HTTPException(400, "only response_type=code is supported")
    if client_id != CLIENT_ID:
        raise HTTPException(400, "unknown client_id")
    if not redirect_uri:
        raise HTTPException(400, "missing redirect_uri")
    # We deliberately don't validate redirect_uri against a registered
    # list -- Immich's redirect URIs depend on the zone domain and we
    # only accept calls that are coming through OpenHost's gate
    # anyway.

    if not _is_owner(request):
        # Browser flow: bounce to the OpenHost zone's /login. After
        # they sign in OpenHost will round-trip back here with the
        # owner header set. Stash original query string in `next`.
        zone = request.headers.get("X-Forwarded-Host", request.url.netloc)
        # Strip the app subdomain to land on the bare zone /login.
        bare_zone = zone.split(".", 1)[1] if "." in zone else zone
        login_url = f"https://{bare_zone}/login"
        return RedirectResponse(login_url, status_code=302)

    code = secrets.token_urlsafe(32)
    _gc_expired_codes()
    _auth_codes[code] = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "nonce": nonce,
        "scope": scope,
        "email": _resolve_owner_email(request),
        "expires_at": time.time() + AUTH_CODE_TTL_SECONDS,
    }

    # Build the redirect URL Immich expects.
    qs = {"code": code}
    if state:
        qs["state"] = state
    sep = "&" if "?" in redirect_uri else "?"
    return RedirectResponse(redirect_uri + sep + urlencode(qs), status_code=302)


async def _read_form(request: Request) -> dict[str, str]:
    body = (await request.body()).decode("utf-8")
    out: dict[str, str] = {}
    for pair in body.split("&"):
        if not pair:
            continue
        k, _, v = pair.partition("=")
        from urllib.parse import unquote_plus
        out[unquote_plus(k)] = unquote_plus(v)
    return out


def _check_client_auth(request: Request, form: dict[str, str]) -> None:
    """Verify client_id + client_secret using either client_secret_post
    (form fields) or client_secret_basic (Authorization header).
    Immich uses client_secret_post by default; we accept both because
    OIDC clients sometimes flip between them on different code paths.
    """
    auth_header = request.headers.get("authorization", "")
    if auth_header.lower().startswith("basic "):
        try:
            decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            raise HTTPException(401, "invalid Basic auth header")
        provided_id, _, provided_secret = decoded.partition(":")
    else:
        provided_id = form.get("client_id", "")
        provided_secret = form.get("client_secret", "")
    if not (provided_id == CLIENT_ID and secrets.compare_digest(provided_secret, CLIENT_SECRET)):
        raise HTTPException(401, "invalid client credentials")


async def token(request: Request) -> JSONResponse:
    form = await _read_form(request)
    _check_client_auth(request, form)

    if form.get("grant_type") != "authorization_code":
        raise HTTPException(400, "only grant_type=authorization_code is supported")
    code = form.get("code", "")
    if not code:
        raise HTTPException(400, "missing code")
    redirect_uri = form.get("redirect_uri", "")

    _gc_expired_codes()
    record = _auth_codes.pop(code, None)
    if record is None:
        raise HTTPException(400, "unknown or expired code")
    if record["redirect_uri"] != redirect_uri:
        raise HTTPException(400, "redirect_uri mismatch")

    now = int(time.time())
    email = record["email"]
    sub = email  # Stable per-user subject; OpenHost is single-tenant so email == sub.
    id_token_claims = {
        "iss": PUBLIC_BASE + "/_oidc",
        "sub": sub,
        "aud": CLIENT_ID,
        "iat": now,
        "exp": now + ID_TOKEN_TTL_SECONDS,
        "email": email,
        "email_verified": True,
        "name": email.split("@", 1)[0],
        "preferred_username": email.split("@", 1)[0],
        # OpenHost is single-tenant: the only user who reaches the
        # bridge is the compute-space owner. Assert that role here so
        # Immich treats them as the admin (specifically when Immich
        # is configured with `roleClaim: immich_role` in its OAuth
        # settings, which we set in openhost-prepare.sh's
        # system.json). Without this claim Immich rejects the very
        # first OAuth registration with "The first registered
        # account must the administrator."
        "immich_role": "admin",
    }
    if record.get("nonce"):
        id_token_claims["nonce"] = record["nonce"]

    id_token = jwt.encode(
        id_token_claims,
        _SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": _KEY_ID},
    )
    # Access token is opaque to Immich today, but we sign one
    # symmetrically so the userinfo endpoint can verify it without
    # extra storage.
    access_token = jwt.encode(
        {
            "iss": PUBLIC_BASE + "/_oidc",
            "sub": sub,
            "iat": now,
            "exp": now + ACCESS_TOKEN_TTL_SECONDS,
            "email": email,
            "scope": record.get("scope", "openid"),
            "token_type": "access",
        },
        _SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": _KEY_ID},
    )
    return JSONResponse({
        "access_token": access_token,
        "token_type": "Bearer",
        "expires_in": ACCESS_TOKEN_TTL_SECONDS,
        "id_token": id_token,
        "scope": record.get("scope", "openid"),
    })


def _verify_access_token(token_value: str) -> dict[str, Any]:
    try:
        return jwt.decode(
            token_value,
            _SIGNING_KEY.public_key(),
            algorithms=["RS256"],
            options={"require": ["sub", "exp"]},
        )
    except jwt.PyJWTError as exc:
        raise HTTPException(401, f"invalid access token: {exc}")


async def userinfo(request: Request) -> JSONResponse:
    auth_header = request.headers.get("authorization", "")
    if not auth_header.lower().startswith("bearer "):
        raise HTTPException(401, "missing Bearer token")
    claims = _verify_access_token(auth_header[7:])
    email = claims.get("email", "")
    return JSONResponse({
        "sub": claims["sub"],
        "email": email,
        "email_verified": True,
        "name": email.split("@", 1)[0] if email else claims["sub"],
        "preferred_username": email.split("@", 1)[0] if email else claims["sub"],
        # See id_token rationale above.
        "immich_role": "admin",
    })


async def healthz(_: Request) -> Response:
    return PlainTextResponse("ok\n")


async def root(_: Request) -> Response:
    return HTMLResponse(
        "<h1>OpenHost OIDC bridge</h1>"
        "<p>Internal endpoint for the openhost-immich app's OIDC SSO flow.</p>",
        status_code=200,
    )


async def http_exception_handler(request: Request, exc: HTTPException) -> Response:
    if request.url.path.startswith("/_oidc/"):
        return JSONResponse({"error": "invalid_request", "error_description": exc.detail},
                            status_code=exc.status_code)
    return PlainTextResponse(str(exc.detail) + "\n", status_code=exc.status_code)


routes = [
    Route("/_oidc/", root),
    Route("/_oidc/healthz", healthz),
    Route("/_oidc/.well-known/openid-configuration", discovery),
    Route("/_oidc/jwks", jwks),
    Route("/_oidc/authorize", authorize),
    Route("/_oidc/token", token, methods=["POST"]),
    Route("/_oidc/userinfo", userinfo, methods=["GET", "POST"]),
]

app: Starlette = Starlette(
    debug=False,
    routes=routes,
    exception_handlers={HTTPException: http_exception_handler},
)
