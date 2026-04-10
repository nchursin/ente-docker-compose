# Setup History (March 2026)

Notes from the initial deployment on `192.168.88.228`. Kept for reference in
case things break or need debugging in the future.

---

## How It Was Set Up

1. Secrets were generated with `openssl rand` (base64 and hex)
2. `compose.yml`, `garage.toml`, `garage-init.py`, `setup.sh` were created
3. `garage-init.py` uses Garage's **v2 admin HTTP API** because the Garage
   Docker image (`dxflrs/garage:v2.2.0`) is distroless — no shell, no CLI
   access. A Python container (`python:3.13-slim-bookworm`) is used as the
   init container instead.
4. The Garage v2 API has quirks (see below)
5. Museum port was changed from 8080 → 8081 (conflict with existing
   `rook1e404/fusion` container on the server)
6. Alpine-based images were avoided for init containers due to known
   musl/networking issues
7. S3 endpoint in museum config uses the LAN IP (not `localhost:3200`) —
   because phones upload directly to presigned S3 URLs, which must be
   reachable from the client device. Garage S3 port 3900 is exposed as
   host port 3200.
8. CORS must be set on all Garage buckets (`PutBucketCors` via S3 API) for
   the web UI to work. `garage-init.py` does this automatically using AWS
   Signature V4 signing. Without CORS, the browser blocks PUT requests to S3.

---

## Garage v2 Admin API Quirks

These were discovered the hard way during initial setup. The OpenAPI spec at
`https://garagehq.deuxfleurs.fr/api/garage-admin-v2.json` is misleading in
several places.

### UpdateClusterLayout

The OpenAPI spec says the request body is a single object with a `nodeId` field.
**Wrong.** The actual Rust struct (`UpdateClusterLayoutRequest`) expects:

```json
{
  "roles": [
    {
      "id": "32a356d2d4b051b820b959c070aaab33...",
      "zone": "dc1",
      "capacity": 1073741824,
      "tags": []
    }
  ]
}
```

Key differences from the spec:
- The field is `id`, not `nodeId`
- The array is wrapped in a `roles` key (the spec shows a flat object)
- The `#[serde(flatten)]` on the action enum means zone/capacity/tags are
  flattened into the same object as `id`
- The `#[serde(untagged)]` on `NodeRoleChangeEnum` means you just put the
  fields directly — no discriminator

Source: `src/api/admin/api.rs` in the Garage repo, tag `v2.2.0`.

### Auth Required Everywhere

All admin endpoints require `Authorization: Bearer <token>` — including
`/v2/GetClusterHealth`. The health check without auth returns 403.

### v1 Endpoints Removed

Garage v2.2.0 has completely removed v1 endpoints. Calling `/v1/layout` returns:
```
Bad request: v1/ endpoint is no longer supported: UpdateClusterLayout
```

### Distroless Image

`dxflrs/garage:v2.2.0` has no shell (`/bin/sh` doesn't exist). The only binary
is `/garage`. This means you can't `docker exec` into it with a shell, and init
scripts must use a separate container.

---

## Shell Script JSON Parsing Failures

The original `garage-init.sh` (shell script) failed repeatedly because:

1. `sed` couldn't reliably extract JSON fields from multiline responses
2. Shell variable expansion mangled JSON brackets and quotes
3. The `curlimages/curl` image has `curl` as its entrypoint, so
   `command: sh /script.sh` actually runs `curl sh /script.sh`
4. Alpine-based images had DNS/networking issues

After multiple iterations, the init script was rewritten in Python
(`garage-init.py`), which solved all JSON parsing and HTTP issues immediately.

---

## S3 Endpoint: localhost vs LAN IP

### The Problem

Museum generates **presigned S3 URLs** and returns them to clients (phones, web
browser). The client then uploads directly to those URLs. If the S3 endpoint in
museum's config is `localhost:3200`, the presigned URL will contain
`localhost:3200` — which the phone tries to connect to its own localhost.

### The Fix

The S3 endpoint in museum config was changed from `http://localhost:3200` to
`http://192.168.88.228:3200` (the server's LAN IP). Garage's S3 port (3900) is
exposed as host port 3200 in the compose file.

### localhost IPv4 vs IPv6

Even for internal connectivity, `localhost` caused issues. Inside the container,
`localhost` resolved to `::1` (IPv6), but socat only listened on IPv4
(`0.0.0.0:3200`). The fix was to use `127.0.0.1` explicitly, but ultimately the
LAN IP approach superseded this.

---

## CORS

The web UI uploads photos directly to S3 from the browser. Without CORS headers
on the Garage S3 endpoint, browsers block the PUT requests.

Garage doesn't have a CORS config option in `garage.toml`. Instead, CORS is set
via the standard S3 `PutBucketCors` API. The `garage-init.py` script does this
automatically using AWS Signature V4 signing (implemented in pure Python with
`hmac` and `hashlib`).

The CORS policy allows all origins (`*`), which is fine for a LAN-only setup.

---

## Storage Limit

New Ente accounts get a 10 GB free-tier limit by default. This is stored in the
`subscriptions` table in Postgres. The `storage-fix.sql` script updates all
users to 100 TB with 100-year validity:

```sql
UPDATE subscriptions
SET storage = 109951162777600,
    expiry_time = EXTRACT(EPOCH FROM (NOW() + INTERVAL '100 years')) * 1000000
WHERE storage < 109951162777600;
```

Must be run after each new user signs up.

---

## Backup: Ente CLI

The Ente CLI (`ente-cli`) is distributed as a binary from GitHub releases (not
a Docker image — `ghcr.io/ente-io/cli` doesn't exist). On headless servers, it
fails with a keyring error:

```
error getting password from keyring: The name is not activatable
```

The fix is setting `ENTE_CLI_SECRETS_PATH` environment variable to point to a
plain text file, bypassing the system keyring entirely.

The CLI also writes temp files to `/tmp/ente-download/` during export. If `/tmp`
is a small tmpfs (RAM-backed), exports fail with "disk quota exceeded". Fix:
`rm -rf /tmp/ente-download/` between runs, or set `TMPDIR` to a larger disk.

---

## Port Assignments (on 192.168.88.228)

| Port | Service | Notes |
|------|---------|-------|
| 8081 | museum (Ente API) | Changed from 8080 (conflict with fusion) |
| 3000-3004 | web (Photos/Accounts/Albums/Auth/Cast) | |
| 3200 | Garage S3 (mapped from 3900) | Must be reachable from LAN clients |
| 3901 | Garage RPC | Internal only |
| 3903 | Garage admin API | Internal only |
| 5432 | Postgres | Internal only |
