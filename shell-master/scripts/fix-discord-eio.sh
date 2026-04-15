#!/usr/bin/env bash
# Quick fix for Discord EIO error (Arch/Hyprland)
# Clears corrupt cache, resets temp state, and restarts Discord cleanly.

echo "🧹 Cleaning Discord cache and restarting..."

# Kill all running Discord instances
pkill Discord 2>/dev/null

# Wait briefly to ensure all processes are stopped
sleep 1

# Remove problematic caches
rm -rf ~/.config/discord/Cache \
       ~/.config/discord/Code\ Cache \
       ~/.config/discord/Service\ Worker \
       ~/.config/discord/GPUCache

# Ensure /tmp is writable (sometimes becomes read-only)
if mount | grep -q "/tmp.*ro"; then
  echo "⚙️  Remounting /tmp as read-write..."
  sudo mount -o remount,rw /tmp
fi

# Restart Discord silently (so EIO logs don’t reappear)
nohup discord > /dev/null 2>&1 &

echo "✅ Discord restarted cleanly!"
