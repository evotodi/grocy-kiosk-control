#!/usr/bin/env python3

import logging
import os
import signal
import subprocess
import time
from gpiozero import Button

# =========================
# Configuration
# =========================

refreshGpio = 17
killGpio = 27

kioskServiceName = "grocy-kiosk.service"

debounceSeconds = 0.15

# =========================
# Logging setup
# =========================

logger = logging.getLogger("grocyButtons")
logger.setLevel(logging.INFO)

handler = logging.StreamHandler()
formatter = logging.Formatter(
    "%(asctime)s [%(levelname)s] %(message)s"
)
handler.setFormatter(formatter)
logger.addHandler(handler)

# =========================
# State
# =========================

lastPressByName: dict[str, float] = {"refresh": 0.0, "kill": 0.0}

# =========================
# Helpers
# =========================


def isDebounced(name: str) -> bool:
    now = time.monotonic()
    if (now - lastPressByName[name]) < debounceSeconds:
        logger.debug("Debounce suppressed %s button", name)
        return False
    lastPressByName[name] = now
    return True


def runCmd(args: list[str]) -> subprocess.CompletedProcess:
    logger.debug("Running command: %s", " ".join(args))
    return subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def systemctlUser(*args: str) -> subprocess.CompletedProcess:
    return runCmd(["systemctl", "--user", *args])


def isWaylandSession() -> bool:
    sessionType = os.environ.get("XDG_SESSION_TYPE", "").lower()
    logger.debug("Session type: %s", sessionType or "unknown")
    return sessionType == "wayland"


# =========================
# Kiosk control
# =========================


def refreshChromium() -> None:
    logger.info("Refresh button pressed")

    if isWaylandSession():
        result = runCmd(["wtype", "-M", "ctrl", "r", "-m", "ctrl"])
    else:
        result = runCmd(["xdotool", "key", "ctrl+r"])

    if result.returncode != 0:
        logger.error(
            "Refresh failed (rc=%s): %s",
            result.returncode,
            result.stderr.strip(),
        )


def isKioskActive() -> bool:
    result = systemctlUser("is-active", kioskServiceName)
    active = result.returncode == 0
    logger.debug("Kiosk active: %s", active)
    return active


def startKiosk() -> None:
    logger.info("Starting kiosk")
    result = systemctlUser("start", kioskServiceName)
    if result.returncode != 0:
        logger.error("Failed to start kiosk: %s", result.stderr.strip())


def stopKiosk() -> None:
    logger.info("Stopping kiosk")
    result = systemctlUser("stop", kioskServiceName)
    if result.returncode != 0:
        logger.error("Failed to stop kiosk: %s", result.stderr.strip())


def toggleKiosk() -> None:
    if isKioskActive():
        logger.info("Kiosk is active → stopping")
        stopKiosk()
    else:
        logger.info("Kiosk is inactive → starting")
        startKiosk()


# =========================
# Button callbacks
# =========================


def onRefreshPressed() -> None:
    if not isDebounced("refresh"):
        return
    refreshChromium()


def onKillPressed() -> None:
    if not isDebounced("kill"):
        return
    logger.info("Toggle button pressed")
    toggleKiosk()


# =========================
# Main
# =========================


def main() -> None:
    logger.info("Grocy kiosk GPIO controller starting")

    refreshButton = Button(refreshGpio, pull_up=True, bounce_time=0.05)
    killButton = Button(killGpio, pull_up=True, bounce_time=0.05)

    refreshButton.when_pressed = onRefreshPressed
    killButton.when_pressed = onKillPressed

    def shutdownHandler(signum, frame) -> None:
        logger.info("Received signal %s, shutting down", signum)
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, shutdownHandler)
    signal.signal(signal.SIGINT, shutdownHandler)

    signal.pause()


if __name__ == "__main__":
    main()
