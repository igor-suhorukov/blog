#!/usr/bin/env bash
# Renders the Mermaid sources in _diagrams/<post>/*.mmd to PNG files in
# assets/posts/<post>/ with the Mermaid CLI Docker image, and the Graphviz
# sources (*.dot) with the local dot. Feed readers and Planet PostgreSQL do not
# run JavaScript, so posts embed the PNGs.
#
# Usage: scripts/render-diagrams.sh [post-slug ...]   (default: every post)
set -euo pipefail
shopt -s nullglob

cd "$(dirname "$0")/.."
image=minlag/mermaid-cli:12.0.0

posts=("$@")
if [ ${#posts[@]} -eq 0 ]; then
  for dir in _diagrams/*/; do
    posts+=("$(basename "$dir")")
  done
fi

for post in "${posts[@]}"; do
  mkdir -p "assets/posts/$post"
  for src in "_diagrams/$post"/*.mmd; do
    out="assets/posts/$post/$(basename "$src" .mmd).png"
    echo "$src -> $out"
    docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/data" "$image" --quiet \
      --input "/data/$src" --output "/data/$out" \
      --configFile /data/_diagrams/mermaid-config.json \
      --backgroundColor white --scale 2
  done
  for src in "_diagrams/$post"/*.dot; do
    out="assets/posts/$post/$(basename "$src" .dot).png"
    echo "$src -> $out"
    dot -Tpng -Gdpi=110 -o "$out" "$src"
  done
done
