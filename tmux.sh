#!/bin/bash

scriptname="tmux.sh"
session_name="tmux_test"
tmux_main_window="test-Main"
scriptfolder="./"

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
	tmux send-keys -t "${session_name}:${tmux_main_window}" "clear;cd ${scriptfolder};bash ${scriptname}" ENTER
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
	exit 1
}

function create_panes() {
	# Create a tmux session with two panes
	tmux split-window -v -t ${session_name}:0.0
	tmux split-window -h -t ${session_name}:0.0
	tmux split-window -h -t ${session_name}:0.2
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

check_superuser
set_script_paths
transfer_to_tmux
create_panes
