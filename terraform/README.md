# Terraform Configuration for Proxmox VMs

This directory contains Terraform configuration to provision VMs on Proxmox:
- **k3s-apps** (192.168.20.11) - K3s single-node cluster
- **db-postgres** (192.168.20.21) - PostgreSQL database server
- **infisical** (192.168.20.22) - Infisical secret management server
- **ai-gpu** (192.168.20.30) - Whisper + Ollama services
- **media-server** (192.168.20.40) - Jellyfin + qBittorrent + Radarr + Sonarr stack

> **Correction — 2026-08-27.** The list above is the layout as it stood before
> the PostgreSQL 17 -> 18 upgrade. `db-postgres` (VM 113, 192.168.20.21) no
> longer exists: it was the blue side of the blue/green upgrade and was
> destroyed once every database had moved. The database host is now
> **db-postgres-18** (VM 118, 192.168.20.23), defined in `vm-postgres-18.tf`.
> The list is also incomplete — **gh-runners** (VM 117, 192.168.20.50) has been
> here since May 2026. See the VM inventory in the repo-root `AGENTS.md` for the
> current set.

## Prerequisites

- Terraform >= 1.6.0
- `mise` (for environment variable management)
- Access to Proxmox API

## Setup

1. Copy `.env.sample` to `.env`:
   ```bash
   cp .env.sample .env
   ```

2. Edit `.env` with your actual values:
   - Update `TF_VAR_pm_api_token_secret` with your Proxmox API token
   - Adjust network settings if needed
   - Update SSH public keys

3. `mise` will automatically load the `.env` file when you enter the directory.

4. Initialize Terraform:
   ```bash
   terraform init
   ```

5. Review the plan:
   ```bash
   terraform plan
   ```

6. Apply the configuration:
   ```bash
   terraform apply
   ```

7. Copy bootstrap scripts to VMs:
   ```bash
   ./copy-bootstrap.sh all
   ```

   Or copy to specific VMs:
   ```bash
./copy-bootstrap.sh k3s      # Only k3s-apps VM
./copy-bootstrap.sh postgres # Only db-postgres VM
./copy-bootstrap.sh media    # Only media-server VM
```

## Environment Variables

All configuration is done via environment variables with the `TF_VAR_` prefix. Terraform automatically reads these.

For list variables like `ssh_public_keys`, use JSON array format:
```bash
TF_VAR_ssh_public_keys='["key1","key2"]'
```

## Files

- `main.tf` - Main Terraform configuration
- `variables.tf` - Variable definitions
- `.env.sample` - Example environment variables (safe to commit)
- `.env` - Your actual environment variables (gitignored)
- `.gitignore` - Excludes sensitive files from git

### Media stack

The media server (Jellyfin + qBittorrent + Radarr + Sonarr) is deployed by Terraform through:

- `terraform/vm-media.tf` - VM definition
- `terraform/cloud-init/media.yaml` - container stack and service bootstrap
- `bootstrap/media` - manual helper scripts and docs

The media VM exposes these services via a local reverse proxy (no ports):
- `http://jellyfin.internal.prakash.com.br`
- `http://torrent.internal.prakash.com.br`
- `http://radarr.internal.prakash.com.br`
- `http://sonarr.internal.prakash.com.br`
- `http://prowlarr.internal.prakash.com.br`
- `http://bazarr.internal.prakash.com.br`

## Infisical Setup

The Infisical VM requires additional setup after Terraform provisions the VMs:

### 1. Generate Secrets

Before applying Terraform, generate the required secrets:

```bash
# Generate encryption key (32 hex chars)
openssl rand -hex 16

# Generate auth secret
openssl rand -base64 32

# Generate postgres password
openssl rand -base64 24
```

Update these values in `terraform.tfvars`.

### 2. Setup PostgreSQL Database

> **Correction — 2026-08-27.** This walkthrough describes VM 113
> (192.168.20.21), which no longer exists, and a script
> (`infisical-db-setup.sh`) that has since been replaced. PostgreSQL is now
> installed and configured by `bootstrap/postgres/install.sh`, and app databases
> are created with `bootstrap/postgres/pg-provision.sh` — neither of which needs
> the manual `postgresql.conf` / `pg_hba.conf` editing shown below. Kept for the
> record of how the host used to be brought up; see `bootstrap/postgres/README.md`
> for the current procedure.

