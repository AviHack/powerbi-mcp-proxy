#!/usr/bin/env python3
"""
pbi_mcp_remote.py — Self-hosted remote MCP server for Power BI.

Workaround for the broken Microsoft-hosted Power BI MCP endpoint
(api.fabric.microsoft.com/v1/mcp/powerbi) which fails with AADSTS9010010
because its OAuth discovery emits a `resource` parameter against the
Entra v2 endpoint. This server performs the OAuth proxy itself via
FastMCP's AzureProvider and never emits that field.

Each user signs in with their own Microsoft account; queries run via
On-Behalf-Of token exchange so Power BI RLS applies per user.

Startup (local):
    uvicorn pbi_mcp_remote:app --host 127.0.0.1 --port 8000

Startup (production behind gunicorn):
    gunicorn -k uvicorn.workers.UvicornWorker pbi_mcp_remote:app
"""

import asyncio
import hashlib
import logging
import os
from collections import OrderedDict
from urllib.parse import urlparse

# Stateless HTTP must be set before FastMCP initializes — keep at top.
os.environ.setdefault("FASTMCP_STATELESS_HTTP", "true")

import httpx
from azure.identity.aio import OnBehalfOfCredential
from fastmcp import FastMCP
from fastmcp.server.auth.providers.azure import AzureProvider
from fastmcp.server.dependencies import get_access_token

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("pbi_mcp")

# ---------------------------------------------------------------------------
# Configuration from environment, with defensive validation
# ---------------------------------------------------------------------------
PBI_CLIENT_ID = os.environ["PBI_CLIENT_ID"]
PBI_CLIENT_SECRET = os.environ["PBI_CLIENT_SECRET"]
PBI_TENANT_ID = os.environ["PBI_TENANT_ID"]
JWT_SIGNING_KEY = os.environ["JWT_SIGNING_KEY"]
MCP_SERVER_URL = os.environ.get("MCP_SERVER_URL", "http://localhost:8000")

# Comma-separated list of redirect URI patterns allowed to register via DCR.
# Defaults to Claude.ai. Add ChatGPT, Copilot CLI, etc. as needed.
_default_redirects = "https://claude.ai/api/mcp/*"
MCP_ALLOWED_REDIRECT_URIS = [
    s.strip() for s in os.environ.get("MCP_ALLOWED_REDIRECT_URIS", _default_redirects).split(",")
    if s.strip()
]

PBI_SCOPES = ["https://analysis.windows.net/powerbi/api/.default"]
PBI_API = "https://api.powerbi.com/v1.0/myorg"

# --- Multi-tenant footgun guard ---
# "common", "organizations", "consumers" cause FastMCP's AzureProvider to
# skip issuer validation, allowing any Microsoft account to authenticate.
# This is almost never what you want for a server holding OBO secrets.
if PBI_TENANT_ID.lower() in {"common", "organizations", "consumers", ""}:
    raise RuntimeError(
        f"PBI_TENANT_ID={PBI_TENANT_ID!r} is multi-tenant and disables issuer validation. "
        "Set PBI_TENANT_ID to a specific tenant GUID (e.g. 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')."
    )

# --- Plaintext-HTTP guard for non-localhost deployments ---
_parsed = urlparse(MCP_SERVER_URL)
if _parsed.scheme == "http" and _parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
    raise RuntimeError(
        f"MCP_SERVER_URL={MCP_SERVER_URL!r} uses http:// on a non-localhost host. "
        "OAuth tokens would transit in plaintext. Use https:// for any deployed server."
    )

# --- Redirect-allowlist sanity ---
if not MCP_ALLOWED_REDIRECT_URIS or "*" in MCP_ALLOWED_REDIRECT_URIS:
    raise RuntimeError(
        "MCP_ALLOWED_REDIRECT_URIS must list specific client callbacks (path wildcards "
        "OK, e.g. 'https://claude.ai/api/mcp/*'), never a bare '*'. A bare wildcard "
        "lets attackers register clients that intercept tokens."
    )

log.info(
    "config loaded tenant=%s server_url=%s redirect_count=%d",
    PBI_TENANT_ID, MCP_SERVER_URL, len(MCP_ALLOWED_REDIRECT_URIS),
)

# OBO credential cache — reuse credentials per bearer token (LRU, max 128).
#
# Keyed by SHA-256(token), not by user OID, so we don't have to parse claims.
# Trade-off: when a user's session refreshes, the new token is a new key and
# the old entry sits idle until LRU evicts it. In-memory only by design;
# do NOT back this with Redis or similar — tokens would leave process scope.
_obo_cache: OrderedDict[str, OnBehalfOfCredential] = OrderedDict()
_obo_lock = asyncio.Lock()
_OBO_CACHE_MAX = 128


# ---------------------------------------------------------------------------
# Manual OBO exchange.
#
# FastMCP ships an EntraOBOToken helper, but it has been observed to fail in
# our setup; doing the exchange ourselves with azure-identity is reliable.
# ---------------------------------------------------------------------------

async def _get_pbi_token() -> str:
    """Exchange the authenticated user's token for a Power BI API token via OBO."""
    access_token = get_access_token()
    if access_token is None:
        raise RuntimeError("No access token available. User may not be authenticated.")

    key = hashlib.sha256(access_token.token.encode()).hexdigest()

    async with _obo_lock:
        if key in _obo_cache:
            _obo_cache.move_to_end(key)
            credential = _obo_cache[key]
        else:
            credential = OnBehalfOfCredential(
                tenant_id=PBI_TENANT_ID,
                client_id=PBI_CLIENT_ID,
                client_secret=PBI_CLIENT_SECRET,
                user_assertion=access_token.token,
            )
            _obo_cache[key] = credential
            while len(_obo_cache) > _OBO_CACHE_MAX:
                _, evicted = _obo_cache.popitem(last=False)
                await evicted.close()

    result = await credential.get_token(*PBI_SCOPES)
    return result.token


