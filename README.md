# Grocy Kiosk Controller

GPIO button controller + systemd units for a Chromium-based kiosk on **Raspberry Pi OS (Trixie)** using **labwc / Wayland**.

This project installs and manages:
- A Chromium kiosk service (`grocy-kiosk.service`)
- A GPIO button daemon (`grocy-buttons.service`)
- Barcode Buddy (PHP app) served via nginx + php-fpm + redis
- Optional Pi shutdown button via `/boot/firmware/config.txt` (`dtoverlay=gpio-shutdown`)

---

## Hardware Wiring

Momentary pushbuttons wired **active-low** (button shorts GPIO to GND).

### Buttons used by this project
| Function | GPIO | Physical Pin | Wiring |
|--------|------|--------------|--------|
| Refresh | GPIO 17 | Pin 11 | Button → GND |
| Toggle kiosk | GPIO 27 | Pin 13 | Button → GND |

Notes:
- Internal pull-ups are enabled via `gpiozero`
- Avoid GPIO pins used by the shutdown overlay (below)

### Shutdown button (gpio-shutdown overlay)
If enabled, `/boot/firmware/config.txt` contains:

- `dtoverlay=gpio-shutdown`

This overlay uses:
- **GPIO3** (physical **pin 5**) for shutdown

Wire:
- GPIO3 (pin 5) → momentary button → GND

---

## Kiosk Services

### `grocy-kiosk.service`
Runs Chromium in kiosk mode against:

- `http://localhost/screen.php`

### `grocy-buttons.service`
Runs `grocyButtons.py` which:
- **Refresh button**: sends Ctrl+R using `wtype` (Wayland-safe)
- **Toggle button**: starts/stops the kiosk via `systemctl --user start/stop grocy-kiosk.service`
- Logs actions to journald

---

## Barcode Buddy

The setup script installs Barcode Buddy to:

- `/var/www/html/barcodebuddy`

and installs/starts:
- nginx
- php8.4-fpm
- redis-server

It also modifies:
- `/etc/php/8.4/fpm/pool.d/www.conf` to set `pm.max_children = 10`

### nginx configuration
The setup script generates an nginx server block based on prompts:
- listen port (default `80`)
- server_name (default `_`)

It uses Barcode Buddy’s example config as a base and updates the PHP-FPM socket to `php8.4-fpm.sock`.

### Screen / SSE buffering prompts
Barcode Buddy’s Screen module uses SSE (server-sent events). Depending on your architecture, buffering can break SSE.

The setup script will prompt you for two optional mitigations:

1) **nginx → php-fpm (fastcgi)**:
   - add `fastcgi_pass_header "X-Accel-Buffering";`

2) **nginx reverse proxy (proxy_pass)**:
   - add `proxy_buffering off;` (if nginx is proxying to an upstream)

---

## Installation

From the project directory:

```bash
chmod +x setupGrocyKiosk.sh
./setupGrocyKiosk.sh
