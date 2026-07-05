#!/usr/bin/env bash
set -euo pipefail

# iPod Video 5 converter
# Usage: ./convert_to_ipod.sh <folder>

TARGET_DIR="${1:-}"

if [[ -z "$TARGET_DIR" ]]; then
    echo "Usage: $0 <folder>"
    exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Error: '$TARGET_DIR' is not a directory"
    exit 1
fi

OUTPUT_DIR="$TARGET_DIR/ipod"
mkdir -p "$OUTPUT_DIR"

VIDEO_EXTENSIONS="mp4|mkv|avi|mov|wmv|flv|webm|m4v|mpg|mpeg|ts|3gp|ogv|rm|rmvb"

find "$TARGET_DIR" -maxdepth 1 -type f | grep -iE "\.($VIDEO_EXTENSIONS)$" | grep -v '/\._' | sort | while read -r INPUT_FILE; do
    BASENAME=$(basename "$INPUT_FILE")
    NAME="${BASENAME%.*}"
    OUTPUT_FILE="$OUTPUT_DIR/${NAME}.m4v"

    if [[ -f "$OUTPUT_FILE" ]]; then
        echo "Skipping (already exists): $BASENAME"
        continue
    fi

    echo "Converting: $BASENAME -> ${NAME}.m4v"

    ffmpeg -i "$INPUT_FILE" \
        -c:v libx264 \
        -profile:v baseline \
        -level 3.0 \
        -pix_fmt yuv420p \
        -vf "scale=640:480:force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2" \
        -b:v 1200k \
        -maxrate 1500k \
        -bufsize 3000k \
        -r 30 \
        -c:a aac \
        -b:a 128k \
        -ar 44100 \
        -ac 2 \
        -movflags +faststart \
        -y \
        "$OUTPUT_FILE" \
        && echo "Done: ${NAME}.m4v" \
        || echo "Failed: $BASENAME"
done

echo ""
echo "All done. Output in: $OUTPUT_DIR"
