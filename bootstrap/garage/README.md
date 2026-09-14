# Garage S3 endpoints

Public HTTPS terminates at Cloudflare. Exact tunnel routes in
`terraform/cloudflare-tunnel.tf` precede the application wildcards and forward
to the shared nginx on `192.168.20.22:80`. Its public vhost in `garage.conf`
proxies exclusively to `127.0.0.1:3900`, preserving Host, object keys and query
strings for SigV4. Existing wildcard DNS records already cover these hosts.

| Public endpoint | Bucket | Browser origins |
| --- | --- | --- |
| `storage.werify.app` | `werify` (when provisioned) | `https://werify.app`, `https://www.werify.app` |
| `storage-staging.werify.app` | `werify-staging` (when provisioned) | `https://staging.werify.app` |
| `storage.iddh.com.br` | `iddh-members-prod` | `https://iddh.com.br`, `https://www.iddh.com.br`, `https://membros.iddh.com.br`, `https://blog.iddh.com.br` |
| `storage-staging.iddh.com.br` | `iddh-members-staging` | `https://iddh-members-staging.prakash.com.br` |
| `storage-staging.miora.now` | `miora-staging` | `https://staging.miora.now` |

Use `https://<endpoint>/<bucket>/<object>` and path-style addressing
(`forcePathStyle: true`). Hosts are aliases of the same S3 API; bucket/key
permissions enforce isolation. Public routing does not enable anonymous object
access. Applications must sign browser URLs using their public endpoint.
Changing an application's endpoint/credentials is a separate app rollout.

`garage.internal.prakash.com.br` remains available on the LAN. The UI stays at
`garage-ui.internal.prakash.com.br`, with its listener on `127.0.0.1:8090`.
The admin API remains on `127.0.0.1:3903`; neither has a public tunnel route.
Storage hosts have no Cloudflare Access login gate: S3 authentication handles
authorization, including presigned requests and browser preflights.

## Public nginx limits

- `limit_req`: 20 requests/s per client IP, burst 40, immediate rejection with 429.
- `limit_conn`: 20 concurrent requests per IP, rejection with 429.
- Both zones span all storage hosts. Only `192.168.20.11` (cloudflared) is trusted
  to supply `CF-Connecting-IP`; direct access to this vhost is rejected.
- Body: 60 MiB per request or multipart part (`GARAGE_PUBLIC_MAX_BODY_SIZE=60m`).
  Larger objects require S3 multipart uploads with parts below this cap. This is
  not HTTP chunked transfer encoding, which still counts as one request.
- Timeouts: headers 15s, client body inactivity 60s, upstream connect 5s,
  upstream read/write and client write inactivity 120s, keepalive 30s.
- Upload/download buffering is disabled. Responses use `Cache-Control:
  private, no-store`, so Cloudflare/browser caches cannot outlive signatures.
  Do not override this with a Cloudflare cache rule. Access logs omit query
  strings containing presigned credentials.

Cloudflare also caps request bodies independently of nginx (100 MB on Free/Pro;
the zone setting can be lower). Increasing nginx's limit cannot bypass it:
[Cloudflare upload limits](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/4xx-client-error/error-413/).

## CORS and deployment

The bucket's native CORS policy owns `Access-Control-Allow-Origin`; nginx
forwards OPTIONS to Garage. Use one rule per exact origin: Garage 2.3 joins
multiple origins in a rule into an invalid comma-separated ACAO value.
`ETag` is exposed for browser multipart uploads. CORS is not an authorization
mechanism, and requests without Origin still require valid S3 signatures.

Update an existing bucket without changing its keys, grants or objects:

```bash
REMOTE_HOST=deployer@192.168.20.22 \
  CORS_BUCKET=miora-staging CORS_ORIGINS=https://staging.miora.now \
  bash bootstrap/garage/configure-cors.sh
```

Use `CORS_DRY_RUN=1` to preview. The script saves prior policies under
`/opt/garage/cors-backups/`, applies only `corsRules` through the local admin API
and verifies the saved policy. To roll back, submit that JSON body to
`POST /v2/UpdateBucket?id=<bucket-id>` on the local admin API. For new buckets,
`configure-app.sh` provisions the bucket, key, grants and CORS together.

Install/update Garage with `setup.sh`, supplying the existing RPC/admin secrets
from Infisical on an existing installation. It writes the nginx config and
runs `nginx -t` before reload. Keep `GARAGE_PUBLIC_DOMAINS` aligned with the
Terraform host list. Configure the existing buckets' CORS before applying the
tunnel route change. Review a Terraform plan and apply only the intended route
change; no new VM, K3s workload or origin certificate is needed.

Verify each allowed origin with an unsigned OPTIONS request against
`https://<endpoint>/<bucket>/cors-probe`, with `Origin`,
`Access-Control-Request-Method: PUT` and
`Access-Control-Request-Headers: content-type`. Expect 200 and one ACAO value
matching Origin. An unlisted origin must fail preflight. Also verify a signed
PUT/GET round trip, 413 for oversized requests and 429 for rate/concurrency
limits; an unsigned object request must not return object data.

Validated on 2026-09-13: all five hosts reached S3 through Cloudflare; the
existing IDDH production/staging and Miora staging buckets passed allowed and
denied-origin preflights. A presigned PUT/GET/DELETE round trip on Miora passed,
including spaces, percent signs and repeated slashes in the object key. The
temporary object was removed. An isolated nginx using the installer-generated
configuration verified 413, rate/concurrency 429, per-IP separation and Host/URI
preservation. The Werify buckets are not provisioned yet.

Cloudflare's existing Browser Integrity Check rejected Python's default
`Python-urllib` User-Agent with error 1010 before the request reached nginx.
curl, a descriptive `garage-s3-verification/1.0` User-Agent and the Boto3
User-Agent reached S3. Diagnostic Python scripts should identify their client;
the zone's browser protection was not changed for this rollout. See
[Cloudflare error 1010](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/).
