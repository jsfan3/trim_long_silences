#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./trim_long_silences.sh input.mp4 output.mp4 [max_silence] [noise_threshold]

Examples:
  ./trim_long_silences.sh input.mp4 output.mp4
  ./trim_long_silences.sh input.mp4 output.mp4 2 -35dB

Arguments:
  max_silence      Maximum silence to keep for each long silent section (default: 2)
  noise_threshold  ffmpeg silencedetect threshold (default: -35dB)

Environment overrides:
  VIDEO_PRESET     x264 preset for temp segments (default: veryfast)
  VIDEO_CRF        x264 CRF for temp segments (default: 18)
  AUDIO_BITRATE    AAC bitrate for temp segments (default: 96k)

Behavior:
  - detects silent sections at least max_silence seconds long
  - for each long silence, keeps only the first max_silence seconds
  - cuts audio and video at the same points
  - exports temp segments and concatenates them
USAGE
}

die() {
  echo "Error: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

float_is_positive() {
  awk -v v="$1" 'BEGIN { exit !(v ~ /^[0-9]*\.?[0-9]+$/ && v > 0) }'
}

fmt6() {
  awk -v v="$1" 'BEGIN { printf "%.6f", v }'
}

[[ $# -ge 2 && $# -le 4 ]] || { usage; exit 1; }

INPUT=$1
OUTPUT=$2
MAX_SILENCE=${3:-2}
NOISE_THRESHOLD=${4:--35dB}

VIDEO_PRESET=${VIDEO_PRESET:-veryfast}
VIDEO_CRF=${VIDEO_CRF:-18}
AUDIO_BITRATE=${AUDIO_BITRATE:-96k}

need_cmd ffmpeg
need_cmd ffprobe
need_cmd awk

[[ -f "$INPUT" ]] || die "input file not found: $INPUT"
float_is_positive "$MAX_SILENCE" || die "max_silence must be a positive number"

HAS_VIDEO=$(ffprobe -v error -select_streams v:0 -show_entries stream=index -of csv=p=0 "$INPUT" || true)
HAS_AUDIO=$(ffprobe -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$INPUT" || true)

[[ -n "$HAS_VIDEO" ]] || die "input has no video stream"
[[ -n "$HAS_AUDIO" ]] || die "input has no audio stream"

DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT")
[[ -n "$DURATION" ]] || die "could not read input duration"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

META_FILE="$WORK_DIR/silence_meta.txt"
SILENCE_FILE="$WORK_DIR/silences.txt"
KEEP_FILE="$WORK_DIR/keep_segments.txt"
CONCAT_LIST="$WORK_DIR/concat_list.txt"
SEG_DIR="$WORK_DIR/segments"

mkdir -p "$SEG_DIR"

echo "1/4 Detecting silence..."
ffmpeg -hide_banner -nostdin -nostats -loglevel error \
  -i "$INPUT" \
  -map 0:a:0 \
  -af "silencedetect=noise=${NOISE_THRESHOLD}:d=${MAX_SILENCE},ametadata=mode=print:file=${META_FILE}" \
  -f null - >/dev/null 2>&1 || true

echo "2/4 Parsing silence ranges..."
awk -v total="$DURATION" '
  /^lavfi\.silence_start=/ {
    split($0, a, "=")
    current_start = a[2] + 0
    next
  }
  /^lavfi\.silence_end=/ {
    split($0, a, "=")
    current_end = a[2] + 0
    if (current_start != "") {
      printf "%.6f %.6f\n", current_start, current_end
      current_start = ""
    }
    next
  }
  END {
    if (current_start != "") {
      printf "%.6f %.6f\n", current_start, total + 0
    }
  }
' "$META_FILE" > "$SILENCE_FILE"

if [[ ! -s "$SILENCE_FILE" ]]; then
  echo "No silence >= ${MAX_SILENCE}s detected. Copying file unchanged."
  ffmpeg -hide_banner -nostdin -y -i "$INPUT" -c copy "$OUTPUT"
  echo "Done: $OUTPUT"
  exit 0
fi

echo "3/4 Building keep segments..."
awk -v total="$DURATION" -v max_keep="$MAX_SILENCE" '
  function emit(a, b) {
    if ((b - a) > 0.0001) {
      printf "%.6f %.6f\n", a + 0, b + 0
    }
  }
  BEGIN {
    prev = 0
  }
  {
    s = $1 + 0
    e = $2 + 0
    d = e - s

    if (s < prev) s = prev
    if (e < s) next

    emit(prev, s)

    if (d > max_keep) emit(s, s + max_keep)
    else emit(s, e)

    prev = e
  }
  END {
    emit(prev, total)
  }
' "$SILENCE_FILE" > "$KEEP_FILE"

SEGMENT_COUNT=$(wc -l < "$KEEP_FILE" | tr -d '[:space:]')
[[ "$SEGMENT_COUNT" -gt 0 ]] || die "no valid keep segments were produced"

echo "   Segments to export: $SEGMENT_COUNT"

echo "4/4 Exporting temp segments and concatenating..."
: > "$CONCAT_LIST"

i=0
while IFS=' ' read -r START END EXTRA; do
  [[ -n "${START:-}" && -n "${END:-}" ]] || die "invalid keep segment line: '${START:-} ${END:-} ${EXTRA:-}'"
  [[ -z "${EXTRA:-}" ]] || die "invalid keep segment line: '${START} ${END} ${EXTRA}'"

  SEGMENT_DURATION=$(awk -v s="$START" -v e="$END" 'BEGIN { printf "%.6f", e - s }')
  awk -v d="$SEGMENT_DURATION" 'BEGIN { exit !(d > 0.0001) }' \
    || die "non-positive segment duration: start=$START end=$END"

  i=$((i + 1))
  SEG_FILE="$SEG_DIR/segment_$(printf '%05d' "$i").ts"

  echo "   [$i/$SEGMENT_COUNT] $(fmt6 "$START") -> $(fmt6 "$END") (dur $(fmt6 "$SEGMENT_DURATION"))"

  ffmpeg -hide_banner -nostdin -loglevel error -y \
    -ss "$START" -i "$INPUT" -t "$SEGMENT_DURATION" \
    -map 0:v:0 -map 0:a:0 \
    -c:v libx264 -preset "$VIDEO_PRESET" -crf "$VIDEO_CRF" -pix_fmt yuv420p \
    -c:a aac -b:a "$AUDIO_BITRATE" \
    -f mpegts \
    "$SEG_FILE"

  printf "file '%s'\n" "$SEG_FILE" >> "$CONCAT_LIST"
done < "$KEEP_FILE"

ffmpeg -hide_banner -nostdin -y \
  -f concat -safe 0 -i "$CONCAT_LIST" \
  -c copy \
  -bsf:a aac_adtstoasc \
  -movflags +faststart \
  "$OUTPUT"

echo "Done: $OUTPUT"
