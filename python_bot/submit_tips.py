#!/usr/bin/env python3
"""
submit_tips.py  --  Headless SRF Tippspiel submission bot.

Loads output/srf_predictions.csv, opens a headless browser with the saved
session, and fills in every predicted scoreline on wmtippspiel.srf.ch/round.

Scores are auto-saved by the page on every input — there is no submit button.

Usage:
    python3 python_bot/submit_tips.py                   # current round
    python3 python_bot/submit_tips.py --round 3         # select round 3
    python3 python_bot/submit_tips.py --dry-run         # read-only
    python3 python_bot/submit_tips.py --round 3 --dry-run
"""

import argparse
import pathlib
import subprocess
import sys
import time
import urllib.request
import urllib.error
from typing import Optional

import pandas as pd
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout

# ── paths ─────────────────────────────────────────────────────────────────────
ROOT         = pathlib.Path(__file__).parent.parent
PREDICTIONS  = ROOT / "output" / "srf_predictions.csv"
SESSION_FILE = pathlib.Path(__file__).parent / "srg_session.json"
SRF_TIPS_URL = "https://wmtippspiel.srf.ch/round"
BRAVE_EXE    = "/Applications/Brave Browser 2.app/Contents/MacOS/Brave Browser"
CDP_PORT     = 9222

# ── CSS selectors (confirmed against live page 2026-06-14) ───────────────────
SEL_MATCH_CARD      = "div.scoreBet"
SEL_TEAM_NAME       = "h4.scoreBet__team__name"        # nth(0)=home, nth(1)=away
SEL_SCORE_INP       = "input.scoreBet__pick__number"   # nth(0)=home, nth(1)=away
SEL_BET_STATUS = ".betStatus__value"             # "Tippen möglich" when open

# ── timing constants ─────────────────────────────────────────────────────────
AUTOSAVE_DEBOUNCE_S  = 0.4   # wait after fill() for React's debounce to fire
PAGE_LOAD_TIMEOUT_MS = 30_000
CARD_WAIT_TIMEOUT_MS = 15_000

# ── exceptions ───────────────────────────────────────────────────────────────

class BotError(RuntimeError):
    """Raised for any unrecoverable bot error; caught at __main__ to exit cleanly."""

class SessionExpiredError(BotError):
    pass

class ConfigError(BotError):
    pass

class RoundNotFoundError(BotError):
    pass


# ── English → German team name translation ────────────────────────────────────
# SRF shows German names; our CSV uses English. Add any missing team here.
EN_TO_DE: dict[str, str] = {
    # Europe
    "Germany":                  "Deutschland",
    "France":                   "Frankreich",
    "Spain":                    "Spanien",
    "Netherlands":              "Niederlande",
    "Belgium":                  "Belgien",
    "Portugal":                 "Portugal",
    "England":                  "England",
    "Switzerland":              "Schweiz",
    "Austria":                  "Österreich",
    "Sweden":                   "Schweden",
    "Norway":                   "Norwegen",
    "Denmark":                  "Dänemark",
    "Poland":                   "Polen",
    "Croatia":                  "Kroatien",
    "Czech Republic":           "Tschechien",
    "Serbia":                   "Serbien",
    "Hungary":                  "Ungarn",
    "Slovenia":                 "Slowenien",
    "Slovakia":                 "Slowakei",
    "Turkey":                   "Türkei",
    "Scotland":                 "Schottland",
    "Romania":                  "Rumänien",
    "Albania":                  "Albanien",
    "Greece":                   "Griechenland",
    "Bosnia and Herzegovina":   "Bosnien-Herzegowina",
    "Iceland":                  "Island",
    "Ukraine":                  "Ukraine",
    # Africa
    "Morocco":                  "Marokko",
    "Senegal":                  "Senegal",
    "Nigeria":                  "Nigeria",
    "Egypt":                    "Ägypten",
    "Ivory Coast":              "Elfenbeinküste",
    "Cameroon":                 "Kamerun",
    "Tunisia":                  "Tunesien",
    "Algeria":                  "Algerien",
    "DR Congo":                 "DR Kongo",
    "South Africa":             "Südafrika",
    "Ghana":                    "Ghana",
    "Kenya":                    "Kenia",
    "Cape Verde":               "Kap Verde",
    # South America
    "Brazil":                   "Brasilien",
    "Argentina":                "Argentinien",
    "Colombia":                 "Kolumbien",
    "Uruguay":                  "Uruguay",
    "Ecuador":                  "Ecuador",
    "Chile":                    "Chile",
    "Bolivia":                  "Bolivien",
    "Peru":                     "Peru",
    "Paraguay":                 "Paraguay",
    "Venezuela":                "Venezuela",
    # North/Central America & Caribbean
    "United States":            "USA",
    "Mexico":                   "Mexiko",
    "Canada":                   "Kanada",
    "Panama":                   "Panama",
    "Costa Rica":               "Costa Rica",
    "Jamaica":                  "Jamaika",
    "Curaçao":                  "Curaçao",
    "Trinidad and Tobago":      "Trinidad und Tobago",
    # Asia
    "South Korea":              "Südkorea",
    "Japan":                    "Japan",
    "Iran":                     "Iran",
    "Saudi Arabia":             "Saudi-Arabien",
    "Australia":                "Australien",
    "New Zealand":              "Neuseeland",
    "Indonesia":                "Indonesien",
    "Uzbekistan":               "Usbekistan",
    "Jordan":                   "Jordanien",
    "Iraq":                     "Irak",
}


