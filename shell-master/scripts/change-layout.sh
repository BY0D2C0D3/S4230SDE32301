#!/usr/bin/env bash

conf="$HOME/.config/hypr/hyprland.conf"

current=$(hyprctl getoption general:layout | awk 'NR==1 {print $2}')

if [[ "$current" == "dwindle" ]]; then
    sed -i 's/layout *= *dwindle/layout = scrolling/' "$conf"
    hyprctl keyword general:layout scrolling
    notify-send "Layout changed: Scrolling"

elif [[ "$current" == "scrolling" ]]; then
    sed -i 's/layout *= *scrolling/layout = dwindle/' "$conf"
    hyprctl keyword general:layout dwindle
    notify-send "Layout changed: Dwindle"
fi