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
from typing import Optional

import pandas as pd
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout

# ── paths ─────────────────────────────────────────────────────────────────────
ROOT         = pathlib.Path(__file__).parent.parent
PREDICTIONS  = ROOT / "output" / "srf_predictions.csv"
SESSION_FILE = pathlib.Path(__file__).parent / "srg_session.json"
SRF_TIPS_URL = "https://wmtippspiel.srf.ch/round"

# ── CSS selectors (confirmed against live page 2026-06-14) ───────────────────
SEL_MATCH_CARD      = "div.scoreBet"
SEL_TEAM_NAME       = "h4.scoreBet__team__name"        # nth(0)=home, nth(1)=away
SEL_SCORE_INP       = "input.scoreBet__pick__number"   # nth(0)=home, nth(1)=away
SEL_BET_STATUS      = ".betStatus__value"              # "Tippen möglich" when open
# Round picker selectors tried in order.
# react-select renders hash-based classes (css-{hash}-control) with no stable
# BEM name, so we match on the "-control" suffix pattern.
# react-select toggles the menu on mousedown, not click, so we dispatch
# mousedown as a fallback when a plain click doesn't open the options list.
SEL_ROUND_DROPDOWN_CANDIDATES = [
    "div[class*='-control']",        # react-select control (hash class pattern)
    "[data-testid='dropdown']",      # dropdown-indicator chevron
]
SEL_ROUND_OPTION    = "div[class*='-option']"          # options rendered after dropdown opens

# ── timing constants ─────────────────────────────────────────────────────────
AUTOSAVE_DEBOUNCE_S  = 0.4      # wait after fill() for React's debounce to fire
PAGE_LOAD_TIMEOUT_MS = 30_000
CARD_WAIT_TIMEOUT_MS = 15_000
DROPDOWN_TIMEOUT_MS  = 10_000
OPTION_WAIT_TIMEOUT_MS = 5_000

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


def select_round(page, round_spec: str) -> None:
    """
    Open the round picker dropdown and click the option matching `round_spec`.

    `round_spec` is matched as a case-insensitive substring, so "2" matches
    "2.Runde", "Spieltag 2", "Round 2", etc.
    """
    print(f"Selecting round: {round_spec!r} ...")

    # Give React time to finish mounting after networkidle.
    page.wait_for_timeout(1500)

    # --- Check current round first -------------------------------------------
    # If the singleValue element shows we're already on the right round, skip.
    # If no round selector exists at all (page in past/future-round state),
    # warn and return — the match scraper will handle 0 open cards gracefully.
    single_val = page.locator("div[class*='-singleValue']")
    if single_val.count() == 0:
        print(f"  WARNING: round selector not found on page — proceeding with current view.")
        return
    current_text = single_val.first.inner_text().strip()
    print(f"  Current round on page: {current_text!r}")
    if round_spec.strip().lower() in current_text.lower():
        print(f"  Already on correct round — no navigation needed.")
        return

    # --- Open the dropdown ---------------------------------------------------
    opened = False

    # Approach 1: focus the hidden input and press ArrowDown (most reliable for
    # react-select — keyboard events always reach the component).
    try:
        inp = page.locator("div[class*='-control'] input").first
        inp.focus(timeout=DROPDOWN_TIMEOUT_MS)
        page.keyboard.press("ArrowDown")
        page.wait_for_selector(SEL_ROUND_OPTION, timeout=OPTION_WAIT_TIMEOUT_MS)
        print("  Dropdown opened via keyboard (ArrowDown)")
        opened = True
    except (PlaywrightTimeout, Exception):
        pass

    # Approach 2: click / mousedown on candidate selectors.
    if not opened:
        for sel in SEL_ROUND_DROPDOWN_CANDIDATES:
            for method in ("click", "mousedown"):
                try:
                    loc = page.locator(sel).first
                    if method == "click":
                        loc.click(timeout=DROPDOWN_TIMEOUT_MS)
                    else:
                        loc.dispatch_event("mousedown")
                    page.wait_for_selector(SEL_ROUND_OPTION, timeout=OPTION_WAIT_TIMEOUT_MS)
                    print(f"  Dropdown opened via {method!r} on {sel!r}")
                    opened = True
                    break
                except (PlaywrightTimeout, Exception):
                    continue
            if opened:
                break

    if not opened:
        shot = pathlib.Path(__file__).parent / "debug_round_dropdown.png"
        page.screenshot(path=str(shot))
        print(f"  Screenshot saved: {shot}")
        raise RoundNotFoundError(
            "Round dropdown did not open after all attempts. "
            f"Screenshot saved to {shot}"
        )

    options = page.locator(SEL_ROUND_OPTION).all()
    if not options:
        raise RoundNotFoundError(
            f"No round options found with selector {SEL_ROUND_OPTION!r}."
        )

    # Print available options so the user always knows what names are on the page.
    available = [o.inner_text().strip() for o in options]
    print(f"  Available rounds: {available}")

    target = round_spec.strip().lower()
    matched = next(
        ((o, t) for o, t in zip(options, available) if target in t.lower()),
        None
    )

    if matched is None:
        raise RoundNotFoundError(
            f"Round {round_spec!r} not found. Available: {available}"
        )

    opt, text = matched
    print(f"  Clicking: {text!r}")
    opt.click()
    # SPA: round change is a React re-render, not a page navigation.
    # Wait for match cards to appear instead of networkidle.
    page.wait_for_selector(SEL_MATCH_CARD, timeout=CARD_WAIT_TIMEOUT_MS)
    print(f"  Round {text!r} loaded.")


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
    if not SESSION_FILE.exists():
        raise SessionExpiredError(
            f"{SESSION_FILE} not found. "
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
        page.goto(SRF_TIPS_URL, wait_until="networkidle", timeout=PAGE_LOAD_TIMEOUT_MS)

        _dismiss_cookie_consent(page)

        if round_spec is not None:
            select_round(page, round_spec)

        try:
            page.wait_for_selector(SEL_MATCH_CARD, timeout=CARD_WAIT_TIMEOUT_MS)
        except PlaywrightTimeout:
            if round_spec is not None:
                # Betting for this round may not be open yet — not a session error.
                print("  No match cards found for this round (betting may not be open yet).")
            else:
                raise SessionExpiredError(
                    "No match cards found — session may have expired. "
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
