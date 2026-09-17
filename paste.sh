#!/bin/bash
# Copy an entry to the clipboard, then paste it into whatever window has focus.
#
# Two routes, because synthesising a keystroke is only reliable for one of them:
#
#   * A terminal is pasted into directly, by writing the text to its tty wrapped
#     in bracketed-paste markers. No keystroke and no focus race, and it sidesteps
#     the fact that Ctrl+V is quoted-insert in a terminal rather than paste.
#   * Everything else gets a synthesised Ctrl+V, which is what those apps expect.
#
# The focused window's pid comes from the compositor; walking up its parents
# locates the tty of the terminal that owns it, if any.
#
# The text arrives on stdin rather than as an argument: the kernel caps a single
# argument at 128 KiB, which a long clipboard entry can exceed.
#
# Usage: paste.sh [--copy-only] < text

set -u

# The trailing x keeps the entry's own trailing newlines through $(...).
text=$(cat; printf x)
text=${text%x}

[ -n "$text" ] || exit 0

printf '%s' "$text" | wl-copy >/dev/null 2>&1

[ "${1:-}" = "--copy-only" ] && exit 0

# Let the panel give the keyboard back before anything is delivered.
sleep 0.18

focused=$(hyprctl activewindow -j 2>/dev/null)

pid=$(printf '%s' "$focused" | sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' | head -1)

tty=""
while [ -n "${pid:-}" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ]; do
  t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$t" ] && [ "$t" != "?" ]; then
    tty="$t"
    break
  fi
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done

if [ -n "$tty" ] && [ -w "/dev/$tty" ]; then
  # Bracketed paste, so the shell inserts the text rather than running it.
  { printf '\033[200~'; printf '%s' "$text"; printf '\033[201~'; } >"/dev/$tty" 2>/dev/null && exit 0
fi

# Fallback for everything without a tty, and for terminals we could not reach.
case "$(printf '%s' "$focused" | tr 'A-Z' 'a-z')" in
  *kitty*|*alacritty*|*foot*|*ghostty*|*wezterm*|*konsole*|*gnome-terminal*|*xterm*|*tmux*)
    keys="-M ctrl -M shift -k v -m shift -m ctrl"
    ;;
  *)
    keys="-M ctrl -k v -m ctrl"
    ;;
esac
for _ in 1 2 3; do
  wtype $keys 2>/dev/null && break
  sleep 0.12
done
