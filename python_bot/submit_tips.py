#!/usr/bin/env python3
"""
submit_tips.py  --  Headless SRF Tippspiel submission bot.

Loads output/srf_predictions.csv (produced by Rscript scripts/05_exact_scores.R),
then opens a headless Chromium browser with the pre-authenticated session from
srg_session.json and submits each predicted scoreline to the SRF Tippspiel page.

Intended to be called automatically by run_pipeline.sh / cron.

Usage:
    python3 python_bot/submit_tips.py          # normal run
    python3 python_bot/submit_tips.py --dry-run # inspect only, no submissions

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HOW TO FIND THE REAL CSS SELECTORS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

All selectors below (SEL_*) are PLACEHOLDERS.  Replace them once:

1. Open https://wmtippspiel.srf.ch/ in Chrome while logged in.
2. Press F12 → "Elements" tab.
3. Press Ctrl+Shift+C (Inspector cursor) and click the element you want.
4. In the highlighted HTML, look at the class= or id= attributes.
5. Right-click the highlighted node → "Copy" → "Copy selector" for a full path,
   or write a shorter one yourself (e.g. ".tip-input-home" if the class is unique).

Tips for robust selectors:
• Prefer unique id="#something" over class chains — ids don't change with
  responsive-layout reflows.
• For repeated elements (one per match), pick a selector that works INSIDE a
  card container so you don't accidentally target another match's input.
• If the page is a React/Vue SPA, elements may not exist until after some
  JavaScript renders them — use page.wait_for_selector() rather than
  assuming they're immediately in the DOM.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"""

import argparse
import pathlib
import sys
import pandas as pd
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout

# ── paths ─────────────────────────────────────────────────────────────────────
ROOT         = pathlib.Path(__file__).parent.parent
PREDICTIONS  = ROOT / "output" / "srf_predictions.csv"
SESSION_FILE = pathlib.Path(__file__).parent / "srg_session.json"

# ── page URL ──────────────────────────────────────────────────────────────────
# If the tips input form lives on a different path (e.g. /tipp or /meine-tipps),
# update this URL.  The session will still be valid for any SRF subdomain.
SRF_TIPS_URL = "https://wmtippspiel.srf.ch/"

# ── CSS selectors — REPLACE THESE with values from DevTools ──────────────────
#
# SEL_MATCH_CARD  — the repeating <div> / <article> that wraps ONE match.
#   HOW TO FIND: right-click any match block on the page → Inspect → look for
#   the outermost element that repeats for every match.
#   EXAMPLE real value might be: "article.match-item" or ".game-card"
SEL_MATCH_CARD = ".match-card"

# SEL_TEAM_HOME / SEL_TEAM_AWAY — the text element showing each team's name
#   INSIDE one match card.  The bot uses these to identify which card belongs
#   to which prediction row in the CSV.
#   HOW TO FIND: inside the card element, find the span/div with the team name.
SEL_TEAM_HOME = ".team-name--home"
SEL_TEAM_AWAY = ".team-name--away"

# SEL_INPUT_HOME / SEL_INPUT_AWAY — the <input type="number"> fields where
#   you type the predicted score.
#   HOW TO FIND: click the Inspect cursor on one of the score input boxes.
#   COMMON patterns: input[name="score-home"], .score-input:first-child
SEL_INPUT_HOME = "input.score--home"
SEL_INPUT_AWAY = "input.score--away"

# SEL_SUBMIT_BTN — the button that saves/submits a single match tip.
#   If the page has ONE global "save all" button instead of per-match buttons,
#   set this to None and uncomment the global-submit block at the bottom.
#   HOW TO FIND: look for a <button> element with text "Tipp abgeben",
#   "Speichern", "Submit" or similar inside / near each match card.
SEL_SUBMIT_BTN = "button.submit-tip"

# Set to True if there is a single "save all" button at the page level instead
# of one per match card.  In that case SEL_SUBMIT_BTN is ignored.
GLOBAL_SUBMIT = False
SEL_GLOBAL_SUBMIT = "button#save-all-tips"   # update this selector too

# How many milliseconds to wait after each submission before moving on.
# Increase this if the site is slow or uses animations that block re-renders.
SUBMIT_DELAY_MS = 600


# ── helpers ───────────────────────────────────────────────────────────────────

def load_predictions() -> pd.DataFrame:
    """Load and validate the R-generated predictions CSV."""
    if not PREDICTIONS.exists():
        sys.exit(
            f"ERROR: {PREDICTIONS} not found.\n"
            "Run `Rscript scripts/05_exact_scores.R` first."
        )
    df = pd.read_csv(PREDICTIONS, parse_dates=["Match_Date"])
    required = {"Team_A", "Team_B", "Goals_A", "Goals_B"}
    missing  = required - set(df.columns)
    if missing:
        sys.exit(f"ERROR: srf_predictions.csv is missing columns: {missing}")
    print(f"Loaded {len(df)} predictions from {PREDICTIONS}")
    return df


def is_logged_in(page) -> bool:
    """
    Heuristic check that the session is still authenticated.
    Adapt the selector to a DOM element that only appears when logged in —
    e.g. the user avatar, a "My Tips" link, or a profile menu.

    HOW TO FIND: after logging in, Inspect something that only visible-to-
    logged-in-users (e.g. "#user-avatar", ".logged-in-indicator", ".my-account").
    """
    # PLACEHOLDER — replace with a real selector that only appears when logged in.
    return page.locator(".user-logged-in").count() > 0


