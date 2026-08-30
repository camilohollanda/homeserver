#!/usr/bin/env bash
# Emits LVM thin pool usage for the node_exporter textfile collector.
#
# node_exporter has no LVM collector, and a thin pool has no mounted
# filesystem, so the filesystem collector cannot see it either. On this
# hypervisor the thin pool pve/data backs the disks of VMs 112, 117 and 118 --
# when it fills, writes fail while the guests still believe they have space,
# and the result is corruption rather than a clean ENOSPC.
set -euo pipefail

OUT_DIR="${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}"
OUT="${OUT_DIR}/lvm_thinpool.prom"

# lv_attr starting with 't' selects thin pools. One CSV row per pool:
# vg,lv,data_percent,metadata_percent
mapfile -t ROWS < <(lvs --noheadings --nosuffix --separator=, \
  -o vg_name,lv_name,data_percent,metadata_percent \
  --select 'lv_attr=~"^t"' 2>/dev/null | tr -d '[:blank:]')

TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# Samples of one metric family must be contiguous, so the two families are
# emitted in separate passes rather than interleaved per pool.
{
  echo '# HELP node_lvm_thinpool_data_percent Percentage of thin pool data space in use.'
  echo '# TYPE node_lvm_thinpool_data_percent gauge'
  for row in "${ROWS[@]}"; do
    IFS=, read -r vg lv data meta <<<"$row"
    [[ -n "${vg:-}" && -n "${data:-}" ]] || continue
    printf 'node_lvm_thinpool_data_percent{vg="%s",lv="%s"} %s\n' "$vg" "$lv" "$data"
  done

  echo '# HELP node_lvm_thinpool_meta_percent Percentage of thin pool metadata space in use.'
  echo '# TYPE node_lvm_thinpool_meta_percent gauge'
  for row in "${ROWS[@]}"; do
    IFS=, read -r vg lv data meta <<<"$row"
    [[ -n "${vg:-}" && -n "${meta:-}" ]] || continue
    printf 'node_lvm_thinpool_meta_percent{vg="%s",lv="%s"} %s\n' "$vg" "$lv" "$meta"
  done
} > "$TMP"

chmod 644 "$TMP"
mv "$TMP" "$OUT"   # atomic: node_exporter must never read a half-written file
trap - EXIT
