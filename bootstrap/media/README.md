# Media Server (Jellyfin + qBittorrent + Radarr + Sonarr)

Provisioned by Terraform from `terraform/vm-media.tf`.

## What runs

- `jellyfin` behind `nginx` on `http://jellyfin.internal.prakash.com.br`
- `qbittorrent` behind `nginx` on `http://torrent.internal.prakash.com.br`
- `radarr` behind `nginx` on `http://radarr.internal.prakash.com.br`
- `sonarr` behind `nginx` on `http://sonarr.internal.prakash.com.br`
- `prowlarr` behind `nginx` on `http://prowlarr.internal.prakash.com.br`
- `bazarr` behind `nginx` on `http://bazarr.internal.prakash.com.br`

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

For stack updates:

```bash
cd /opt/media-stack
sudo /opt/media-stack/restart-stack.sh
```
