#!/bin/bash

# Yank: capture the current clipboard as a JSON entry on stdout.
# In watch mode wl-paste invokes this with the payload on stdin and the mime
# as $1. Without arguments it snapshots the current selection itself.

set -o pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/yank"
IMAGE_DIR="$STATE_DIR/images"
mkdir -p "$IMAGE_DIR"

# Hard per-entry limits, enforced while reading so an oversized selection is
# never fully written or buffered. Anything over the limit is dropped, not
# truncated. Keep in step with maxImageBytes/maxTextLength in YankHistory.js.
MAX_IMAGE_BYTES=$((20 * 1024 * 1024))
MAX_TEXT_BYTES=$((1024 * 1024))

# gc mode: read the image paths the history still references on stdin, one per
# line, and delete every other file in images/. Files younger than a minute are
# left alone: they may belong to a capture the shell has not recorded yet.
if [[ ${1:-} == gc ]]; then
  keep=$(cat)
  find "$IMAGE_DIR" -maxdepth 1 -type f -mmin +1 -print0 |
    while IFS= read -r -d '' f; do
      grep -qxF -- "$f" <<<"$keep" || rm -f -- "$f"
    done
  exit 0
fi

types=$(wl-paste --list-types 2>/dev/null || true)

# Never record password-manager or other marked-sensitive selections.
if [[ ${CLIPBOARD_STATE:-} == "sensitive" ]] || grep -qx 'x-kde-passwordManagerHint' <<<"$types"; then
  exit 0
fi

emit_image() {
  local mime="$1"
  local ext tmp hash file bytes

  ext=${mime#image/}
  [[ $ext == jpeg ]] && ext=jpg

  tmp=$(mktemp --tmpdir="$IMAGE_DIR" yank.XXXXXX) || return 0
  # Read at most one byte past the limit: that byte is what tells us it is over.
  head -c $((MAX_IMAGE_BYTES + 1)) >"$tmp"
  bytes=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
  if (( bytes == 0 || bytes > MAX_IMAGE_BYTES )); then
    rm -f "$tmp"
    return 0
  fi

  hash=$(sha256sum "$tmp" | awk '{print $1}')
  file="$IMAGE_DIR/$hash.$ext"
  if [[ -e $file ]]; then
    rm -f "$tmp"
    # Fresh mtime: gc must not reap it before the shell records the entry again.
    touch "$file"
  else
    mv "$tmp" "$file"
  fi

  jq -cn --arg mime "$mime" --arg path "$file" --argjson bytes "$bytes" --arg at "$(date -Is)" \
    '{type:"image", mime:$mime, path:$path, bytes:$bytes, createdAt:$at}'
}

emit_text() {
  local raw tmp bytes
  # Bounded read into a scratch file first: the size is checked on the raw
  # bytes, before bash strips NULs, and nothing over the limit is buffered.
  tmp=$(mktemp) || return 0
  head -c $((MAX_TEXT_BYTES + 1)) >"$tmp"
  bytes=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
  if (( bytes > MAX_TEXT_BYTES )); then
    rm -f "$tmp"
    return 0
  fi
  raw=$(<"$tmp")
  rm -f "$tmp"

  # Reject binary payloads offered as text (e.g. `cat file.png | wl-copy`):
  # bash already strips NULs while capturing; here we reject invalid UTF-8
  # and heavy control-character density (NUL-only input becomes empty).
  if [[ -z $raw ]]; then
    return 0
  fi
  if ! printf '%s' "$raw" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    return 0
  fi
  # True ASCII control characters only (tab/newline/CR excluded; high bytes
  # are UTF-8 continuations, not garbage — invalid UTF-8 already died at iconv).
  local ctrl total
  ctrl=$(printf '%s' "$raw" | LC_ALL=C tr -cd '\0-\10\13\14\16-\37\177' | wc -c)
  total=$(printf '%s' "$raw" | LC_ALL=C wc -c)
  if (( total > 0 && ctrl * 20 > total )); then
    return 0
  fi

  # Single-line JSON: the shell's SplitParser feeds stdout to QML line by line.
  printf '%s' "$raw" | jq -cRs --arg at "$(date -Is)" '{type:"text", text:., createdAt:$at}'
}

case "${1:-}" in
text) emit_text; exit 0 ;;
image/*) emit_image "$1"; exit 0 ;;
esac

for mime in image/png image/jpeg image/webp image/gif image/bmp; do
  if grep -qx "$mime" <<<"$types"; then
    timeout 2s wl-paste --type "$mime" 2>/dev/null | emit_image "$mime"
    exit 0
  fi
done

if grep -q '^text/' <<<"$types" || grep -qx 'UTF8_STRING' <<<"$types" || grep -qx 'STRING' <<<"$types"; then
  wl-paste --type text --no-newline 2>/dev/null | emit_text
fi