# ---------------------------------------------------------------------------
# Auth provider
# ---------------------------------------------------------------------------
auth = AzureProvider(
    client_id=PBI_CLIENT_ID,
    client_secret=PBI_CLIENT_SECRET,
    tenant_id=PBI_TENANT_ID,
    required_scopes=["MCP.Access"],
    additional_authorize_scopes=["https://analysis.windows.net/powerbi/api/Dataset.Read.All"],
    base_url=MCP_SERVER_URL,
    jwt_signing_key=JWT_SIGNING_KEY,
    require_authorization_consent=True,
    allowed_client_redirect_uris=MCP_ALLOWED_REDIRECT_URIS,
    enable_cimd=False,
)

# ---------------------------------------------------------------------------
# FastMCP server
# ---------------------------------------------------------------------------
mcp = FastMCP(
    "powerbi",
    instructions=(
        "Query Power BI data with the signed-in user's permissions. "
        "Use list_workspaces and list_datasets to discover available data, "
        "then run_dax_query for ad-hoc DAX. Queries must start with EVALUATE."
    ),
    auth=auth,
)


# ---------------------------------------------------------------------------
# Discovery tools
# ---------------------------------------------------------------------------

@mcp.tool()
async def list_workspaces() -> list[dict]:
    """List Power BI workspaces you have access to. Returns name and ID for each."""
    token = await _get_pbi_token()
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.get(
            f"{PBI_API}/groups",
            headers={"Authorization": f"Bearer {token}"},
        )
        log.info(f"Power BI /groups: HTTP {resp.status_code}")
        if resp.status_code in (401, 403):
            raise PermissionError("Permission denied. Your account may not have Power BI Pro.")
        resp.raise_for_status()
        return [{"name": g["name"], "id": g["id"]} for g in resp.json()["value"]]


@mcp.tool()
async def list_datasets(workspace_id: str) -> list[dict]:
    """List datasets in a Power BI workspace. Returns name and ID for each."""
    token = await _get_pbi_token()
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.get(
            f"{PBI_API}/groups/{workspace_id}/datasets",
            headers={"Authorization": f"Bearer {token}"},
        )
        log.info(f"Power BI /datasets: HTTP {resp.status_code}")
        if resp.status_code in (401, 403):
            raise PermissionError("Permission denied. You may not have access to this workspace.")
        resp.raise_for_status()
        return [{"name": d["name"], "id": d["id"]} for d in resp.json()["value"]]


# ---------------------------------------------------------------------------
# Generic DAX query tool
# ---------------------------------------------------------------------------

@mcp.tool()
async def run_dax_query(
    query: str,
    dataset_id: str,
    workspace_id: str,
) -> dict:
    """Execute a DAX query against a Power BI dataset.

    Use list_workspaces and list_datasets first to find workspace_id and
    dataset_id. The query must start with EVALUATE.
    """
    token = await _get_pbi_token()
    async with httpx.AsyncClient(timeout=60) as client:
        resp = await client.post(
            f"{PBI_API}/groups/{workspace_id}/datasets/{dataset_id}/executeQueries",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "queries": [{"query": query}],
                "serializerSettings": {"includeNulls": True},
            },
        )
        log.info(f"Power BI /executeQueries: HTTP {resp.status_code}")
        if resp.status_code == 400:
            raise ValueError("DAX query error. Check syntax and table/column names.")
        if resp.status_code in (401, 403):
            raise PermissionError("Permission denied. You may not have access to this dataset.")
        resp.raise_for_status()
        rows = []
        for r in resp.json().get("results", []):
            for table in r.get("tables", []):
                rows.extend(table.get("rows", []))
        return {"rows": rows, "row_count": len(rows)}


# ---------------------------------------------------------------------------
# Schema-introspection helpers (intentionally not implemented)
#
# REST /tables returns 404 on imported (non-Premium/XMLA) datasets, and the
# DAX INFO.* / TMSCHEMA DMVs are also blocked. The honest answer is "use
# run_dax_query to probe a specific name." We expose stubs so users see the
# guidance instead of guessing why discovery silently fails.
# ---------------------------------------------------------------------------

@mcp.tool()
async def list_measures(dataset_id: str, workspace_id: str) -> list[dict]:
    """List all measures in a Power BI dataset. (Unsupported on imported datasets.)"""
    raise NotImplementedError(
        "Schema enumeration is unsupported for imported Power BI datasets. "
        "The REST /tables endpoint returns 404 and DAX INFO.*/TMSCHEMA DMVs are "
        "blocked without XMLA/Premium. Use run_dax_query to probe a specific measure: "
        'EVALUATE ROW("exists", [YourMeasureName])'
    )


@mcp.tool()
async def list_columns(table_name: str, dataset_id: str, workspace_id: str) -> list[dict]:
    """List all columns for a table in a Power BI dataset. (Unsupported on imported datasets.)"""
    raise NotImplementedError(
        "Schema enumeration is unsupported for imported Power BI datasets. "
        "The REST /tables endpoint returns 404 and DAX INFO.*/TMSCHEMA DMVs are "
        "blocked without XMLA/Premium. Use run_dax_query to probe a specific column: "
        f"EVALUATE VALUES('{table_name}'[YourColumnName])"
    )


# ---------------------------------------------------------------------------
# ASGI app for gunicorn / uvicorn
# ---------------------------------------------------------------------------
app = mcp.http_app(json_response=True)
