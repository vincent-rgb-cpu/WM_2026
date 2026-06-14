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
import sys
import time
import pandas as pd
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout

# ── paths ─────────────────────────────────────────────────────────────────────
ROOT         = pathlib.Path(__file__).parent.parent
PREDICTIONS  = ROOT / "output" / "srf_predictions.csv"
SESSION_FILE = pathlib.Path(__file__).parent / "srg_session.json"
SRF_TIPS_URL = "https://wmtippspiel.srf.ch/round"

# ── confirmed CSS selectors (inspected 2026-06-14) ───────────────────────────
SEL_MATCH_CARD      = "div.scoreBet"
SEL_TEAM_NAME       = "h4.scoreBet__team__name"        # nth(0)=home, nth(1)=away
SEL_SCORE_INP       = "input.scoreBet__pick__number"   # nth(0)=home, nth(1)=away
SEL_BET_STATUS      = ".betStatus__value"              # "Tippen möglich" when open
SEL_ROUND_DROPDOWN  = "[data-testid='dropdown']"       # chevron that opens round picker
SEL_ROUND_OPTION    = ".select__option"                # options rendered after click

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
    time.sleep(0.4)   # give the auto-save debounce time to fire


def select_round(page, round_spec: str) -> None:
    """
    Open the round picker dropdown and click the option matching `round_spec`.

    `round_spec` can be:
      - a plain integer string, e.g. "3"  → matches any option whose text contains "3"
      - a label substring, e.g. "Spieltag 3" → matched case-insensitively
    """
    print(f"Selecting round: {round_spec!r} ...")

    try:
        # Click the chevron/dropdown indicator to open the picker
        page.locator(SEL_ROUND_DROPDOWN).first.click(timeout=10_000)
        page.wait_for_selector(SEL_ROUND_OPTION, timeout=5_000)
    except PlaywrightTimeout:
        sys.exit(
            "ERROR: Round dropdown did not open.\n"
            f"  selector tried: {SEL_ROUND_DROPDOWN}\n"
            "  Check that SEL_ROUND_DROPDOWN still matches the page."
        )

    options = page.locator(SEL_ROUND_OPTION).all()
    if not options:
        sys.exit(f"ERROR: No round options found with selector {SEL_ROUND_OPTION!r}.")

    target = round_spec.strip().lower()
    matched = None
    for opt in options:
        text = opt.inner_text().strip()
        if target in text.lower():
            matched = (opt, text)
            break

    if matched is None:
        available = [o.inner_text().strip() for o in options]
        sys.exit(
            f"ERROR: Round {round_spec!r} not found in dropdown.\n"
            f"  Available options: {available}"
        )

    opt, text = matched
    print(f"  Clicking round option: {text!r}")
    opt.click()
    # Wait for the page to reload match cards for the selected round
    page.wait_for_load_state("networkidle", timeout=15_000)
    print(f"  Round {text!r} loaded.")


def load_predictions() -> pd.DataFrame:
    if not PREDICTIONS.exists():
        sys.exit(
            f"ERROR: {PREDICTIONS} not found.\n"
            "Run `Rscript scripts/05_exact_scores.R` first."
        )
    df = pd.read_csv(PREDICTIONS)
    print(f"Loaded {len(df)} predictions from {PREDICTIONS.name}")
    return df


def submit_tips(df: pd.DataFrame, dry_run: bool = False, round_spec: str | None = None) -> None:
    if not SESSION_FILE.exists():
        sys.exit(
            f"ERROR: {SESSION_FILE} not found.\n"
            "Run `python3 python_bot/setup_login.py` first."
        )

    label = "[DRY RUN] " if dry_run else ""

    # Build a lookup: (german_home, german_away) -> prediction row
    lookup = {
        (normalise(to_german(r["Team_A"])), normalise(to_german(r["Team_B"]))): r
        for _, r in df.iterrows()
    }

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(storage_state=str(SESSION_FILE))
        page    = context.new_page()

        print(f"Opening {SRF_TIPS_URL} ...")
        page.goto(SRF_TIPS_URL, wait_until="networkidle", timeout=30_000)

        if round_spec is not None:
            select_round(page, round_spec)

        try:
            page.wait_for_selector(SEL_MATCH_CARD, timeout=15_000)
        except PlaywrightTimeout:
            sys.exit(
                "ERROR: No match cards found — session may have expired.\n"
                "Re-run setup_login.py to refresh srg_session.json."
            )

        cards = page.locator(SEL_MATCH_CARD).all()
        print(f"Found {len(cards)} match card(s) on the page.\n")

        submitted = skipped = closed = 0

        for card in cards:
            # ── skip if betting window is closed for this match ───────────
            status_el = card.locator(SEL_BET_STATUS)
            if status_el.count() > 0:
                status_text = status_el.first.inner_text()
                if "möglich" not in status_text:
                    closed += 1
                    continue   # betting period over for this game

            # ── read team names from the page ─────────────────────────────
            try:
                name_els   = card.locator(SEL_TEAM_NAME).all()
                home_page  = name_els[0].inner_text().strip()
                away_page  = name_els[1].inner_text().strip()
            except (PlaywrightTimeout, IndexError):
                print("  SKIP: could not read team names from a card.")
                skipped += 1
                continue

            # ── look up matching prediction row ───────────────────────────
            key = (normalise(home_page), normalise(away_page))
            row = lookup.get(key)

            if row is None:
                # Team names didn't match — likely a missing German translation.
                # Add the pair to EN_TO_DE at the top of this file to fix it.
                print(f"  SKIP (no match): {home_page!r} vs {away_page!r}")
                print(f"         CSV has: {list(df['Team_A'][:3])} ...")
                skipped += 1
                continue

            goals_home = int(row["Goals_A"])
            goals_away = int(row["Goals_B"])
            print(
                f"  {label}{home_page} {goals_home}–{goals_away} {away_page}"
                f"  (xG {row['xG_A']:.2f}–{row['xG_B']:.2f}, {row['WDL_pred']})"
            )

            if dry_run:
                submitted += 1
                continue

            # ── fill both score inputs ────────────────────────────────────
            try:
                inputs = card.locator(SEL_SCORE_INP).all()
                fill_score(inputs[0], goals_home)
                fill_score(inputs[1], goals_away)
                submitted += 1
            except (PlaywrightTimeout, IndexError) as e:
                print(f"    WARNING: Could not fill inputs — {e}")
                skipped += 1

        print(
            f"\n{label}Done.  "
            f"Submitted: {submitted}  |  "
            f"Betting closed: {closed}  |  "
            f"Skipped: {skipped}"
        )
        browser.close()


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Submit WC-2026 tips to SRF Tippspiel.")
    p.add_argument("--dry-run", action="store_true",
                   help="Navigate and match but do NOT fill or save anything.")
    p.add_argument("--round", metavar="ROUND",
                   help="Round to navigate to before submitting, e.g. '3' or 'Spieltag 3'.")
    return p.parse_args()


if __name__ == "__main__":
    args  = parse_args()
    preds = load_predictions()
    submit_tips(preds, dry_run=args.dry_run, round_spec=args.round)