After the VMs are created, SSH into the db-postgres VM and run:

```bash
# On db-postgres VM (192.168.20.21)
cd /opt/bootstrap
./infisical-db-setup.sh infisical infisical 'your-postgres-password'
```

Then configure PostgreSQL to accept remote connections:

```bash
# Edit postgresql.conf
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/*/main/postgresql.conf

# Add to pg_hba.conf
echo "host    infisical    infisical    192.168.20.22/32    scram-sha-256" | sudo tee -a /etc/postgresql/*/main/pg_hba.conf

# Restart PostgreSQL
sudo systemctl restart postgresql
```

### 3. Access Infisical

After the Infisical VM boots (takes ~3-5 minutes for Docker setup):

- URL: https://192.168.20.22:8443
- Create your admin account on first login
- The self-signed certificate will show a warning (expected)

### 4. Integrate with K8s

Install External Secrets Operator on your K3s cluster:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

## Cloudflare resources

DNS records and the cloudflared tunnel (including its ingress routes) are
managed here:

- `cloudflare-tunnel.tf` — the `homeserver` tunnel + its remotely-managed
  ingress block. The on-VM `/etc/cloudflared/config.yml` contains only
  `tunnel:` + `credentials-file:` — all ingress routes come from Cloudflare
  and live-reload on `terraform apply`.
- `cloudflare-dns.tf` — public CNAMEs at the tunnel, internal A-records for
  LAN-only services on `*.internal.prakash.com.br` (those records live inside
  the `prakash.com.br` zone, not a separate delegated zone), and the DNS-AID
  agent discovery SVCBs under `_agents.werify.app`.

### DNSSEC on werify.app — enabled, deliberately outside Terraform

`werify.app` is DNSSEC-signed as of 2026-08-03. Cloudflare signs the zone
(algorithm 13, ECDSAP256SHA256); the DS lives at the registrar, **Dynadot**,
which is not Cloudflare Registrar — so there is no one-click flow and the DS
was hand-entered:

```
werify.app. IN DS 2371 13 2 3BE9833617AD40E0612E6D96D1B4748AB65615D191DE615C23295D3D0157C92A
```

Key tag `2371` is the **KSK** (flags 257). `34505` is the ZSK and is *not*
what goes in the DS — an easy mis-copy, since the ZSK tag is the one that
shows up in ordinary RRSIGs.

**Why it is not a `cloudflare_zone_dnssec` resource here.** It could be, and
that resource only needs the DNS Read/Write the Terraform token already has.
But adding it un-imported means the next `apply` calls the API to "create"
something that already exists, and the blast radius if that ever churned the
key is the whole domain going dark for validating resolvers — `.app` is
HSTS-preloaded, so there is no HTTP fallback. That trade is bad for a one-time
zone toggle whose other half (the DS at Dynadot) Terraform cannot manage
anyway. To bring it in later, do it deliberately and import first:

```bash
# zone id = cloudflare_zone_ids.werify_app in terraform.tfvars
terraform import cloudflare_zone_dnssec.werify_app '<werify_app zone id>'
```

Verify DNSSEC at the **registry**, not at a resolver — cache will lie to you:

```bash
curl -sL -H 'Accept: application/rdap+json' https://rdap.org/domain/werify.app
#   secureDNS.delegationSigned must be true
dig +dnssec werify.app A @1.1.1.1 | grep flags   # must carry "ad"
```

Two gotchas, both paid for once already: the **Dynadot DNSSEC form fails
silently** (submissions vanish with no error and no registry change — if
`delegationSigned` stays `false`, use their API `command=set_dnssec`, which
returns an actual error), and going insecure→secure produces **intermittent
SERVFAIL for ~30 min** while resolvers holding the cached "this zone is
insecure" proof drain. Genuine breakage looks different: deterministic
SERVFAIL everywhere, `ad` never appearing.

### Importing the iddh.com.br apex — one record imported, three still to delete

`iddh.com.br` and `www.iddh.com.br` predate Terraform: both were created by
hand and still point at Hostinger, where the legacy WordPress site runs. They
are in `local.public_tunnel_records` ahead of the cutover (members repo,
`docs/host-topology.md`) and were brought into state with:

