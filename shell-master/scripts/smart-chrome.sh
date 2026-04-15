#!/usr/bin/env bash

URL="$1"

if [ -z "$URL" ]; then
  echo "Usage: $0 <URL>"
  exit 1
fi

CURRENT_WS=$(hyprctl activeworkspace -j | jq -r '.id')

# Get Chrome windows in the current workspace
CHROME_IN_CURRENT_WS=$(hyprctl clients -j | jq -r --arg ws "$CURRENT_WS" '
  .[] | select(.workspace.id == ($ws | tonumber) and .class == "google-chrome-stable") | .address
')

if [ -n "$CHROME_IN_CURRENT_WS" ]; then
  # Chrome exists in this workspace → open link in new tab
  setsid google-chrome-stable --new-tab "$URL" >/dev/null 2>&1 &
else
  # No Chrome in this workspace → open a new Chrome window here
  hyprctl dispatch exec "firefox --new-window $URL"
fi
