# Media Server (Jellyfin + qBittorrent + Radarr + Sonarr)

Provisioned by Terraform from `terraform/vm-media.tf`.

Start at **`https://home.internal.prakash.com.br`** — the Homepage dashboard
links to (and reports the status of) everything below.

## What runs

All vhosts are served over **HTTPS** by the local `nginx`; plain HTTP redirects
to HTTPS. TLS uses a single Let's Encrypt SAN cert (lineage `media-stack`)
issued via Cloudflare DNS-01 — no public HTTP exposure needed. Renewal is
handled by `certbot.timer`, which reloads `media-nginx` via a deploy hook.

- `jellyfin` behind `nginx` on `https://jellyfin.internal.prakash.com.br`
- `qbittorrent` behind `nginx` on `https://torrent.internal.prakash.com.br`
- `radarr` behind `nginx` on `https://radarr.internal.prakash.com.br`
- `sonarr` behind `nginx` on `https://sonarr.internal.prakash.com.br`
- `prowlarr` behind `nginx` on `https://prowlarr.internal.prakash.com.br`
- `bazarr` behind `nginx` on `https://bazarr.internal.prakash.com.br`
- `homepage` behind `nginx` on `https://home.internal.prakash.com.br`

DNS-01 needs `CF_API_TOKEN` (Zone.DNS Edit + Zone.Read) and `LETSENCRYPT_EMAIL`
passed to `setup.sh`. The A records pointing these domains at this VM live in
`terraform/cloudflare-dns.tf`.

## Storage layout

- `${media_library_path}/movies` (movies library)
- `${media_library_path}/tv` (tv/other media library)
- `${media_download_path}/incomplete` (in-progress torrent files)
- `${media_download_path}/complete` (finished torrents)

These paths come from Terraform variables:

- `media_library_path` (default `/srv/media`)
- `media_download_path` (default `/srv/downloads`)

## Post-deploy steps

1. Visit Jellyfin at `http://jellyfin.internal.prakash.com.br` and complete first-run setup.
2. Configure a movie library pointing at `/media/movies`.
3. Visit qBittorrent at `http://torrent.internal.prakash.com.br` and set remote indexers.
4. Visit Prowlarr at `http://prowlarr.internal.prakash.com.br` and add your indexers.
5. In Prowlarr, connect it to Radarr, Sonarr, and qBittorrent.
6. Visit Bazarr at `http://bazarr.internal.prakash.com.br` and connect it to Radarr and Sonarr.
7. Visit Radarr at `http://radarr.internal.prakash.com.br`, add `qBittorrent` as download client and point the movie folder to `/media/movies`.
8. Visit Sonarr at `http://sonarr.internal.prakash.com.br`, add `qBittorrent` as download client and point the TV folder to `/media/tv`.
9. Re-run `setup.sh` once the apps above have completed first-run setup — it discovers their API keys and switches the Homepage tiles from links to live widgets.

## Homepage dashboard

`homepage` (`ghcr.io/gethomepage/homepage`) is the landing page for the stack.
It's config-file driven — `install.sh` writes `settings.yaml`, `services.yaml`,
`widgets.yaml` and `bookmarks.yaml` into `/opt/media-stack/homepage/` on every
run. **The installer is the source of truth: edit it, not the files on the VM**,
or your changes get overwritten on the next run.

Widgets talk to the other containers directly over the compose network
(`http://sonarr:8989`, …) rather than through the public vhosts, so they keep
working even when DNS or the cert is unhappy.

### Widget credentials are discovered, not configured

The apps mint their own credentials, so `install.sh` starts the stack first and
then interrogates it rather than asking you to copy keys by hand:

| Service | How its credential is obtained |
|---|---|
| Radarr / Sonarr / Prowlarr | read from `/config/config.xml` (`<ApiKey>`) |
| Bazarr | read from `/config/config/config.yaml` (`apikey:`), `config.ini` on older versions |
| Jellyfin | minted over the API — the same key Dashboard → API Keys creates, named `homepage` and reused on later runs |
| qBittorrent | **you must supply it** |

So the normal case is just `./bootstrap/media/setup.sh` with no extra vars.

Jellyfin needs an admin login to mint against, and qBittorrent's widget
authenticates with the WebUI login (the password is a PBKDF2 hash on disk, so
there's nothing to read back):

```bash
export JELLYFIN_USERNAME=... JELLYFIN_PASSWORD=...
export QBITTORRENT_USERNAME=... QBITTORRENT_PASSWORD=...
./bootstrap/media/setup.sh
```

Setting `RADARR_API_KEY` (or any other `*_API_KEY`) explicitly overrides
discovery for that service. The installer prints a ✓/– line per service and
skips the `widget:` block for anything it couldn't resolve — an empty key
renders as a permanent "API Error" tile, so those ship as plain links with an
up/down `siteMonitor` instead. Store whatever you do supply under `/media/` in
Infisical.

Because discovery has to happen after the containers are up, the run order is:
start stack → discover → write Homepage config → recreate the `homepage`
container → reload nginx. The nginx reload is required, not cosmetic: it
resolves `proxy_pass http://homepage:3000` once at config load, so without it
it would keep routing to the pre-recreate container IP.

Credentials land in `/opt/media-stack/.env` (0600) and reach the container as
`HOMEPAGE_VAR_*`; the YAML only ever contains `{{HOMEPAGE_VAR_…}}` placeholders,
so it stays safe to read and diff.

The Docker socket is deliberately **not** mounted into Homepage — the per-app
widgets already cover status, and a web-facing container with socket access is a
root-equivalent escalation path. The `resources` widget gets free-space numbers
from read-only `/media` and `/downloads` bind mounts instead.

## Stack updates

```bash
cd /opt/media-stack
sudo /opt/media-stack/restart-stack.sh
```