def to_german(english_name: str) -> str:
    """Translate an English team name to German; fall back to the original."""
    return EN_TO_DE.get(english_name.strip(), english_name.strip())


def normalise(name: str) -> str:
    """Lower-case + strip for comparison — avoids case / whitespace mismatches."""
    return name.strip().lower()


def fill_score(locator, value: int) -> None:
    """
    Set a score input to `value` and trigger the page's auto-save.

    The SRF page auto-saves on every keystroke via React's synthetic events.
    fill() in Playwright fires the correct input events that React listens to.
    We also press Tab to trigger any onBlur handler and wait briefly to let
    the debounced save complete.
    """
    locator.fill(str(value))
    locator.press("Tab")
    time.sleep(AUTOSAVE_DEBOUNCE_S)


def _dismiss_cookie_consent(page) -> None:
    """Dismiss the Usercentrics cookie consent modal if it appears."""
    try:
        btn = page.locator("button:has-text('Alle akzeptieren')")
        btn.wait_for(state="visible", timeout=4_000)
        btn.click()
        page.wait_for_timeout(800)
        print("  Cookie consent dismissed.")
    except PlaywrightTimeout:
        pass  # modal not present — nothing to do



def _wait_for_cdp(port: int, timeout: int = 30) -> bool:
    url = f"http://localhost:{port}/json/version"
    for _ in range(timeout * 2):
        try:
            urllib.request.urlopen(url, timeout=1)
            return True
        except (urllib.error.URLError, OSError):
            time.sleep(0.5)
    return False


def _fill_cards(page, lookup: dict, df: "pd.DataFrame",
                dry_run: bool, label: str) -> None:
    """Scrape all match cards on the current page and fill scores."""
    cards = page.locator(SEL_MATCH_CARD).all()
    print(f"Found {len(cards)} match card(s) on the page.\n")

    submitted = skipped = closed = 0

    for card in cards:
        status_el = card.locator(SEL_BET_STATUS)
        if status_el.count() > 0:
            if "möglich" not in status_el.first.inner_text():
                closed += 1
                continue

        try:
            name_els  = card.locator(SEL_TEAM_NAME).all()
            home_page = name_els[0].inner_text().strip()
            away_page = name_els[1].inner_text().strip()
        except (PlaywrightTimeout, IndexError):
            print("  SKIP: could not read team names from a card.")
            skipped += 1
            continue

        key = (normalise(home_page), normalise(away_page))
        row = lookup.get(key)
        if row is None:
            print(f"  SKIP (no match): {home_page!r} vs {away_page!r}")
            skipped += 1
            continue

        goals_home = int(row["Goals_A"])
        goals_away = int(row["Goals_B"])
        print(
            f"  {label}{home_page} {goals_home}–{goals_away} {away_page}"
            f"  (xG {row['xG_A']:.2f}–{row['xG_B']:.2f}, {row['WDL_pred']})"
        )

        if not dry_run:
            try:
                inputs = card.locator(SEL_SCORE_INP).all()
                fill_score(inputs[0], goals_home)
                fill_score(inputs[1], goals_away)
            except (PlaywrightTimeout, IndexError) as e:
                print(f"    WARNING: Could not fill inputs — {e}")
                skipped += 1
                continue

        submitted += 1

    print(
        f"\n{label}Done.  "
        f"Submitted: {submitted}  |  "
        f"Betting closed: {closed}  |  "
        f"Skipped: {skipped}"
    )