def normalise_name(name: str) -> str:
    """
    Light normalisation for team-name matching between the CSV and the webpage.
    Extend this if the SRF page uses abbreviations or alternative spellings.
    """
    return name.strip().lower()


# ── main bot ──────────────────────────────────────────────────────────────────

def submit_tips(df: pd.DataFrame, dry_run: bool = False) -> None:
    if not SESSION_FILE.exists():
        sys.exit(
            f"ERROR: {SESSION_FILE} not found.\n"
            "Run `python3 python_bot/setup_login.py` first."
        )

    mode_label = "[DRY RUN] " if dry_run else ""
    print(f"{mode_label}Launching headless Chromium ...")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)

        # Load the pre-authenticated context saved by setup_login.py.
        context = browser.new_context(
            storage_state=str(SESSION_FILE),
            locale="de-CH",
        )
        page = context.new_page()

        # ── navigate to the tips page ─────────────────────────────────────
        print(f"Navigating to {SRF_TIPS_URL} ...")
        page.goto(SRF_TIPS_URL, wait_until="networkidle", timeout=30_000)

        # ── session-expiry check ──────────────────────────────────────────
        # This is a best-effort heuristic; if the check selector doesn't match
        # a real DOM element it will always return False.  In that case,
        # remove the check or update SEL inside is_logged_in().
        if not is_logged_in(page):
            print(
                "WARNING: Could not confirm logged-in state "
                "(selector inside is_logged_in() may need updating).\n"
                "Proceeding anyway — if submissions fail, re-run setup_login.py."
            )

        # ── wait for match cards to appear ────────────────────────────────
        try:
            page.wait_for_selector(SEL_MATCH_CARD, timeout=15_000)
        except PlaywrightTimeout:
            sys.exit(
                f"ERROR: No elements matched '{SEL_MATCH_CARD}' within 15s.\n"
                "The page may have changed its HTML structure.\n"
                "Open DevTools on the live page and update SEL_MATCH_CARD."
            )

        cards = page.locator(SEL_MATCH_CARD).all()
        print(f"Found {len(cards)} match card(s) on the page.\n")

        # Pre-build a lookup from (normalised_home, normalised_away) -> row.
        lookup = {
            (normalise_name(r["Team_A"]), normalise_name(r["Team_B"])): r
            for _, r in df.iterrows()
        }

        submitted = 0
        skipped   = 0

        for card in cards:
            # ── identify the match ────────────────────────────────────────
            try:
                home_raw = card.locator(SEL_TEAM_HOME).inner_text(timeout=3_000).strip()
                away_raw = card.locator(SEL_TEAM_AWAY).inner_text(timeout=3_000).strip()
            except PlaywrightTimeout:
                print("  SKIP: Could not read team names from a card (selector mismatch?).")
                skipped += 1
                continue

            key = (normalise_name(home_raw), normalise_name(away_raw))
            row = lookup.get(key)

            if row is None:
                print(f"  SKIP: No prediction for {home_raw!r} vs {away_raw!r}.")
                skipped += 1
                continue

            goals_home = int(row["Goals_A"])
            goals_away = int(row["Goals_B"])
            print(
                f"  {mode_label}{home_raw} {goals_home}–{goals_away} {away_raw}"
                f"  (xG {row['xG_A']:.2f}–{row['xG_B']:.2f},  {row['WDL_pred']})"
            )

            if dry_run:
                submitted += 1
                continue

            # ── fill score inputs ─────────────────────────────────────────
            # triple_click selects any pre-existing text before we type,
            # preventing concatenation (e.g. "21" instead of "2").
            try:
                inp_home = card.locator(SEL_INPUT_HOME)
                inp_away = card.locator(SEL_INPUT_AWAY)

                inp_home.triple_click()
                inp_home.type(str(goals_home))
                inp_away.triple_click()
                inp_away.type(str(goals_away))
            except PlaywrightTimeout:
                print(f"    WARNING: Could not fill input fields — selector mismatch?")
                skipped += 1
                continue

            # ── click the per-match submit button (if not using global) ───
            if not GLOBAL_SUBMIT:
                btn = card.locator(SEL_SUBMIT_BTN)
                if btn.count() > 0:
                    btn.click()
                    page.wait_for_timeout(SUBMIT_DELAY_MS)
                else:
                    # No per-card button found; the page may use a global one.
                    # Set GLOBAL_SUBMIT = True above and update SEL_GLOBAL_SUBMIT.
                    print("    NOTE: No per-match submit button found in this card.")

            submitted += 1

        # ── global submit button (if the page saves all tips at once) ─────
        if GLOBAL_SUBMIT and not dry_run and submitted > 0:
            try:
                page.locator(SEL_GLOBAL_SUBMIT).click()
                page.wait_for_timeout(2_000)
                print(f"\nClicked global submit button '{SEL_GLOBAL_SUBMIT}'.")
            except PlaywrightTimeout:
                print(f"\nWARNING: Global submit button '{SEL_GLOBAL_SUBMIT}' not found.")

        print(
            f"\n{mode_label}Done.  "
            f"Submitted: {submitted}  |  Skipped: {skipped}  |  "
            f"Total predictions: {len(df)}"
        )
        browser.close()


# ── entry point ───────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Submit WC-2026 tips to SRF Tippspiel.")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Navigate and match predictions but do NOT fill or submit anything.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args  = parse_args()
    preds = load_predictions()
    submit_tips(preds, dry_run=args.dry_run)
