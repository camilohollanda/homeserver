#!/usr/bin/env bash
set -euo pipefail

cd /opt/media-stack
/usr/bin/docker compose pull
/usr/bin/docker compose up -d
