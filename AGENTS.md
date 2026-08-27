# Repo orientation

K3s + Proxmox homelab. Three top-level layers:

- `terraform/` — Proxmox VM provisioning (cloud-init). Edits here = new/resized VMs.
- `bootstrap/` — per-VM installers run **after** the VM exists. One folder per VM/app, all idempotent.
- `gitops/` — Argo CD application manifests for everything running **inside K3s** (not on bare VMs).

A new piece of infra usually lives in exactly one of these, not multiple.

## VM inventory

| vmid | name            | IP             | role                                                            |
|------|-----------------|----------------|-----------------------------------------------------------------|
| 112  | k3s-apps        | 192.168.20.11  | K3s single-node cluster (apps, ingress-nginx, Argo CD, ESO).    |
| 114  | infisical *     | 192.168.20.22  | **Services VM** — see below.                                    |
| 115  | ai-gpu          | 192.168.20.30  | Whisper + Ollama. GPU passthrough. OS disk on `tank-vm` (HDD).   |
| 116  | media-server    | 192.168.20.40  | Jellyfin / *arr stack (local nginx proxy, no TLS).              |
| 117  | gh-runners      | 192.168.20.50  | Self-hosted GitHub Actions runners.                             |
| 118  | db-postgres-18  | 192.168.20.23  | PostgreSQL 18 — the only database host. `pg18.internal.prakash.com.br`. |

\* Terraform still calls VM 114 `infisical` for legacy reasons; in practice it's a multi-tenant **services VM** hosting Infisical, Garage, Mailpit, … behind a shared nginx.

**Decommissioned:** VM 113 (`db-postgres`, 192.168.20.21, PostgreSQL 17, mDNS
`pg.local`) was the blue side of the PG 17 → 18 upgrade and was destroyed on
2026-08-27, once all 11 connection strings had moved to 118. Nothing answers on
`.21` or `pg.local` any more — **there is no mDNS name for the database now**;
118 does not run Avahi. Reach it by DNS: `pg18.internal.prakash.com.br`, and
`pg.internal.prakash.com.br` once `terraform apply` lands the repoint. VM 119
(`forgejo`, 192.168.20.24) is likewise gone.

## Services VM (114) — the pattern to copy

The services VM hosts multiple unrelated docker apps behind **one shared nginx** that owns ports 80/443. Each new app plugs in as:

