#!/bin/bash
set -euo pipefail

# Needs to be adjusted if Barcode Buddy runs on the same server
SCRIPT_LOCATION="${SCRIPT_LOCATION:="/var/www/html/barcodebuddy/index.php"}"
# Needs to be adjusted if Barcode Buddy runs on an external server
SERVER_ADDRESS="${SERVER_ADDRESS:="https://your.bbuddy.url/api/"}"
# Set to true if an external server is used
USE_CURL="${USE_CURL:="false"}"
WWW_USER="${WWW_USER:="www-data"}"
IS_DOCKER="${IS_DOCKER:="false"}"
# Enter API key if an external server is being used
API_KEY="${API_KEY:="YOUR_API_KEY"}"

# Set a custom barcode below. If this barcode is scanned, specialAction() will be executed
SPECIAL_BARCODE="${SPECIAL_BARCODE:="YOUR-CUSTOM-BARCODE"}"

# Optional: user hook file for special barcode actions (sourced if present).
# Recommended location for local customization:
SPECIAL_ACTION_FILE="${SPECIAL_ACTION_FILE:="/etc/barcodebuddy/specialAction.sh"}"

DEBUG_EVTEST=false

log() { echo "[ScannerConnection] $*"; }

to_bool() {
  case "${1,,}" in
    1|true|yes|y|on) echo "true" ;;
    *)               echo "false" ;;
  esac
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "ERROR: Missing command: $1"; exit 1; }
}

specialAction() {
  log "Custom barcode scanned"

  if [[ -f "${SPECIAL_ACTION_FILE}" ]]; then
    log "Sourcing special action file: ${SPECIAL_ACTION_FILE}"

    # Be forgiving while sourcing: user hook may reference vars that aren't set.
    set +u
    # shellcheck source=/dev/null
    . "${SPECIAL_ACTION_FILE}"
    set -u

    # If the sourced file defines a function named specialActionUser, call it.
    if declare -F specialActionUser >/dev/null 2>&1; then
      specialActionUser
    else
      log "NOTE: ${SPECIAL_ACTION_FILE} sourced, but no specialActionUser() function was found."
    fi
  else
    log "No special action file found at ${SPECIAL_ACTION_FILE} (skipping)."
  fi
}

declare -A CODE_MAP_CHAR=( ["(KEY_0)"]="0" \
  ["(KEY_1)"]="1" \
  ["(KEY_2)"]="2" \
  ["(KEY_3)"]="3" \
  ["(KEY_4)"]="4" \
  ["(KEY_5)"]="5" \
  ["(KEY_6)"]="6" \
  ["(KEY_7)"]="7" \
  ["(KEY_8)"]="8" \
  ["(KEY_9)"]="9" \
  ["(KEY_KP0)"]="0" \
  ["(KEY_KP1)"]="1" \
  ["(KEY_KP2)"]="2" \
  ["(KEY_KP3)"]="3" \
  ["(KEY_KP4)"]="4" \
  ["(KEY_KP5)"]="5" \
  ["(KEY_KP6)"]="6" \
  ["(KEY_KP7)"]="7" \
  ["(KEY_KP8)"]="8" \
  ["(KEY_KP9)"]="9" \
  ["(KEY_NUMERIC_0)"]="0" \
  ["(KEY_NUMERIC_1)"]="1" \
  ["(KEY_NUMERIC_2)"]="2" \
  ["(KEY_NUMERIC_3)"]="3" \
  ["(KEY_NUMERIC_4)"]="4" \
  ["(KEY_NUMERIC_5)"]="5" \
  ["(KEY_NUMERIC_6)"]="6" \
  ["(KEY_NUMERIC_7)"]="7" \
  ["(KEY_NUMERIC_8)"]="8" \
  ["(KEY_NUMERIC_9)"]="9" \
  ["(KEY_A)"]="A" \
  ["(KEY_B)"]="B" \
  ["(KEY_C)"]="C" \
  ["(KEY_D)"]="D" \
  ["(KEY_E)"]="E" \
  ["(KEY_F)"]="F" \
  ["(KEY_G)"]="G" \
  ["(KEY_H)"]="H" \
  ["(KEY_I)"]="I" \
  ["(KEY_J)"]="J" \
  ["(KEY_K)"]="K" \
  ["(KEY_L)"]="L" \
  ["(KEY_M)"]="M" \
  ["(KEY_N)"]="N" \
  ["(KEY_O)"]="O" \
  ["(KEY_P)"]="P" \
  ["(KEY_Q)"]="Q" \
  ["(KEY_R)"]="R" \
  ["(KEY_S)"]="S" \
  ["(KEY_T)"]="T" \
  ["(KEY_U)"]="U" \
  ["(KEY_V)"]="V" \
  ["(KEY_W)"]="W" \
  ["(KEY_X)"]="X" \
  ["(KEY_Y)"]="Y" \
  ["(KEY_Z)"]="Z" \
  ["(KEY_DOT)"]="." \
  ["(KEY_KPDOT)"]="." \
  ["(KEY_MINUS)"]="-" \
  ["(KEY_KPMINUS)"]="-" \
  ["(KEY_SLASH)"]="-" \
  ["(KEY_SEMICOLON)"]=":" \
  ["(KEY_ENTER)"]="KEY_ENTER" \
  ["(KEY_KPENTER)"]="KEY_ENTER" )