```bash
# zone id = cloudflare_zone_ids.iddh_com_br
terraform import 'cloudflare_dns_record.public_tunnel["iddh_www"]'  '97aee423b42fbbeaebd6d2ad331d06ca/98da5f2be4fc4b77af2847af9ef0f2a5'
terraform import 'cloudflare_dns_record.public_tunnel["iddh_apex"]' '97aee423b42fbbeaebd6d2ad331d06ca/da50dc780ecd209150db96aebfc194eb'
```

`www` is clean — one CNAME in, one CNAME out, so the plan is an in-place
`content` change.

**The apex is not.** It is served by *four* records, not one:

| id | type | content |
|---|---|---|
| `da50dc780ecd209150db96aebfc194eb` | A | `147.79.79.77` — **imported** |
| `2fa05c8a161dea56e41d2eea604002f1` | A | `147.79.72.227` |
| `0b3347e160ef7f8e6dc81caee70e5fdc` | AAAA | `2a02:4780:4d:e625:aca6:2684:3cba:3376` |
| `592f241e7d6955b71028a516d38bc048` | AAAA | `2a02:4780:4a:3425:b12:ca8a:c25c:37e2` |

`cloudflare_dns_record.public_tunnel["iddh_apex"]` is a single resource, so
only the first could be imported. The other three are invisible to Terraform,
and **`terraform apply` will fail while they exist**: the plan replaces the
imported A record with a CNAME, and Cloudflare refuses a CNAME that coexists
with other records at the same name. Delete them immediately before the apply:

```bash
ZONE=97aee423b42fbbeaebd6d2ad331d06ca
for REC in 2fa05c8a161dea56e41d2eea604002f1 \
           0b3347e160ef7f8e6dc81caee70e5fdc \
           592f241e7d6955b71028a516d38bc048; do
  curl -sS -X DELETE -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$REC"
done
```

This is the point of no return for the apex: between the deletion and the
apply, `iddh.com.br` resolves to a single Hostinger IP, and after the apply it
resolves to the tunnel. Do not run it before the app is ready to serve the apex
(the ingress rules and the tunnel routes are the safe half of this change — they
can land days earlier and change nothing on their own).

The expected plan, scoped so it does not refresh Proxmox:

```bash
terraform plan -target='cloudflare_dns_record.public_tunnel' \
               -target='cloudflare_zero_trust_tunnel_cloudflared_config.homeserver'
# iddh_apex     must be replaced  (type A -> CNAME forces replacement)
# iddh_www      updated in-place  (content -> <tunnel>.cfargotunnel.com)
# iddh_wildcard created
# tunnel config updated in-place  (3 new ingress hostnames)
```

MX, SPF and the Google verification TXT records at the apex are untouched —
mail stays on Hostinger, and a wildcard CNAME does not shadow them. Before the
wildcard lands, check the zone for any other subdomain that must keep resolving
to Hostinger (`webmail`, `autodiscover`, `cpanel`): explicit records win over a
wildcard, so the fix is to make sure they exist explicitly.

### Token model — two tokens, different scopes

Cloudflare access is split across two tokens. The split is intentional —
compromise of one shouldn't grant the powers of the other.

| Token | Env var | Scope | Where it lives | What it does |
|---|---|---|---|---|
| **A — narrow** | `CF_API_TOKEN` | `Zone.DNS:Edit` + `Zone:Read` on the 3 zones | `.env` on dev box AND `/etc/letsencrypt/cloudflare.ini` on every VM that uses certbot DNS-01 | certbot's `_acme-challenge.*` TXT writes; nothing else |
| **B — broad** | `TF_VAR_cloudflare_api_token` | A's scopes **plus** `Account.Cloudflare Tunnel:Edit` | `.env` on dev box only — **never copy to a VM** | Terraform provider |

Why this matters:
- If a VM is compromised, the attacker can edit DNS but cannot touch the
  tunnel ingress — they can't, e.g., redirect routes to themselves.
- If the dev box is compromised, the attacker gets the broader token, but
  that's a smaller and more controllable attack surface than 3+ VMs.
- To rotate Token B alone: create a new token in CF dashboard with the same
  permissions, swap value of `TF_VAR_cloudflare_api_token` in `.env`, delete
  the old token. No SSH to any VM. Same recipe for Token A in reverse — but
  rotating A also requires updating `/etc/letsencrypt/cloudflare.ini` on
  each VM (currently 3: services, ai, postgres) and restarting certbot.

### Operational quirks worth knowing

