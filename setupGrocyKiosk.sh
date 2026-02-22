#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Flags / Args
# -----------------------------
cleanBarcodeBuddy=0

arg_special_barcode=""
arg_special_barcode_file=""
arg_input_device=""
arg_www_user=""
arg_listen_port=""
arg_server_name=""
arg_reverse_proxy=0
arg_use_curl=0
arg_api_key=""
arg_server_address=""

die() { echo "ERROR: $*" >&2; exit 1; }

is_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

is_http_url() {
  [[ "$1" =~ ^https?://.+ ]]
}

runtime_check_user_exists() {
  local u="$1"
  getent passwd "$u" >/dev/null 2>&1 || die "User does not exist: ${u}"
}

runtime_check_input_device() {
  local dev="$1"
  [[ -e "$dev" ]] || die "Input device does not exist: ${dev}"
}

runtime_check_url_reachable_hint() {
  local url="$1"
  # Don't fail the install if network/DNS isn't up; just provide a helpful warning.
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsS --max-time 5 -o /dev/null "${url}" 2>/dev/null; then
      echo "WARNING: Could not reach server-address quickly: ${url}"
      echo "         This may be normal if networking/DNS isn't ready yet."
    fi
  fi
}

runtime_check_special_action_dir() {
  local p="$1"
  local d=""
  d="$(dirname -- "$p")"
  if [[ ! -d "${d}" ]]; then
    echo "WARNING: Special action directory does not exist yet: ${d}"
    echo "         You can create it later (e.g. sudo mkdir -p \"${d}\")."
  fi
}

usage() {
  cat <<'EOF'
Usage: setupGrocyKiosk.sh [options]

Options:
  --clean-barcodebuddy

  --input-device <path>                 (e.g. /dev/input/by-id/...event-kbd)
  --www-user <user>                     (default: www-data)

  --special-barcode <barcode>
  --special-barcode-file <path>         (default: /etc/barcodebuddy/specialAction.sh)

  --listen-port <port>                  (default: 80)
  --server-name <name>                  (default: _)
  --reverse-proxy                       (set reverse proxy mode; skips prompt)

  --use-curl                            (flag; send scans via curl to external BB)
  --server-address <url>                (e.g. https://example/api/)
  --api-key <key>

  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean-barcodebuddy)
      cleanBarcodeBuddy=1
      shift
      ;;
    --special-barcode)
      [[ $# -ge 2 ]] || die "--special-barcode requires a value"
      arg_special_barcode="$2"
      shift 2
      ;;
    --special-barcode-file)
      [[ $# -ge 2 ]] || die "--special-barcode-file requires a value"
      arg_special_barcode_file="$2"
      shift 2
      ;;
    --input-device)
      [[ $# -ge 2 ]] || die "--input-device requires a value"
      arg_input_device="$2"
      shift 2
      ;;
    --www-user)
      [[ $# -ge 2 ]] || die "--www-user requires a value"
      arg_www_user="$2"
      shift 2
      ;;
    --listen-port)
      [[ $# -ge 2 ]] || die "--listen-port requires a value"
      arg_listen_port="$2"
      shift 2
      ;;
    --server-name)
      [[ $# -ge 2 ]] || die "--server-name requires a value"
      arg_server_name="$2"
      shift 2
      ;;
    --reverse-proxy)
      arg_reverse_proxy=1
      shift
      ;;
    --use-curl)
      arg_use_curl=1
      shift
      ;;
    --api-key)
      [[ $# -ge 2 ]] || die "--api-key requires a value"
      arg_api_key="$2"
      shift 2
      ;;
    --server-address)
      [[ $# -ge 2 ]] || die "--server-address requires a value"
      arg_server_address="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

# -----------------------------
# Argument validations (syntax)
# -----------------------------
if [[ -n "${arg_listen_port}" ]] && ! is_port "${arg_listen_port}"; then
  die "--listen-port must be an integer 1..65535 (got: ${arg_listen_port})"
fi

if [[ "${arg_use_curl}" -eq 1 ]]; then
  [[ -n "${arg_server_address}" ]] || die "--use-curl requires --server-address"
  [[ -n "${arg_api_key}" ]] || die "--use-curl requires --api-key"
  is_http_url "${arg_server_address}" || die "--server-address must start with http:// or https:// (got: ${arg_server_address})"
fi

if [[ -n "${arg_server_address}" ]] && ! is_http_url "${arg_server_address}"; then
  die "--server-address must start with http:// or https:// (got: ${arg_server_address})"
fi

if [[ -n "${arg_input_device}" ]] && [[ "${arg_input_device}" != /dev/input/* ]]; then
  die "--input-device must be under /dev/input/ (got: ${arg_input_device})"
fi

if [[ -n "${arg_special_barcode_file}" ]] && [[ "${arg_special_barcode_file}" != /* ]]; then
  die "--special-barcode-file must be an absolute path (got: ${arg_special_barcode_file})"
fi

# -----------------------------
# Argument validations (runtime)
# -----------------------------
if [[ -n "${arg_www_user}" ]]; then
  runtime_check_user_exists "${arg_www_user}"
fi

if [[ -n "${arg_input_device}" ]]; then
  runtime_check_input_device "${arg_input_device}"
fi

if [[ "${arg_use_curl}" -eq 1 ]]; then
  runtime_check_url_reachable_hint "${arg_server_address}"
fi

# -----------------------------
# Paths / Names
# -----------------------------
scriptDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
projectDir="${scriptDir}"

defaultScannerDev="/dev/input/event0"
defaultSpecialBarcode="YOUR-SPECIAL-BARCODE"

buttonsPy="${projectDir}/grocyButtons.py"
buttonsUnitSrc="${projectDir}/grocy-buttons.service"
kioskUnitSrc="${projectDir}/grocy-kiosk.service"

userSystemdDir="${HOME}/.config/systemd/user"
buttonsUnitDst="${userSystemdDir}/grocy-buttons.service"
kioskUnitDst="${userSystemdDir}/grocy-kiosk.service"

# todo: Change back to Forcue repo when PRs are merged
#barcodeBuddyRepoUrl="https://github.com/Forceu/barcodebuddy.git"
barcodeBuddyRepoUrl="https://github.com/evotodi/barcodebuddy.git"
barcodeBuddyDir="/var/www/html/barcodebuddy"

nginxSitesAvailable="/etc/nginx/sites-available"
nginxSitesEnabled="/etc/nginx/sites-enabled"
barcodeBuddyNginxConf="${nginxSitesAvailable}/barcodebuddy.conf"
barcodeBuddyNginxLink="${nginxSitesEnabled}/barcodebuddy.conf"

phpFpmPoolConf="/etc/php/8.4/fpm/pool.d/www.conf"
phpFpmService="php8.4-fpm"
redisService="redis-server"
nginxService="nginx"

bbScannerUnit="/etc/systemd/system/bbscanner.service"
bbServerUnit="/etc/systemd/system/bbserver.service"
grabInputSrc="${projectDir}/grabInput.sh"
grabInputDest="/usr/local/bin/grabInput.sh"


# -----------------------------
# Helpers
# -----------------------------
requireFile() {
  local p="$1"
  if [[ ! -f "${p}" ]]; then
    echo "ERROR: Missing ${p}"
    exit 1
  fi
}

prompt() {
  local question="$1"
  local defaultValue="$2"
  local reply=""
  read -r -p "${question} [${defaultValue}]: " reply
  if [[ -z "${reply}" ]]; then
    echo "${defaultValue}"
  else
    echo "${reply}"
  fi
}

promptYesNo() {
  local question="$1"
  local defaultYesNo="$2" # "y" or "n"
  local reply=""
  local promptSuffix="y/N"
  if [[ "${defaultYesNo}" == "y" ]]; then
    promptSuffix="Y/n"
  fi

  while true; do
    read -r -p "${question} (${promptSuffix}): " reply
    if [[ -z "${reply}" ]]; then
      reply="${defaultYesNo}"
    fi
    case "${reply}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

# Add a directive within the first "location / { ... }" block if possible,
# otherwise insert a basic "location /" block into the server block.
ensureDirectiveInLocationRoot() {
  local filePath="$1"
  local directiveLine="$2"

  if sudo grep -qF "${directiveLine}" "${filePath}"; then
    return 0
  fi

  # If location / exists, insert directive before the closing brace of that block.
  if sudo grep -Eq '^\s*location\s+/\s*\{' "${filePath}"; then
    # Insert just before the first closing brace after "location / {"
    sudo awk -v ins="${directiveLine}" '
      BEGIN { inLoc=0; inserted=0 }
      /^\s*location\s+\/\s*\{/ { inLoc=1 }
      {
        if (inLoc && !inserted && /^\s*\}/) {
          print "        " ins
          inserted=1
          inLoc=0
        }
        print
      }
    ' "${filePath}" | sudo tee "${filePath}.tmp" >/dev/null
    sudo mv "${filePath}.tmp" "${filePath}"
    return 0
  fi

  # No location / block found -> inject a minimal one inside the first server block.
  sudo awk -v ins="${directiveLine}" '
    BEGIN { inserted=0 }
    {
      print
      if (!inserted && $0 ~ /^\s*server\s*\{\s*$/) {
        print "    location / {"
        print "        " ins
        print "    }"
        inserted=1
      }
    }
  ' "${filePath}" | sudo tee "${filePath}.tmp" >/dev/null
  sudo mv "${filePath}.tmp" "${filePath}"
}

# -----------------------------
# Install packages
# -----------------------------
echo "==> Installing OS packages"
sudo apt update
sudo apt install -y \
  python3-gpiozero \
  wtype \
  php8.4 \
  php8.4-fpm \
  php8.4-curl \
  php-json \
  php8.4-mbstring \
  php8.4-sqlite3 \
  php8.4-redis \
  php8.4-xml \
  redis \
  redis-server \
  screen \
  evtest \
  nginx \
  git \
  composer

# -----------------------------
# Enable gpio-shutdown overlay (GPIO3 / physical pin 5)
# -----------------------------
echo "==> Ensuring /boot/firmware/config.txt has dtoverlay=gpio-shutdown (GPIO3 / pin 5)"

bootConfig="/boot/firmware/config.txt"
overlayLine="dtoverlay=gpio-shutdown"

if [[ ! -f "${bootConfig}" ]]; then
  echo "WARNING: ${bootConfig} not found. Skipping gpio-shutdown overlay setup."
else
  if sudo grep -Fxq "${overlayLine}" "${bootConfig}"; then
    echo "==> gpio-shutdown overlay already present"
  else
    echo "==> Adding gpio-shutdown overlay to ${bootConfig}"
    echo "${overlayLine}" | sudo tee -a "${bootConfig}" >/dev/null
    echo "==> NOTE: A reboot is required for gpio-shutdown to take effect."
  fi
fi

echo "==> Ensuring user is in gpio group (may require logout/login to take effect)"
if getent group gpio >/dev/null 2>&1; then
  sudo usermod -aG gpio "${USER}" || true
fi

# -----------------------------
# Barcode Buddy install / update
# -----------------------------
echo "==> Barcode Buddy: install/update"

if [[ "${cleanBarcodeBuddy}" -eq 1 ]]; then
  echo "==> Clean mode enabled: removing Barcode Buddy and nginx site (if present)"
  sudo rm -f "${barcodeBuddyNginxLink}" || true
  sudo rm -f "${barcodeBuddyNginxConf}" || true
  sudo rm -rf "${barcodeBuddyDir}" || true
fi

if [[ -d "${barcodeBuddyDir}/.git" ]]; then
  echo "==> Barcode Buddy already present, updating via git pull"
  # Mark repo as safe for git, since we run git commands via sudo (root) but the dir may be owned by www-data.
  if ! sudo git config --system --get-all safe.directory 2>/dev/null | grep -Fxq "${barcodeBuddyDir}"; then
    sudo git config --system --add safe.directory "${barcodeBuddyDir}"
  fi
  sudo git -C "${barcodeBuddyDir}" fetch --all --prune
  sudo git -C "${barcodeBuddyDir}" pull --ff-only
elif [[ -d "${barcodeBuddyDir}" ]]; then
  echo "ERROR: ${barcodeBuddyDir} exists but is not a git checkout."
  echo "Either move it aside, or rerun with --clean-barcodebuddy"
  exit 1
else
  echo "==> Cloning Barcode Buddy into ${barcodeBuddyDir}"
  sudo mkdir -p "$(dirname "${barcodeBuddyDir}")"
  sudo git clone "${barcodeBuddyRepoUrl}" "${barcodeBuddyDir}"
  # Mark repo as safe for git, since we run git commands via sudo (root) but the dir may be owned by www-data.
  if ! sudo git config --system --get-all safe.directory 2>/dev/null | grep -Fxq "${barcodeBuddyDir}"; then
    sudo git config --system --add safe.directory "${barcodeBuddyDir}"
  fi
fi

# Also ensure safety in the update path (in case repo existed before this script version)
if ! sudo git config --system --get-all safe.directory 2>/dev/null | grep -Fxq "${barcodeBuddyDir}"; then
  sudo git config --system --add safe.directory "${barcodeBuddyDir}"
fi

sudo COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --working-dir "${barcodeBuddyDir}"


echo "==> Setting permissions for Barcode Buddy directory"
sudo chmod -R ugo+rw "${barcodeBuddyDir}"
sudo mkdir -p "${barcodeBuddyDir}/data"
sudo chown -R www-data:www-data "${barcodeBuddyDir}"
sudo chmod -R ugo+rwx "${barcodeBuddyDir}/data"

# -----------------------------
# Barcode Buddy screen/scanner services (systemd)
# -----------------------------
echo
echo "==> Barcode Buddy: installing bbserver/bbscanner systemd services"

requireFile "${grabInputSrc}"

# Install our managed grabInput.sh (do not symlink to Barcode Buddy example)
echo "==> Installing grabInput.sh to ${grabInputDest}"

# If an old symlink exists, remove it so `install` doesn't overwrite the symlink target.
if [[ -L "${grabInputDest}" ]]; then
  echo "==> Removing old symlink: ${grabInputDest} -> $(readlink "${grabInputDest}")"
  sudo rm -f "${grabInputDest}"
elif [[ -e "${grabInputDest}" && ! -f "${grabInputDest}" ]]; then
  echo "ERROR: ${grabInputDest} exists but is not a regular file or symlink. Please remove it manually."
  exit 1
fi

sudo install -o root -g root -m 0755 "${grabInputSrc}" "${grabInputDest}"

echo "Find your scanner device with one of:"
echo "  ls -l /dev/input/by-id/"
echo "  ls -l /dev/input/by-path/"
if [[ -n "${arg_input_device}" ]]; then
  scannerDev="${arg_input_device}"
else
  scannerDev="$(prompt "Path to barcode scanner input device (event-kbd)" "${defaultScannerDev}")"
fi

echo
if [[ -n "${arg_www_user}" ]]; then
  bbWwwUser="${arg_www_user}"
else
  bbWwwUser="$(prompt "Barcode Buddy www user (used to run scan jobs)" "www-data")"
fi

bbUseCurl="false"
bbServerAddress=""
bbApiKey=""
bbSpecialBarcode="${defaultSpecialBarcode}"
bbSpecialActionFile="/etc/barcodebuddy/specialAction.sh"

# Curl mode: if --use-curl supplied, do not prompt yes/no, only prompt for missing details.
if [[ "${arg_use_curl}" -eq 1 ]]; then
  bbUseCurl="true"
  if [[ -n "${arg_server_address}" ]]; then
    bbServerAddress="${arg_server_address}"
  else
    bbServerAddress="$(prompt "Barcode Buddy server address (base URL, e.g. https://example/api/)" "https://your.bbuddy.url/api/")"
  fi
  if [[ -n "${arg_api_key}" ]]; then
    bbApiKey="${arg_api_key}"
  else
    bbApiKey="$(prompt "Barcode Buddy API key" "YOUR_API_KEY")"
  fi
else
  if promptYesNo "Use curl to send scans to an external Barcode Buddy server?" "n"; then
    bbUseCurl="true"
    bbServerAddress="$(prompt "Barcode Buddy server address (base URL, e.g. https://example/api/)" "https://your.bbuddy.url/api/")"
    bbApiKey="$(prompt "Barcode Buddy API key" "YOUR_API_KEY")"
  fi
fi

# Special barcode: if args supplied, skip prompt and use them.
if [[ -n "${arg_special_barcode}" || -n "${arg_special_barcode_file}" ]]; then
  if [[ -n "${arg_special_barcode}" ]]; then
    bbSpecialBarcode="${arg_special_barcode}"
  fi
  if [[ -n "${arg_special_barcode_file}" ]]; then
    bbSpecialActionFile="${arg_special_barcode_file}"
  fi
else
  if promptYesNo "Use a special barcode for custom action?" "n"; then
    bbSpecialBarcode="$(prompt "Enter your special barcode (Do not use underscores)" "${defaultSpecialBarcode}")"
    bbSpecialActionFile="$(prompt "Where is your special action file?" "/etc/barcodebuddy/specialAction.sh")"
    echo "To create the special action file:"
    echo "  sudo mkdir -p /etc/barcodebuddy"
    echo "  sudo nano /etc/barcodebuddy/specialAction.sh"
    echo ""
    echo "Example contents:"
    echo '\
#!/bin/bash
specialActionUser() {
  echo "[specialActionUser] do something fun here"
  # e.g. play a sound, toggle a GPIO, call a local script, etc.
}
'
    echo "The specialActionUser fuction will be called when you scan your special barcode"
  fi
fi

# -----------------------------
# Runtime checks (final resolved values, including prompts)
# -----------------------------
runtime_check_user_exists "${bbWwwUser}"
runtime_check_input_device "${scannerDev}"

if [[ "${bbUseCurl}" == "true" ]]; then
  [[ -n "${bbServerAddress}" ]] || die "curl mode enabled but SERVER_ADDRESS is empty"
  [[ -n "${bbApiKey}" ]] || die "curl mode enabled but API_KEY is empty"
  is_http_url "${bbServerAddress}" || die "SERVER_ADDRESS must start with http:// or https:// (got: ${bbServerAddress})"
  runtime_check_url_reachable_hint "${bbServerAddress}"
fi

if [[ -n "${bbSpecialBarcode}" ]] && [[ "${bbSpecialActionFile}" != /* ]]; then
  die "SPECIAL_ACTION_FILE must be an absolute path (got: ${bbSpecialActionFile})"
fi
runtime_check_special_action_dir "${bbSpecialActionFile}"

echo "==> Writing ${bbServerUnit}"
sudo tee "${bbServerUnit}" >/dev/null <<EOF
[Unit]
Description=Run websocket server for barcodebuddy screen feature
Wants=network-online.target
After=network-online.target

[Service]
Type=simple

# Pre-flight checks for clearer failures
ExecStartPre=/bin/sh -lc 'command -v /usr/bin/php >/dev/null 2>&1 || { echo "[bbserver] ERROR: php not found at /usr/bin/php"; exit 1; }'
ExecStartPre=/bin/sh -lc 'test -f "${barcodeBuddyDir}/wsserver.php" || { echo "[bbserver] ERROR: wsserver.php not found: ${barcodeBuddyDir}/wsserver.php"; exit 1; }'

ExecStart=/usr/bin/php ${barcodeBuddyDir}/wsserver.php
Restart=on-failure
RestartSec=2

User=www-data
Group=www-data

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=bbserver

# Lightweight hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictNamespaces=true
RestrictRealtime=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF

echo "==> Writing ${bbScannerUnit}"
sudo tee "${bbScannerUnit}" >/dev/null <<EOF
[Unit]
Description=Grab barcode scans for barcode buddy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple

# Pre-flight info + checks so failures are obvious in journald
ExecStartPre=/bin/sh -lc 'echo "[bbscanner] Using device path: ${scannerDev}"; if command -v readlink >/dev/null 2>&1; then echo "[bbscanner] Resolved device target: $(readlink -f "${scannerDev}" 2>/dev/null || echo "(unresolved)")"; fi'
ExecStartPre=/bin/sh -lc 'test -e "${scannerDev}" || { echo "[bbscanner] ERROR: input device not found: ${scannerDev}"; echo "[bbscanner] Hint: ls -l /dev/input/by-id/"; exit 1; }'
ExecStartPre=/bin/sh -lc 'test -x "${grabInputDest}" || { echo "[bbscanner] ERROR: grabInput.sh not executable: ${grabInputDest}"; exit 1; }'

ExecStart=${grabInputDest} ${scannerDev}
Restart=on-failure
RestartSec=2

# Logging (keep logs for troubleshooting)
StandardOutput=journal
StandardError=journal
SyslogIdentifier=bbscanner

# Environment used by grabInput.sh
Environment=SCRIPT_LOCATION=${barcodeBuddyDir}/index.php
Environment=USE_CURL=${bbUseCurl}
Environment=WWW_USER=${bbWwwUser}
Environment=SERVER_ADDRESS=${bbServerAddress}
Environment=API_KEY=${bbApiKey}
Environment=SPECIAL_BARCODE=${bbSpecialBarcode}
Environment=SPECIAL_ACTION_FILE=${bbSpecialActionFile}

# Lightweight hardening (service runs as root to use evtest --grab)
NoNewPrivileges=true
PrivateTmp=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictNamespaces=true
RestrictRealtime=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF

echo "==> Enabling and starting bbserver/bbscanner"
sudo systemctl daemon-reload
sudo systemctl enable --now bbserver.service
sudo systemctl enable --now bbscanner.service

echo "==> Barcode Buddy services status:"
sudo systemctl --no-pager status bbserver.service || true
sudo systemctl --no-pager status bbscanner.service || true

# -----------------------------
# PHP-FPM config tweak
# -----------------------------
echo "==> Configuring PHP-FPM pool (pm.max_children = 10)"
if [[ ! -f "${phpFpmPoolConf}" ]]; then
  echo "ERROR: Missing ${phpFpmPoolConf}"
  exit 1
fi

if sudo grep -Eq '^\s*;?\s*pm\.max_children\s*=' "${phpFpmPoolConf}"; then
  sudo sed -i -E 's/^\s*;?\s*pm\.max_children\s*=.*$/pm.max_children = 10/' "${phpFpmPoolConf}"
else
  echo "pm.max_children = 10" | sudo tee -a "${phpFpmPoolConf}" >/dev/null
fi

# -----------------------------
# Nginx server block prompts
# -----------------------------
echo
echo "==> Nginx configuration for Barcode Buddy"
echo "You will be prompted for listen port and server_name (domain/IP)."

if [[ -n "${arg_listen_port}" ]]; then
  listenPort="${arg_listen_port}"
else
  listenPort="$(prompt "Listen port for Barcode Buddy nginx server block" "80")"
fi

if [[ -n "${arg_server_name}" ]]; then
  serverName="${arg_server_name}"
else
  serverName="$(prompt "server_name (domain or IP, space-separated allowed)" "_")"
fi

echo
reverseProxyMode=0
if [[ "${arg_reverse_proxy}" -eq 1 ]]; then
  reverseProxyMode=1
else
  if promptYesNo "Is nginx acting as a reverse proxy in front of Barcode Buddy (proxy_pass)?" "n"; then
    reverseProxyMode=1
  fi
fi

# Build config from the example, then apply your choices.
echo "==> Preparing nginx config from Barcode Buddy example"
exampleConf="${barcodeBuddyDir}/example/nginxConfiguration.conf"
if [[ ! -f "${exampleConf}" ]]; then
  echo "ERROR: Cannot find ${exampleConf}"
  exit 1
fi

shouldWriteNginxConf=1
if [[ -f "${barcodeBuddyNginxConf}" ]] && [[ "${cleanBarcodeBuddy}" -ne 1 ]]; then
  echo
  echo "Existing nginx config found at:"
  echo "  ${barcodeBuddyNginxConf}"
  if promptYesNo "Overwrite it with a newly generated config (your old file will be replaced)?" "n"; then
    shouldWriteNginxConf=1
  else
    shouldWriteNginxConf=0
  fi
fi

if [[ "${shouldWriteNginxConf}" -eq 1 ]]; then
  tempConf="$(mktemp)"
  sudo cp "${exampleConf}" "${tempConf}"

  # Update fastcgi socket to php8.4-fpm
  sudo sed -i -E \
    's#fastcgi_pass\s+unix:/var/run/php/php[0-9]+\.[0-9]+-fpm\.sock;#fastcgi_pass unix:/var/run/php/php8.4-fpm.sock;#g' \
    "${tempConf}"

  # Ensure root points to our install dir (if present in example)
  sudo sed -i -E \
    "s#root\s+/var/www/html/barcodebuddy/?;#root ${barcodeBuddyDir};#g" \
    "${tempConf}"

  # Set listen port: replace first "listen N;" if present, else inject inside server block
  if sudo grep -Eq '^\s*listen\s+[0-9]+;' "${tempConf}"; then
    sudo sed -i -E "0,/^\s*listen\s+[0-9]+;/{s/^\s*listen\s+[0-9]+;/    listen ${listenPort};/}" "${tempConf}"
  else
    sudo sed -i -E "0,/server\s*\{/{s/server\s*\{/server {\n    listen ${listenPort};/}" "${tempConf}"
  fi

  # Set server_name
  if sudo grep -Eq '^\s*server_name\s+' "${tempConf}"; then
    sudo sed -i -E "s/^\s*server_name\s+.*;/    server_name ${serverName};/" "${tempConf}"
  else
    sudo sed -i -E "0,/server\s*\{/{s/server\s*\{/server {\n    server_name ${serverName};/}" "${tempConf}"
  fi

  # -----------------------------------
  # SSE buffering prompts / fixes
  # -----------------------------------
  echo
  echo "==> Barcode Buddy Screen / SSE buffering"

  # Case A: nginx -> php-fpm (fastcgi). Pass header through if user wants.
  if promptYesNo 'Apply "fastcgi_pass_header \"X-Accel-Buffering\";" in the PHP location block?' "y"; then
    if ! sudo grep -q 'fastcgi_pass_header\s+"X-Accel-Buffering"' "${tempConf}"; then
      sudo sed -i -E \
        '0,/fastcgi_pass\s+unix:\/var\/run\/php\/php8\.4-fpm\.sock;/{s#(fastcgi_pass\s+unix:/var/run/php/php8\.4-fpm\.sock;)#\1\n        fastcgi_pass_header "X-Accel-Buffering";#}' \
        "${tempConf}"
    fi
  else
    echo "Leaving fastcgi SSE header setting unchanged."
  fi

  # Case B: nginx is reverse-proxying to an upstream (proxy_pass). Disable proxy buffering if user wants.
  if [[ "${reverseProxyMode}" -eq 1 ]]; then
    echo
    echo "Reverse proxy mode detected."
    if promptYesNo 'Disable proxy buffering for SSE by adding "proxy_buffering off;" (recommended for SSE)?' "y"; then
      ensureDirectiveInLocationRoot "${tempConf}" "proxy_buffering off;"
    else
      echo "Leaving proxy buffering unchanged."
    fi
  fi

  sudo mkdir -p "${nginxSitesAvailable}"
  sudo mv "${tempConf}" "${barcodeBuddyNginxConf}"
  echo "==> Wrote nginx config: ${barcodeBuddyNginxConf}"
else
  echo "==> Keeping existing nginx config unchanged."
fi

# Enable site symlink (do not remove others)
echo "==> Enabling nginx site (symlink)"
sudo mkdir -p "${nginxSitesEnabled}"
if [[ -L "${barcodeBuddyNginxLink}" || -e "${barcodeBuddyNginxLink}" ]]; then
  echo "==> nginx site link already exists: ${barcodeBuddyNginxLink}"
else
  sudo ln -s "${barcodeBuddyNginxConf}" "${barcodeBuddyNginxLink}"
fi

echo "==> Testing nginx configuration"
sudo nginx -t

# -----------------------------
# Enable/restart system services
# -----------------------------
echo "==> Enabling and restarting nginx/php-fpm/redis"
sudo systemctl enable --now "${phpFpmService}"
sudo systemctl enable --now "${redisService}"
sudo systemctl enable --now "${nginxService}"

sudo systemctl restart "${phpFpmService}"
sudo systemctl restart "${redisService}"
sudo systemctl restart "${nginxService}"

# -----------------------------
# Install systemd USER units for kiosk/buttons
# -----------------------------
echo "==> Installing Grocy kiosk/button user services"
requireFile "${buttonsPy}"
requireFile "${buttonsUnitSrc}"
requireFile "${kioskUnitSrc}"

chmod +x "${buttonsPy}"

mkdir -p "${userSystemdDir}"
cp -f "${buttonsUnitSrc}" "${buttonsUnitDst}"
cp -f "${kioskUnitSrc}" "${kioskUnitDst}"

systemctl --user daemon-reload
systemctl --user enable --now grocy-kiosk.service
systemctl --user enable --now grocy-buttons.service

echo
echo "==> Grocy services status:"
systemctl --user --no-pager status grocy-kiosk.service || true
systemctl --user --no-pager status grocy-buttons.service || true

echo
echo "==> Barcode Buddy should now be served via nginx on port ${listenPort} (server_name: ${serverName})."
echo "==> Useful logs:"
echo "journalctl --user -u grocy-buttons.service -f"
echo "journalctl --user -u grocy-kiosk.service -f"
echo "sudo journalctl -u ${nginxService} -f"
echo "sudo journalctl -u ${phpFpmService} -f"
echo "sudo journalctl -u bbscanner.service -f"
echo "sudo journalctl -u bbserver.service -f"
echo
echo "DONE."
echo "Note: If gpio group membership was newly added, log out and back in (or reboot) once."
