#!/usr/bin/env python3
"""
setup_login.py  --  One-time interactive session capture for SRF Tippspiel.

Opens YOUR real Brave Browser 2 with your existing profile (so Google and all
other saved logins are already available), navigates to SRF Tippspiel, waits
for you to log in, then saves the authenticated session to srg_session.json.

Usage:
    python3 python_bot/setup_login.py

IMPORTANT: Close Brave Browser 2 before running this script.
Chromium-based browsers lock their profile directory while running, so
Playwright cannot open it if the browser is already open.
"""

import pathlib
import sys
from playwright.sync_api import sync_playwright

# ── configuration ─────────────────────────────────────────────────────────────
SRF_URL      = "https://wmtippspiel.srf.ch/"
SESSION_FILE = pathlib.Path(__file__).parent / "srg_session.json"

# Your real Brave Browser 2 executable.
BRAVE_EXE = "/Applications/Brave Browser 2.app/Contents/MacOS/Brave Browser"

# Your real Brave profile directory. Using this means the browser opens with
# your Google account, bookmarks and saved passwords already present — exactly
# as if you double-clicked the app yourself.
# "Default" is the first (and usually only) profile. If you have multiple
# profiles, check Brave → Settings → Profiles to find the right folder name.
BRAVE_PROFILE_DIR = str(pathlib.Path.home() /
                        "Library/Application Support/BraveSoftware/Brave-Browser")


def main() -> None:
    print("=" * 62)
    print("  SRF Tippspiel — one-time login session capture")
    print("=" * 62)
    print()

    if not pathlib.Path(BRAVE_EXE).exists():
        sys.exit(f"ERROR: Brave not found at:\n  {BRAVE_EXE}\n"
                 "Update BRAVE_EXE at the top of this file.")

    if not pathlib.Path(BRAVE_PROFILE_DIR).exists():
        sys.exit(f"ERROR: Brave profile not found at:\n  {BRAVE_PROFILE_DIR}\n"
                 "Update BRAVE_PROFILE_DIR at the top of this file.")

    print("!! Make sure Brave Browser 2 is fully closed before continuing.")
    print("   (It locks the profile directory while it is running.)")
    print()
    input("Press ENTER when Brave is closed to continue...")
    print()

    with sync_playwright() as p:
        # launch_persistent_context opens Brave with your REAL profile instead
        # of a blank one — your Google session, cookies and passwords are all
        # present, exactly as if you opened Brave yourself.
        print(f"Opening your Brave profile from:\n  {BRAVE_PROFILE_DIR}\n")
        context = p.chromium.launch_persistent_context(
            user_data_dir  = BRAVE_PROFILE_DIR,
            executable_path= BRAVE_EXE,
            headless       = False,
            slow_mo        = 50,
            args           = ["--no-sandbox"],
        )

        page = context.new_page()
        print(f"Navigating to {SRF_URL} ...")
        page.goto(SRF_URL, wait_until="domcontentloaded")

        print()
        print("Brave has opened with your real profile.")
        print()
        print("Steps:")
        print("  1. Accept the cookie banner if it appears.")
        print("  2. Log in to SRF using Google (or however you normally log in).")
        print("  3. Wait until you can see your tips page (fully logged in).")
        print("  4. Return to THIS terminal window and press ENTER.")
        print()
        print("Waiting for you to finish ... ", end="", flush=True)
        input()

        # Save the authenticated session (cookies + localStorage) to a file.
        # submit_tips.py loads this file so it starts pre-authenticated.
        context.storage_state(path=str(SESSION_FILE))

        print()
        print(f"Session saved to:  {SESSION_FILE}")
        print("You can now run:   make submit")
        print("Session is valid until SRF expires it (typically several weeks).")

        context.close()


if __name__ == "__main__":
    main()
