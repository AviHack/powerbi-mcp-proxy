# Architecture

## Overview

`powerbi-mcp-proxy` is a remote HTTP server implementing the Model Context Protocol. Each user authenticates with their own Microsoft account via Entra ID; the server exchanges that token via On-Behalf-Of (OBO) for a Power BI API token so queries run with the user's own RLS permissions.

![Architecture diagram](assets/architecture.svg)

## Auth flow

```
1. MCP client fetches /.well-known/oauth-protected-resource
2. Client registers via Dynamic Client Registration (DCR), restricted to MCP_ALLOWED_REDIRECT_URIS
3. User is redirected to login.microsoftonline.com (proxied through this server)
4. Server receives the auth code, exchanges with Entra ID, issues a short-lived JWT to the client
5. On each tool call, OnBehalfOfCredential exchanges the user's token for a Power BI API token
6. The DAX query runs against Power BI as that user — their RLS applies
```

## Components

| Component | Role |
|-----------|------|
| FastMCP | MCP protocol server, tool dispatch |
| `AzureProvider` (FastMCP) | OAuth proxy, DCR, JWT validation |
| `OnBehalfOfCredential` (`azure-identity`) | OBO token exchange per request, per user |
| Azure App Service (recommended) | HTTPS termination, hosting |
| Azure Key Vault (recommended) | `PBI_CLIENT_SECRET`, `JWT_SIGNING_KEY` |
| GitHub Actions + OIDC (optional) | Manual deploy workflow for your own repo without stored Azure credentials |

## Data flow

```
User asks question in MCP client
    → Client calls a tool (e.g. run_dax_query)
        → Server validates the user's JWT (signature, audience, issuer, expiry, scopes)
        → OBO exchange: user JWT → Power BI access token (scoped to that user)
        → POST /executeQueries to api.powerbi.com
            → Power BI resolves the query under the user's RLS
            → Results flow back through the same chain
        → Server returns rows to the client
    → Client renders for the user
```

## Why this exists vs. Microsoft's hosted endpoint

Microsoft's hosted Power BI MCP server at `api.fabric.microsoft.com/v1/mcp/powerbi` emits a `resourceUrl` field in its OAuth discovery response, which causes the v2 Entra endpoint to reject the authorization request with `AADSTS9010010`. See [microsoft/powerbi-modeling-mcp#68](https://github.com/microsoft/powerbi-modeling-mcp/issues/68). This server uses FastMCP's `AzureProvider` directly, which does not emit that field, so OAuth completes cleanly with all current MCP clients.

The cost is that you self-host: your own Entra app, your own deployment, your own user management.

## Network surface

The server makes outbound calls only to:

- `login.microsoftonline.com` — OAuth, OBO exchange
- `api.powerbi.com` — Power BI REST API

It does not need access to your internal network. Power BI itself handles any on-prem gateway connection to your data sources.

Inbound: HTTPS from the public internet (or your VNet, if you front it with a private endpoint).