- **`config_src` is `ForceNew` in the CF Terraform provider** — but the CF
  API itself supports changing it in place. If you ever need to flip a
  tunnel between locally-managed and remotely-managed, do it via the API
  (`PATCH /accounts/X/cfd_tunnel/Y` with `{"config_src": "..."}`), then
  `terraform state rm` + `terraform import` the tunnel to refresh state.
  Letting Terraform handle the change would destroy + recreate the tunnel
  — new UUID, new credentials JSON, manual cloudflared rewrite on the VM.
- **Pre-populate the remote-managed config before flipping `config_src`**.
  When you set `config_src=cloudflare`, cloudflared starts pulling its
  ingress from CF's stored config — if that store is empty, every request
  returns 404 until you push a config. Order: PUT the config first, THEN
  patch `config_src`.
- **`internal.prakash.com.br` is not a zone** — those A records live inside
  the `prakash.com.br` zone with multi-segment names. The older bash
  scripts hardcoded a zone ID that happened to be `prakash.com.br`'s.
- **CF token permission changes take a few seconds to propagate** across
  CF's edges. If Terraform 403s on a tunnel read immediately after you
  add a scope to the token, retry once — it usually clears within a minute.

### Ongoing changes — the everyday workflow

- **Add a route to the tunnel** → edit `local.tunnel_ingress` in
  `cloudflare-tunnel.tf`. Cloudflared live-reloads on the next apply; no SSH.
- **Add an internal service** → add an entry to `local.internal_a_records` in
  `cloudflare-dns.tf`.
- **Add a public hostname** → add to `local.public_tunnel_records` AND to
  `local.tunnel_ingress` (CNAME alone is not enough; the tunnel needs to
  know what to route the host to).
- **`bootstrap/k3s/cloudflared-config.sh`** is still used for first-time
  cloudflared install on a fresh k3s VM — it now only writes the minimal
  config (tunnel ID + credentials path) and registers the systemd service.

## Notes

- The `.env` file is gitignored and contains sensitive information
- State files are also gitignored
- Use `terraform.tfvars` as an alternative if you prefer (also gitignored)
- `terraform.tfstate` and `terraform.tfvars` were previously tracked in git
  and have been scrubbed from history with `git filter-repo`. Anyone who
  cloned before the rewrite still has the historical blobs locally — if
  that's a concern, rotate the secrets (Proxmox token, CF token, Infisical
  encryption key, etc.) and have them re-clone.

## Change history

| Date | Change | Status |
|------|--------|--------|
| 2026-08-27 | `ai-gpu` (VM 115) `scsi0` moved from `local-lvm` to `tank-vm`; the 4 MB EFI disk stayed on `local-lvm`. Done on the host first, then reflected in `vm-ai.tf`. | Applied on the host; the datastore change matches (no diff) |
| 2026-08-27 | `ai-gpu` `scsi0` set to `ssd = false` in `vm-ai.tf`. `tank` is one 3.6TB 7200rpm drive (`ROTA=1`); the `ssd=1` flag survived the move off `local-lvm` and was never true on `tank-vm`. Every other tank-vm disk on the host (114 `scsi1`, 116 `scsi0`) is already `ssd=0`, and `vm-media.tf` documents the same reasoning. | Config changed, **not yet applied** — `terraform plan` shows an in-place `ssd = true -> false` on `ai_gpu`. The guest keeps seeing a non-rotational device until VM 115 is stopped and started |
| 2026-08-27 | VM 113 (`db-postgres`, PG 17, 192.168.20.21) destroyed. `vm-postgres.tf` and `cloud-init/postgres.yaml` removed; `local.db_vm` dropped; `output.db_vm_ip` and the `services` VM's `depends_on` repointed at VM 118. | VM already gone and dropped from state on refresh; the only pending action is deleting the orphaned `postgres-cloud-init.yaml` snippet on the host, on the next `terraform apply` |
| 2026-08-27 | `pg.internal.prakash.com.br` repointed from 192.168.20.21 to 192.168.20.23 in `cloudflare-dns.tf`. `pg18` is deliberately kept alongside it — all live `DATABASE_URL`s still name `pg18`. | Config changed, **not yet applied** — the record still resolves to the dead .21 until `terraform apply` runs |
| 2026-08-27 | Normalise every `DATABASE_URL` from `pg18.internal` onto `pg.internal`, then drop the `pg18` record (`bootstrap/postgres/CUTOVER.md`, steps 4 and 3). | Not started |