```
/opt/services/                      # shared nginx (bootstrap/services/install.sh)
  ├── docker-compose.yml            # network_mode: host, ports 80/443
  ├── nginx.conf                    # `include conf.d/*.conf;`
  └── conf.d/<app>.conf             # <-- each app drops a vhost here

/opt/<app>/                         # the app's own stack
  ├── docker-compose.yml            # binds to 127.0.0.1:<port>
  └── .env                          # 0600, app secrets

/etc/systemd/system/<app>.service   # oneshot wrapper around `docker compose up -d`
/etc/letsencrypt/live/<fqdn>/       # per-vhost cert, DNS-01 via Cloudflare
```

Hard rules when adding a new service here:

1. **Don't bind 80/443 in the app's compose** — the shared nginx owns them. Bind on `127.0.0.1:<some-port>` and have nginx proxy to it. Exception: services that legitimately need a non-HTTP listener reachable from the LAN (e.g. Mailpit's SMTP port) bind on `0.0.0.0:<non-conflicting-port>`.
2. **One vhost file per app** in `/opt/services/conf.d/<app>.conf`. After writing it, reload with `docker exec services nginx -s reload`.
3. **Use the shared cert tooling** — `bootstrap/services/install.sh` already provisions certbot + the Cloudflare DNS-01 plugin and writes a renewal hook that reloads the shared nginx. Just call `certbot certonly --dns-cloudflare …` from your app installer.
4. **Prereq guard at the top of every app installer**: bail if `/opt/services/docker-compose.yml` is missing — that means the services proxy hasn't been set up yet.

Live examples to crib from: `bootstrap/infisical/install.sh`, `bootstrap/garage/install.sh`, `bootstrap/mailpit/install.sh`. They're all the same shape.

## Bootstrap script convention

Every app folder under `bootstrap/<app>/` has **two scripts**:

- `install.sh` — runs **on the VM** as root. Top of file has a `REMOTE_HOST=` trick that re-execs itself over SSH while forwarding the env vars (`printf 'export %s=%q\n' …` piped into `ssh "$REMOTE_HOST" sudo bash -s`). This means you can run the same script locally for testing or remotely from your dev box — no separate "deploy" tooling needed.
- `setup.sh` — runs **on your local machine**. Does the pre-flight work that needs cloud APIs (Cloudflare DNS automation, secret generation with `openssl rand`, SSH readiness check via `wait_ssh`), then invokes `install.sh` with `REMOTE_HOST=…`.

DNS automation in `setup.sh` is shared boilerplate: `get_zone_id` (longest-suffix match across CF zones) + `ensure_a_record`. Copy these helpers when adding a new service.

All env vars defaulting to "auto-generated random" use `openssl rand -base64 32 | tr -d '=+/' | cut -c1-32`.

## Domains & TLS

Three distinct paths — don't conflate them:

- **Public apps** (`*.werify.app`, `prakash.com.br`, `membros.iddh.com.br`) → exposed via **Cloudflare Tunnel** from k3s-apps. **TLS terminates at the Cloudflare edge** — cloudflared forwards plain HTTP to `127.0.0.1:80` (ingress-nginx), and these Ingresses deliberately have **no `tls:` block**. cert-manager is not involved. Routes live in `terraform/cloudflare-tunnel.tf`; `*.werify.app` and `*.prakash.com.br` are already wildcards, anything else falls through to `http_status:404`.
- **Internal apps inside k3s** (`argocd`, `grafana`, `bugsink`) → `<app>.internal.prakash.com.br` → **A record to 192.168.20.11** (a `*.internal` wildcard A record catches the rest). LAN-only. Cert via **cert-manager** + the `letsencrypt-dns` ClusterIssuer (DNS-01 over Cloudflare), **one Certificate per host**, declared in each app's own `gitops/<app>/ingress.yaml`. Don't try to replace these with one shared wildcard Certificate: an Ingress can only reference a Secret in **its own namespace**, so a wildcard living in `cert-manager` would need kubernetes-reflector to be usable at all. One was tried in Jan 2026 and sat unused until removed.
- **Internal apps on the services VM** (`infisical`, `mailpit`, `garage`) → `<app>.internal.prakash.com.br` → **A record to 192.168.20.22**. LAN-only (or via Cloudflare Zero Trust internal DNS). Cert via **certbot** DNS-01, served by the shared nginx.

`setup.sh` scripts on the services VM create the A record automatically unless `SKIP_DNS=1`. The CF token needs `Zone.DNS Edit` + `Zone.Read`.

## Secrets

- Long-lived secrets live in **Infisical** (project `homeserver`). After running an app's `setup.sh`, the final echo block lists which keys to store and under which path (e.g. `/Garage/`, `/mailpit/`).
- K3s apps consume Infisical secrets via the **External Secrets Operator** — see `gitops/external-secrets/`.
- Never check generated secrets into git; the `setup.sh` scripts print them once and expect you to copy them into Infisical.

## Things to be careful about

- **VM 114 was originally just for Infisical.** Old comments/scripts may still say "Infisical VM" — treat it as the services VM and never put logic into one app's installer that other apps would need. Shared concerns (Docker install, certbot, the nginx proxy) belong in `bootstrap/services/install.sh`.
- **Don't reformat `/dev/sdb` on VM 114** — it's the Garage data disk (ext4, label `garage-data`). `bootstrap/garage/install.sh` refuses to overwrite a non-ext4 filesystem there; preserve that guard if you touch disk logic.
- **The renewal hook reloads only the shared nginx** (`docker exec services nginx -s reload`). If you add a service whose cert needs *its own* reload (rare), add another hook in `/etc/letsencrypt/renewal-hooks/deploy/`.
- **Port 25 is often blocked / privileged.** New SMTP-ish services on VM 114 should bind a non-25 port (Mailpit defaults to 2525) unless there's a concrete reason otherwise.

## Mailpit specifically

- Bootstrap: `bootstrap/mailpit/{install,setup}.sh`
- Domain: `mailpit.internal.prakash.com.br` (web UI, basic-auth, TLS via shared nginx)
- SMTP listener: `mailpit.internal.prakash.com.br:2525` **and** `:587` (both reach the same container; 587 exists for apps that hardcode the submission port). **STARTTLS + AUTH PLAIN/LOGIN required** (`MP_SMTP_REQUIRE_STARTTLS=true` + `MP_SMTP_AUTH`); SMTP credentials are the same as the web UI basic-auth user. Connect by hostname, not IP — the LE cert is bound to the FQDN.
- Persistence: `/opt/mailpit/data/mailpit.db` (sqlite — fine, retention is bounded by `MP_MAX_MESSAGES`).
- This is **for development email capture only.** Real outbound mail still goes through whatever production SMTP each app is configured with.
