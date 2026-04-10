#!/usr/bin/env python3
"""One-shot Garage init: creates layout, buckets, API key, and CORS."""

import base64
import datetime
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.request
import urllib.error

HOST = "garage"
ADMIN = f"http://{HOST}:3903"
S3 = f"http://{HOST}:3900"
TOKEN = os.environ.get("GARAGE_ADMIN_TOKEN", "")
REGION = "garage"
BUCKETS = ["b2-eu-cen", "wasabi-eu-central-2-v3", "scw-eu-fr-v3"]

if not TOKEN:
    print("ERROR: GARAGE_ADMIN_TOKEN environment variable not set")
    sys.exit(1)


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"{ADMIN}{path}",
        data=data,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        print(f"  ERROR {e.code} on {method} {path}: {err_body}")
        raise


def s3_put(bucket, query, payload, access_key, secret_key):
    """PUT to S3 with AWS Signature V4."""
    now = datetime.datetime.now(datetime.timezone.utc)
    date_stamp = now.strftime("%Y%m%d")
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")

    payload_hash = hashlib.sha256(payload).hexdigest()
    content_md5 = base64.b64encode(hashlib.md5(payload).digest()).decode()
    host = f"{HOST}:3900"

    canonical_uri = f"/{bucket}"
    canonical_qs = query
    canonical_headers = (
        f"content-md5:{content_md5}\n"
        f"host:{host}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amz_date}\n"
    )
    signed_headers = "content-md5;host;x-amz-content-sha256;x-amz-date"
    canonical_request = (
        f"PUT\n{canonical_uri}\n{canonical_qs}\n"
        f"{canonical_headers}\n{signed_headers}\n{payload_hash}"
    )

    scope = f"{date_stamp}/{REGION}/s3/aws4_request"
    string_to_sign = (
        f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n"
        f"{hashlib.sha256(canonical_request.encode()).hexdigest()}"
    )

    def _sign(k, msg):
        return hmac.new(k, msg.encode(), hashlib.sha256).digest()

    signing_key = _sign(
        _sign(
            _sign(
                _sign(f"AWS4{secret_key}".encode(), date_stamp),
                REGION,
            ),
            "s3",
        ),
        "aws4_request",
    )
    signature = hmac.new(
        signing_key, string_to_sign.encode(), hashlib.sha256
    ).hexdigest()

    auth = (
        f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    req = urllib.request.Request(
        f"{S3}/{bucket}?{query}",
        data=payload,
        headers={
            "Authorization": auth,
            "x-amz-date": amz_date,
            "x-amz-content-sha256": payload_hash,
            "Content-MD5": content_md5,
            "Content-Type": "application/xml",
        },
        method="PUT",
    )
    with urllib.request.urlopen(req) as resp:
        resp.read()


# ── Wait for Garage ──────────────────────────────────────────────────

print("Waiting for Garage admin API...")
for i in range(30):
    try:
        api("GET", "/v2/GetClusterHealth")
        print("Garage is ready.")
        break
    except (urllib.error.URLError, ConnectionError):
        print(f"  attempt {i + 1}/30...")
        time.sleep(2)
else:
    print("ERROR: Garage not ready after 60s")
    sys.exit(1)

# ── Layout ───────────────────────────────────────────────────────────

status = api("GET", "/v2/GetClusterStatus")
nodes = status["nodes"]
if not nodes:
    print("ERROR: No nodes found")
    sys.exit(1)
node_id = nodes[0]["id"]
print(f"Node ID: {node_id}")

print("=== Configuring layout ===")
# Body: {"roles": [{"id": "...", "zone": "...", "capacity": ..., "tags": []}]}
# Field is "id" (not "nodeId") — the OpenAPI spec is misleading
api("POST", "/v2/UpdateClusterLayout", {
    "roles": [
        {"id": node_id, "zone": "dc1", "capacity": 1073741824, "tags": []}
    ]
})
api("POST", "/v2/ApplyClusterLayout", {"version": 1})
print("Layout applied.")

# ── Buckets ──────────────────────────────────────────────────────────

print("=== Creating buckets ===")
for bucket in BUCKETS:
    api("POST", "/v2/CreateBucket", {"globalAlias": bucket})
    print(f"  bucket: {bucket}")

# ── API Key ──────────────────────────────────────────────────────────

print("=== Creating API key ===")
key = api("POST", "/v2/CreateKey", {"name": "ente-key"})
key_id = key["accessKeyId"]
key_secret = key["secretAccessKey"]
print(f"  Key ID: {key_id}")

print("=== Granting bucket permissions ===")
for bucket in BUCKETS:
    info = api("GET", f"/v2/GetBucketInfo?globalAlias={bucket}")
    bucket_id = info["id"]
    api("POST", "/v2/AllowBucketKey", {
        "bucketId": bucket_id,
        "accessKeyId": key_id,
        "permissions": {"read": True, "write": True, "owner": True},
    })
    print(f"  granted: {bucket}")

# ── CORS (required for web UI uploads) ───────────────────────────────

print("=== Setting CORS on buckets ===")
cors_xml = (
    '<?xml version="1.0" encoding="UTF-8"?>'
    "<CORSConfiguration><CORSRule>"
    "<AllowedOrigin>*</AllowedOrigin>"
    "<AllowedMethod>GET</AllowedMethod>"
    "<AllowedMethod>HEAD</AllowedMethod>"
    "<AllowedMethod>POST</AllowedMethod>"
    "<AllowedMethod>PUT</AllowedMethod>"
    "<AllowedMethod>DELETE</AllowedMethod>"
    "<AllowedHeader>*</AllowedHeader>"
    "<MaxAgeSeconds>3000</MaxAgeSeconds>"
    "<ExposeHeader>ETag</ExposeHeader>"
    "</CORSRule></CORSConfiguration>"
).encode()

for bucket in BUCKETS:
    try:
        s3_put(bucket, "cors=", cors_xml, key_id, key_secret)
        print(f"  CORS set: {bucket}")
    except urllib.error.HTTPError as e:
        print(f"  CORS failed for {bucket}: {e.code} {e.read().decode()}")

# ── Output credentials for setup.sh ──────────────────────────────────

print("=== GARAGE CREDENTIALS ===")
print(f"GARAGE_KEY_ID={key_id}")
print(f"GARAGE_KEY_SECRET={key_secret}")
print("=== DONE ===")