NON_ALLOWED_CHAR="NONE"

if [[ $EUID -ne 0 ]]; then
  log "ERROR: This script must be run as root"
  exit 1
fi

USE_CURL="$(to_bool "${USE_CURL}")"
IS_DOCKER="$(to_bool "${IS_DOCKER}")"

need_cmd evtest
need_cmd systemd-run
need_cmd php
if [[ "${USE_CURL}" == "true" ]]; then
  need_cmd curl
fi

if [[ "${IS_DOCKER}" == "true" ]]; then
  if [[ "$(printenv ATTACH_BARCODESCANNER || true)" != "true" ]]; then
    log "Not starting service, as ATTACH_BARCODESCANNER has not been passed"
    exit 0
  fi
fi

if [[ "${USE_CURL}" == "false" ]]; then
  if [[ ! -f "${SCRIPT_LOCATION}" ]]; then
    log "ERROR: SCRIPT_LOCATION not found: ${SCRIPT_LOCATION}"
    exit 1
  fi
fi

deviceToUse=""
# If no arguments passed, we check if there is only one input device
# (most likely the case for docker images)
if [[ $# -eq 0 ]]; then
  nInputEvents=$(ls 2>/dev/null -Ubad1 -- /dev/input/event* | wc -l)
  if [[ "${nInputEvents}" = 1 ]]; then
    deviceToUse=$(ls /dev/input/event* | head -n 1)
  else
    log "ERROR: No argument provided and more than one device in /dev/input/"
    log "Usage: grabInput.sh /dev/input/eventX"
    exit 1
  fi
else
  deviceToUse="$1"
fi

if [[ ! -e "${deviceToUse}" ]]; then
  log "ERROR: Input device not found: ${deviceToUse}"
  exit 1
fi

trap 'log "Stopping"; exit 0' TERM INT

returnAllowedCharacter() {
  for key in "${!CODE_MAP_CHAR[@]}"; do
    if [[ $1 =~ "$key" && $1 =~ "time" && $1 =~ "value 1" ]]; then
      echo "${CODE_MAP_CHAR[$key]}"
      return
    fi
  done
  echo "$NON_ALLOWED_CHAR"
}

launch_scan_job() {
  local barcode="$1"
  if [[ -z "${barcode}" ]]; then
    return 0
  fi

  local unit
  unit="bbscan-$(date +%s%N)"

  log "Sending to unit ${unit}"

  /usr/bin/systemd-run \
    --quiet \
    --collect \
    --unit="${unit}" \
    --property="Type=oneshot" \
    --property="User=${WWW_USER}" \
    --property="WorkingDirectory=$(dirname "$SCRIPT_LOCATION")" \
    --property="TimeoutStartSec=10s" \
    --property="Nice=10" \
    --property="IOSchedulingClass=best-effort" \
    /usr/bin/php "$SCRIPT_LOCATION" "$barcode"
}

send_via_curl() {
  local barcode="$1"

  log "Sending barcode ${barcode} via curl"

  curl --fail-with-body --silent --show-error \
    --get \
    --data-urlencode "add=${barcode}" \
    "${SERVER_ADDRESS}action/scan?apikey=${API_KEY}"
}

log "Script location: ${SCRIPT_LOCATION}"
log "WWW User: ${WWW_USER}"
log "Use curl: ${USE_CURL}"
if [[ "${USE_CURL}" == "true" ]]; then
  log "Server address: ${SERVER_ADDRESS}"
  log "Api key: ${API_KEY}"
fi
log "Special barcode: ${SPECIAL_BARCODE}"
log "Special action file: ${SPECIAL_ACTION_FILE}"

enteredText=""
log "Waiting for scanner input on ${deviceToUse}"
evtest --grab "$deviceToUse" | while read -r line; do
  if [[ "${DEBUG_EVTEST}" == "true" ]]; then
    log "evtest grabbed: ${line}"
    log "enteredText: ${enteredText}"
  fi
  key="$(returnAllowedCharacter "{$line}")"
  if [[ "$key" != "$NON_ALLOWED_CHAR" ]]; then
    if [[ "$key" != "KEY_ENTER" ]]; then
      enteredText+="$key"
    else
      log "Received: ${enteredText}"
      if [[ "$enteredText" == "$SPECIAL_BARCODE" ]]; then
        specialAction
      else
        if [[ "${USE_CURL}" == "false" ]]; then
          launch_scan_job "$enteredText"
        else
          send_via_curl "$enteredText"
        fi
      fi
      enteredText=""
    fi
  fi
done