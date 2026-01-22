#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Flags
# -----------------------------
cleanBarcodeBuddy=0

for arg in "$@"; do
  case "${arg}" in
    --clean-barcodebuddy)
      cleanBarcodeBuddy=1
      ;;
    -h|--help)
      echo "Usage: $0 [--clean-barcodebuddy]"
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}"
      echo "Use --help for usage."
      exit 1
      ;;
  esac
done

# -----------------------------
# Paths / Names
# -----------------------------
projectDir="${HOME}/GrocyKioskCtrl"

buttonsPy="${projectDir}/grocyButtons.py"
buttonsUnitSrc="${projectDir}/grocy-buttons.service"
kioskUnitSrc="${projectDir}/grocy-kiosk.service"

userSystemdDir="${HOME}/.config/systemd/user"
buttonsUnitDst="${userSystemdDir}/grocy-buttons.service"
kioskUnitDst="${userSystemdDir}/grocy-kiosk.service"

barcodeBuddyRepoUrl="https://github.com/Forceu/barcodebuddy.git"
barcodeBuddyDir="/var/www/html/barcodebuddy"

nginxSitesAvailable="/etc/nginx/sites-available"
nginxSitesEnabled="/etc/nginx/sites-enabled"
barcodeBuddyNginxConf="${nginxSitesAvailable}/barcodebuddy.conf"
barcodeBuddyNginxLink="${nginxSitesEnabled}/barcodebuddy.conf"

phpFpmPoolConf="/etc/php/8.4/fpm/pool.d/www.conf"
phpFpmService="php8.4-fpm"
redisService="redis-server"
nginxService="nginx"

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
  redis \
  redis-server \
  screen \
  evtest \
  nginx \
  git

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
fi

echo "==> Setting permissions for Barcode Buddy data directory"
sudo mkdir -p "${barcodeBuddyDir}/data"
sudo chown -R www-data:www-data "${barcodeBuddyDir}/data"
sudo chmod -R u+rwX,g+rwX,o-rwx "${barcodeBuddyDir}/data"

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
listenPort="$(prompt "Listen port for Barcode Buddy nginx server block" "80")"
serverName="$(prompt "server_name (domain or IP, space-separated allowed)" "_")"

echo
reverseProxyMode=0
if promptYesNo "Is nginx acting as a reverse proxy in front of Barcode Buddy (proxy_pass)?" "n"; then
  reverseProxyMode=1
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
echo
echo "DONE."
echo "Note: If gpio group membership was newly added, log out and back in (or reboot) once."
