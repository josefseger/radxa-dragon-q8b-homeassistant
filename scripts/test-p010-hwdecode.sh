#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/video-file"
    exit 2
fi

VIDEO_FILE=$1
PATCHED_LIB=${PATCHED_LIB:-$HOME/src/ffmpeg-7.1.5-p010/build-shared/libavcodec/libavcodec.so.61}

if [ ! -f "$PATCHED_LIB" ]; then
    echo "Patched libavcodec not found: $PATCHED_LIB"
    exit 1
fi

LD_PRELOAD="$PATCHED_LIB" \
mpv \
  --no-config \
  --vo=gpu \
  --gpu-api=opengl \
  --hwdec=v4l2m2m-copy \
  "$VIDEO_FILE"
