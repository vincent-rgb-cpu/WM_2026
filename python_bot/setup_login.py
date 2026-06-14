#!/usr/bin/env python3
"""
setup_login.py  --  One-time interactive session capture for SRF Tippspiel.

Run this ONCE before the automated bot.  It opens a visible Chromium window,
lets you log in manually (including any CAPTCHA or 2FA), then saves the
authenticated browser state (cookies + localStorage) to srg_session.json.

The headless submit_tips.py script loads that file on every automated run so
it starts already logged in — no credentials are ever stored in plain text.

Usage:
    python3 python_bot/setup_login.py

After running:
    The file  python_bot/srg_session.json  will be created.
    Re-run this script whenever that session expires (typically after several
    weeks, or after an SRF password change).
"""

import pathlib
import sys
from playwright.sync_api import sync_playwright

# ── configuration ─────────────────────────────────────────────────────────────
SRF_URL      = "https://wmtippspiel.srf.ch/"
SESSION_FILE = pathlib.Path(__file__).parent / "srg_session.json"


def main() -> None:
    print("=" * 62)
    print("  SRF Tippspiel — one-time login session capture")
    print("=" * 62)
    print()

    with sync_playwright() as p:
        # Launch a visible (non-headless) browser so you can interact normally.
        browser = p.chromium.launch(headless=False, slow_mo=50)

        # A fresh context with no stored state — clean slate every time you
        # run this script, which avoids stale-cookie edge cases.
        context = browser.new_context(
            viewport={"width": 1280, "height": 800},
            locale="de-CH",   # Swiss-German locale; helps with language detection
        )
        page = context.new_page()

        print(f"Opening {SRF_URL} ...")
        page.goto(SRF_URL, wait_until="domcontentloaded")

        print()
        print("A Chromium browser window has opened.")
        print()
        print("Steps:")
        print("  1. Accept the cookie banner if it appears.")
        print("  2. Click the login button and sign in with your SRF account.")
        print("  3. Complete any CAPTCHA or two-factor authentication step.")
        print("  4. Wait until you can see your tips page (fully logged in).")
        print("  5. Return to THIS terminal window and press ENTER.")
        print()
        print("Waiting for you to finish ... ", end="", flush=True)
        input()   # blocks until the user presses ENTER

        # Save the entire browser context (cookies, localStorage, sessionStorage).
        context.storage_state(path=str(SESSION_FILE))

        print()
        print(f"Session saved to:  {SESSION_FILE}")
        print()
        print("You can now run submit_tips.py automatically.")
        print("The session remains valid until SRF expires it (typically weeks).")

        browser.close()


if __name__ == "__main__":
    main()
