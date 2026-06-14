#!/usr/bin/env python3
"""
setup_login.py  --  One-time interactive session capture for SRF Tippspiel.

Run this ONCE before the automated bot.  It opens a visible Brave browser
window, lets you log in manually (including any CAPTCHA or 2FA), then saves
the authenticated browser state (cookies + localStorage) to srg_session.json.

The headless submit_tips.py script loads that file on every automated run so
it starts already logged in — no credentials are ever stored in plain text.

WHY BRAVE?
Playwright's bundled Chromium is flagged as "not safe" by some sites because
it has no verified publisher.  Brave is your real, installed browser so sites
treat it as a normal user visit.  The saved session file is then loaded by the
headless bot which uses Playwright's Chromium — that works fine because the
bot only needs the cookies, not the browser brand.

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

# Brave executable paths for each platform.
# Playwright launches Brave like any Chromium-based browser by passing the
# executable_path argument — no separate driver or extension is needed.
BRAVE_PATHS = [
    # macOS — "Brave Browser 2" (second profile / nightly build)
    "/Applications/Brave Browser 2.app/Contents/MacOS/Brave Browser",
    # macOS (standard install location)
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    # Linux
    "/usr/bin/brave-browser",
    "/usr/bin/brave",
    # Windows (uncomment if needed)
    # r"C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe",
]


def find_brave() -> str:
    """Return the path to the Brave executable, or exit with a helpful message."""
    for path in BRAVE_PATHS:
        if pathlib.Path(path).exists():
            return path
    sys.exit(
        "Could not find Brave Browser.\n"
        "Set the correct path in the BRAVE_PATHS list at the top of setup_login.py.\n"
        "To find it: run  `which brave-browser`  or look in /Applications on macOS."
    )


def main() -> None:
    print("=" * 62)
    print("  SRF Tippspiel — one-time login session capture (Brave)")
    print("=" * 62)
    print()

    brave_exe = find_brave()
    print(f"Using Brave at: {brave_exe}")
    print()

    with sync_playwright() as p:
        # Launch YOUR installed Brave browser (not Playwright's bundled Chromium).
        # Brave is Chromium-based so the Playwright chromium API works identically.
        # slow_mo adds a small delay between actions — useful during interactive use.
        browser = p.chromium.launch(
            executable_path=brave_exe,
            headless=False,
            slow_mo=50,
            args=["--no-sandbox"],   # avoids permission prompts on some systems
        )

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
        print("A Brave browser window has opened.")
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
