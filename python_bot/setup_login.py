#!/usr/bin/env python3
"""
setup_login.py  --  One-time interactive session capture for SRF Tippspiel.

HOW THIS WORKS (and why it fixes the "browser not safe" error):
  When Playwright LAUNCHES a browser it injects automation flags that Google
  OAuth can detect, causing the "browser not safe" warning.

  This script takes a different approach:
    1. YOU open Brave yourself (via a terminal command printed below).
    2. You log in to SRF normally — Brave looks exactly like a regular browser.
    3. This script connects to the ALREADY-RUNNING Brave through its built-in
       debug port (remote debugging) and copies the session cookies.

  Playwright never touches the browser during login, so Google sees nothing
  unusual.

Usage:
    python3 python_bot/setup_login.py

IMPORTANT: Quit Brave Browser 2 first — Chrome/Brave locks their profile
directory while running, so the second instance (with the debug port) won't
start correctly if another instance is already using the same profile.
"""

import pathlib
import sys
import time
import urllib.request
import urllib.error
import subprocess
from playwright.sync_api import sync_playwright

# ── configuration ─────────────────────────────────────────────────────────────
SRF_URL      = "https://wmtippspiel.srf.ch/"
SESSION_FILE = pathlib.Path(__file__).parent / "srg_session.json"
BRAVE_EXE    = "/Applications/Brave Browser 2.app/Contents/MacOS/Brave Browser"
CDP_PORT     = 9222   # Brave's remote-debugging port; change if 9222 is in use


def wait_for_cdp(port: int, timeout: int = 30) -> bool:
    """Poll until Brave's debug endpoint is ready (returns True) or times out."""
    url = f"http://localhost:{port}/json/version"
    for _ in range(timeout * 2):
        try:
            urllib.request.urlopen(url, timeout=1)
            return True
        except (urllib.error.URLError, OSError):
            time.sleep(0.5)
    return False


def main() -> None:
    print("=" * 62)
    print("  SRF Tippspiel — session capture (no automation flags)")
    print("=" * 62)
    print()

    if not pathlib.Path(BRAVE_EXE).exists():
        sys.exit(f"ERROR: Brave not found at:\n  {BRAVE_EXE}")

    # ── Step 1: make sure the normal Brave instance is closed ────────────────
    print("Step 1 of 3 — Close Brave Browser 2")
    print()
    print("  Brave locks its profile while running, so we need it closed")
    print("  before we can open a second instance with the debug port.")
    print()
    input("  Press ENTER once Brave Browser 2 is fully closed ... ")
    print()

    # ── Step 2: launch Brave with the remote-debugging port ──────────────────
    # We launch the binary directly (NOT via Playwright), so none of the
    # automation flags are injected. The browser behaves like a normal Brave.
    print("Step 2 of 3 — Launching Brave with remote debugging ...")
    subprocess.Popen(
        [BRAVE_EXE, f"--remote-debugging-port={CDP_PORT}", SRF_URL],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    if not wait_for_cdp(CDP_PORT):
        sys.exit(
            f"ERROR: Brave did not start its debug port on {CDP_PORT} within 15s.\n"
            "Try changing CDP_PORT to 9223 at the top of this file."
        )
    print(f"  Brave is running on debug port {CDP_PORT}.")
    print()

    # ── Step 3: wait for user to log in ──────────────────────────────────────
    print("Step 3 of 3 — Log in to SRF Tippspiel in the Brave window")
    print()
    print("  The browser that just opened is your real Brave profile.")
    print("  Log in to SRF using Google (or however you normally log in).")
    print("  Google will NOT show a 'browser not safe' warning because")
    print("  this is a completely normal Brave window — no automation flags.")
    print()
    input("  Press ENTER once you are fully logged in to SRF ... ")
    print()

    # ── Connect via CDP and export the session ────────────────────────────────
    # Playwright connects as a passive observer — it does not inject scripts
    # or modify the page in any way.
    print("Saving session cookies ...")
    with sync_playwright() as p:
        browser = p.chromium.connect_over_cdp(f"http://localhost:{CDP_PORT}")

        if not browser.contexts:
            sys.exit("ERROR: No browser context found. Make sure you are logged in.")

        context = browser.contexts[0]
        context.storage_state(path=str(SESSION_FILE))

    print(f"Session saved to:  {SESSION_FILE}")
    print()
    print("You can now close Brave and run:   make submit")
    print("Re-run this script when the session expires (typically weeks).")


if __name__ == "__main__":
    main()
