#!/usr/bin/env bash

set -e

SHADER_DIR="$(dirname "$0")"
OUT_DIR="${1:-$SHADER_DIR}"

SHADERS=(
    "ui_rect.frag"
    "ui_rect.vert"
)

echo "Compiling shaders..."

for shader in "${SHADERS[@]}"; do
    src="$SHADER_DIR/$shader"
    out="$OUT_DIR/$shader.spv"

    if [ ! -f "$src" ]; then
        echo "  [WARN] Not found: $src — skipping"
        continue
    fi

    glslc --target-env=vulkan1.3 "$src" -o "$out"
    echo "  [OK]   $shader  ->  $shader.spv"
done

echo "Done."