def load_predictions() -> pd.DataFrame:
    if not PREDICTIONS.exists():
        raise ConfigError(
            f"{PREDICTIONS} not found. "
            "Run `Rscript scripts/05_exact_scores.R` first."
        )
    df = pd.read_csv(PREDICTIONS)
    print(f"Loaded {len(df)} predictions from {PREDICTIONS.name}")
    return df


def submit_tips(df: pd.DataFrame, dry_run: bool = False,
                round_spec: Optional[str] = None) -> None:
    label  = "[DRY RUN] " if dry_run else ""
    lookup = {
        (normalise(to_german(r["Team_A"])), normalise(to_german(r["Team_B"]))): r
        for _, r in df.iterrows()
    }

    if round_spec is not None:
        # ── Interactive mode ──────────────────────────────────────────────────
        # Launch Brave, let the user navigate to the correct round, then
        # connect via CDP and fill predictions. No headless automation of
        # the round selector — the user does it in a real browser window.
        if not pathlib.Path(BRAVE_EXE).exists():
            raise ConfigError(f"Brave not found at {BRAVE_EXE}")

        print(f"Launching Brave Browser ...")
        subprocess.Popen(
            [BRAVE_EXE, f"--remote-debugging-port={CDP_PORT}", SRF_TIPS_URL],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if not _wait_for_cdp(CDP_PORT):
            raise BotError(f"Brave did not start CDP on port {CDP_PORT} within 30s.")

        print()
        print(f"  Brave is open at {SRF_TIPS_URL}")
        print(f"  → Navigate to round {round_spec!r} in the browser.")
        input("  → Press ENTER when you are on the correct round ... ")
        print()

        with sync_playwright() as p:
            browser = p.chromium.connect_over_cdp(f"http://localhost:{CDP_PORT}")
            page    = browser.contexts[0].pages[0]
            _fill_cards(page, lookup, df, dry_run, label)

    else:
        # ── Headless mode (current round) ─────────────────────────────────────
        if not SESSION_FILE.exists():
            raise SessionExpiredError(
                f"{SESSION_FILE} not found. "
                "Run `python3 python_bot/setup_login.py` first."
            )

        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context(storage_state=str(SESSION_FILE))
            page    = context.new_page()

            print(f"Opening {SRF_TIPS_URL} ...")
            page.goto(SRF_TIPS_URL, wait_until="networkidle",
                      timeout=PAGE_LOAD_TIMEOUT_MS)
            _dismiss_cookie_consent(page)

            try:
                page.wait_for_selector(SEL_MATCH_CARD, timeout=CARD_WAIT_TIMEOUT_MS)
            except PlaywrightTimeout:
                raise SessionExpiredError(
                    "No match cards found — session may have expired. "
                    "Re-run setup_login.py to refresh srg_session.json."
                )

            _fill_cards(page, lookup, df, dry_run, label)
            browser.close()


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Submit WC-2026 tips to SRF Tippspiel.")
    p.add_argument("--dry-run", action="store_true",
                   help="Navigate and match but do NOT fill or save anything.")
    p.add_argument("--round", metavar="ROUND",
                   help="Round to navigate to before submitting, e.g. '3' or 'Spieltag 3'.")
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()
    try:
        preds = load_predictions()
        submit_tips(preds, dry_run=args.dry_run, round_spec=args.round)
    except SessionExpiredError as e:
        print(f"ERROR (session): {e}")
        sys.exit(1)
    except ConfigError as e:
        print(f"ERROR (config): {e}")
        sys.exit(1)
    except RoundNotFoundError as e:
        print(f"ERROR (round): {e}")
        sys.exit(1)
    except BotError as e:
        print(f"ERROR: {e}")
        sys.exit(1)
