# WM 2026 — FIFA World Cup 2026 Result Predictor

A machine-learning pipeline (in R) that predicts the outcome of FIFA World Cup
2026 matches and Monte-Carlo simulates the entire tournament. It learns from
~49,000 historical international matches, rates teams with a dual Elo system
(slow + fast), enriches features with Transfermarkt squad market values and
match-importance context, and trains a regularised gradient-boosted classifier
to estimate **P(home win) / P(draw) / P(away win)** for every fixture. Those
probabilities drive a full bracket simulation (group stage → final) producing
tournament-wide advancement and title odds for all 48 teams.

A **live benchmarking dashboard** (GitHub Actions + Quarto, auto-updated daily)
tracks model accuracy against real WC-2026 results and runs a Quarter-Kelly
financial simulation against **real pre-match market odds** from The Odds API.

---

## Live dashboard

**https://vincent-rgb-cpu.github.io/WM_2026/**

Auto-updated daily at 07:00 UTC throughout the tournament. Three tabs:

| Tab | Contents |
|-----|----------|
| **Predictions** | All upcoming fixtures with team flags, predicted winner, W/D/L probability bars, and most likely exact scoreline |
| **ML Metrics** | Calibration chart, per-match log-loss curve, model vs. baselines, tournament title odds (top 12) |
| **Financial Simulation** | Cumulative bankroll, return-per-bet bar chart, full match log with real Pinnacle odds and Quarter-Kelly stakes |

---

## Results at a glance

Held-out evaluation on international matches from **2021 onwards** (the model
never sees them during training):

| Model                     | Accuracy | Log-loss | Brier |
|---------------------------|:--------:|:--------:|:-----:|
| **xgboost (this model)**  | **0.613**| **0.859**| **0.504** |
| Baseline: class priors    |   0.480  |   1.049  | 0.633 |
| Baseline: majority class  |   0.480  |  17.97   | 1.040 |

~61 % three-way accuracy is realistic for international football (draws are
inherently hard to predict). Live WC-2026 accuracy is shown on the dashboard
and updated with every new result.

### Tournament odds (Monte-Carlo, N = 10,000)

| Team       | Win Cup | Make Final | Make SF | Make R16 |
|------------|:-------:|:----------:|:-------:|:--------:|
| France     | 17.2 %  |   29.0 %   | 45.2 %  |  97.8 %  |
| Spain      | 15.5 %  |   24.3 %   | 39.6 %  |  99.4 %  |
| Argentina  | 14.0 %  |   25.0 %   | 42.9 %  |  98.3 %  |
| England    | 13.6 %  |   22.5 %   | 38.3 %  |  99.1 %  |
| Brazil     |  8.6 %  |   16.2 %   | 28.6 %  |  97.6 %  |
| Portugal   |  6.6 %  |   14.0 %   | 26.1 %  |  98.6 %  |

Full results for all 48 teams are in `output/tournament_probabilities.csv` and
shown in the dashboard. The simulation is internally consistent: per-round
probabilities sum to exactly the number of slots (Win Cup = 100 %, finalists =
200 %, …).

> ⚠️ Elo-driven models concentrate probability on strong teams — top-team title
> odds run slightly higher than the betting market. Treat these as model
> estimates, not forecasts.

---

## How to run

### Prerequisites

- **R ≥ 4.1** with packages installed via `renv` (`make setup`)
- Optional: `ODDS_API_KEY` env variable for real market odds (free tier at
  [the-odds-api.com](https://the-odds-api.com))

### R pipeline (stages 01 – 06)

```bash
make setup     # install R packages via renv (first run only)
make mv        # fetch Transfermarkt squad market values (cached 7 days)
make all       # stages 01–05: data → train → predict → simulate → scorelines
```

Or stage by stage:

```bash
Rscript scripts/01_build_dataset.R       # download + feature engineering
Rscript scripts/02_train_evaluate.R      # time-split evaluation + final model
Rscript scripts/03_predict_tournament.R  # per-fixture W/D/L + group simulation
Rscript scripts/04_simulate.R            # full Monte-Carlo (N = 10,000)
Rscript scripts/05_exact_scores.R        # Poisson xG → exact scorelines
```

### Benchmarking & real odds (stages 01b, 01c, 06)

```bash
# Fetch squad market values (Transfermarkt, 7-day cache)
make mv

# Fetch real pre-match h2h odds from The Odds API (1-day cache)
export ODDS_API_KEY=<your_key>
make odds

# Compute live accuracy metrics + Quarter-Kelly P&L simulation
make benchmark
```

The benchmark compares model predictions against actual WC-2026 results and
simulates betting using real Pinnacle (or best-available) closing odds. A bet
is only placed when:
1. Real market odds are cached for that match, **and**
2. `edge = model_prob − 1/real_odds ≥ 3 %`

### Hyperparameter tuning

```bash
Rscript scripts/07_tune_hyperparameters.R        # 60 random trials (default)
Rscript scripts/07_tune_hyperparameters.R 120    # more trials
```

Runs a random search over `eta`, `max_depth`, `min_child_weight`, `subsample`,
`colsample_bytree`, and `gamma` on the same time-split used for evaluation.
Results are written to `output/tuning_results.csv`. Copy the best row into
`XGB_PARAMS` in `R/config.R` and re-run stage 02.

### Local dashboard preview

```bash
make dashboard   # renders dashboard/index.qmd and opens it in your browser
```

### Fully automated local cron

```bash
# Test the full pipeline manually first
make pipeline

# Then add to crontab (crontab -e):
0 7 * * * cd /absolute/path/to/WM_2026 && bash run_pipeline.sh >> logs/cron.log 2>&1
```

---

## Data sources

| Purpose | Source |
|---------|--------|
| **Training data** | International results 1872–present ([martj42 mirror][hist], ~49k matches) |
| **WC-2026 fixtures & live scores** | `worldcup26.ir/get/games` (JSON API) |
| **Squad market values** | Transfermarkt national team pages (scraped via `scripts/01b_scrape_market_values.R`) |
| **Real pre-match odds** | [The Odds API](https://the-odds-api.com) — `soccer_fifa_world_cup`, `regions=eu`, `markets=h2h` |

Training data and market values are cached locally and git-ignored.
`data/raw/wc2026_fixtures.json` is committed to the repo as a CI fallback
(the fixtures host is geo-blocked from GitHub Actions runners; the committed
file is refreshed on every local run and keeps CI from failing).

[hist]: https://github.com/martj42/international_results

---

## Project structure

```
WM_2026/
├── R/                            # library code (functions only, no side effects)
│   ├── config.R                  # paths, URLs, hyper-parameters, feature list
│   ├── utils.R                   # shared helpers (logging, pipe, etc.)
│   ├── team_mapping.R            # reconcile team names across sources
│   ├── data_reader.R             # WC-2026 fixtures API  → tidy match tibble
│   ├── historical_data.R         # historical results CSV → tidy match tibble
│   ├── features.R                # Elo (slow + fast), rolling-form, importance features
│   ├── model.R                   # xgboost train / predict / persist
│   ├── evaluate.R                # time-split metrics vs. baselines
│   ├── predict.R                 # per-fixture W/D/L predictions + dead-rubber sim
│   ├── monte_carlo.R             # full bracket simulation (groups → final)
│   └── scorelines.R              # Poisson xG model → exact scoreline per fixture
│
├── scripts/                      # pipeline drivers (thin wrappers over library code)
│   ├── 00_setup.R                #   install R dependencies via renv
│   ├── 01_build_dataset.R        #   readers + features  → training_data.rds
│   ├── 01b_scrape_market_values.R#   Transfermarkt squad values → squad_market_values.csv
│   ├── 01c_fetch_real_odds.R     #   The Odds API h2h → real_market_odds.csv
│   ├── 02_train_evaluate.R       #   evaluate + fit final model → result_model.rds
│   ├── 03_predict_tournament.R   #   per-fixture predictions + group sim → output/*.csv
│   ├── 04_simulate.R             #   tournament Monte-Carlo → tournament_probabilities.csv
│   ├── 05_exact_scores.R         #   Poisson scorelines  → scoreline_predictions.csv
│   ├── 06_financial_benchmark.R  #   live metrics + Quarter-Kelly P&L → output/*.csv
│   └── 07_tune_hyperparameters.R #   random search for XGBoost hyperparameters
│
├── dashboard/
│   ├── index.qmd                 # Quarto dashboard (Predictions + ML Metrics + Financial)
│   └── _quarto.yml               # Quarto project config (darkly theme)
│
├── .github/workflows/
│   └── benchmark.yml             # CI: daily pipeline run + dashboard deploy
│
├── data/
│   └── raw/
│       └── wc2026_fixtures.json  # committed as CI fallback (refreshed locally)
├── output/                       # model outputs committed for dashboard (see below)
│   ├── fixture_predictions.csv   #   upcoming fixture W/D/L probabilities
│   ├── scoreline_predictions.csv #   most likely exact scorelines per fixture
│   ├── wc2026_match_log.csv      #   live match results + model predictions + P&L
│   ├── financial_benchmark.csv   #   cumulative bankroll time series
│   ├── evaluation_metrics.csv    #   held-out accuracy / log-loss / Brier
│   └── tournament_probabilities.csv # title & round-advancement odds (all 48 teams)
│
├── run_all.R                     # runs R stages 01 → 06 in sequence
├── run_pipeline.sh               # R pipeline (cron entry point)
└── Makefile                      # all targets — see `make help` or below
```

### Makefile targets

```
make setup          install R packages (renv)
make mv             fetch Transfermarkt market values (7-day cache)
make odds           fetch real h2h odds from The Odds API (1-day cache; needs ODDS_API_KEY)
make data           stage 01: build training dataset
make train          stage 02: evaluate + train final model
make predict        stage 03: fixture predictions + group simulation
make simulate       stage 04: full tournament Monte-Carlo (N = 10,000)
make scorelines     stage 05: Poisson exact scorelines
make benchmark      stage 06: live accuracy metrics + Kelly P&L simulation
make all            stages 01–05 in sequence
make dashboard      render Quarto dashboard locally (opens in browser)
make pipeline       full R pipeline (cron entry point)
make lock           snapshot R packages to renv.lock
make clean          remove all generated artefacts (keeps raw data cache)
```

---

## Modelling details

### Features

All features are computed *before* each match to prevent data leakage:

| Feature | Description |
|---------|-------------|
| `elo_home_pre`, `elo_away_pre` | Pre-match slow Elo ratings (World-Football-Elo style with log-scale goal-difference multiplier and FiveThirtyEight autocorrelation correction) |
| `momentum_home`, `momentum_away` | Fast Elo − Slow Elo: a parallel Elo computed with K×3 (K=60) that reacts to the last ~3 matches, capturing current squad form independent of long-run strength |
| `home_adv` | 1 for the WC-2026 co-hosts (USA, Canada, Mexico) in their home matches, 0 for all other WC fixtures (neutral venues) |
| `form_pts_diff` | Difference in rolling points over each team's last 5 matches |
| `form_gf_diff` | Difference in rolling goals-for over the last 5 matches |
| `form_ga_diff` | Difference in rolling goals-against over the last 5 matches |
| `rest_diff` | Difference in days since each team's last match (NA-imputed with per-team median, fallback 14 days) |
| `log_mv_home`, `log_mv_away` | Log of total squad market value in EUR (Transfermarkt; `NA` handled natively by XGBoost) |
| `match_importance` | Ordinal context: 0 = friendly, 1 = qualifier, 2 = tournament group, 3 = knockout |
| `is_knockout` | Binary: 1 for R32/R16/QF/SF/Final, 0 otherwise — activates in the knockout phase |

### Algorithm

- **XGBoost** multiclass (`multi:softprob`, 3 classes), hyperparameters tuned
  via random search (`scripts/07_tune_hyperparameters.R`):

  ```
  eta=0.04  max_depth=3  min_child_weight=10  gamma=0.30
  subsample=0.85  colsample_bytree=0.85  nrounds=300
  ```

  Heavy regularisation (`gamma`, `min_child_weight`) prevents the fast-Elo
  momentum features from dominating shallow splits.

- **Recency weighting:** `exp(-0.00050 × days_before_ref)` (~3.8-year half-life).
  The reference date is anchored to `WC_START` (2026-06-11) so weights stay
  stable as new WC results accumulate during the tournament.

- **Time-based split:** train on pre-2021, evaluate on 2021-present — no
  random CV, which would leak future information.

- **Host nation advantage:** USA, Canada, and Mexico receive an Elo home
  bonus of +65 rating points (`neutral = FALSE`). All other WC fixtures are
  neutral.

- **Dead-rubber group-stage adjustment:** in the Monte-Carlo simulation, if a
  team already holds 6 points by matchday 3 (guaranteed advancement), their
  match probabilities are shrunk 40 % toward uniform (1/3 each) to proxy
  squad rotation. Requires matchday-ordered processing within each group.

### Elo system

Two Elo series run in parallel from the same 1500 starting point:

| | Slow Elo | Fast Elo |
|---|---|---|
| K-factor | 20 | 60 (3×) |
| Half-life | ~35 matches | ~3 matches |
| Role | Long-run team strength | Recent momentum |
| Feature | `elo_home/away_pre` | feeds `momentum_home/away` |

Both use the same log-scale goal-difference multiplier and FiveThirtyEight
autocorrelation correction: upsets earn more Elo points than dominant wins over
weaker opponents.

### Poisson scoreline model (stage 05)

Translates W/D/L probabilities into exact scorelines:

- Symmetric GLM: `log(E[goals]) = α + β_att·elo_att + β_def·elo_def + β_home·is_home`
- Fitted on matches since 2010 (~15,000 matches, 31,000 scorer-rows) with
  the same recency weighting as the main model
- For each fixture: computes a 6×6 probability matrix (0–5 goals per side),
  selects the most-probable cell **that falls in the same W/D/L region**
  predicted by XGBoost — the two models are complementary

### Squad market values

`scripts/01b_scrape_market_values.R` fetches total squad market values from
Transfermarkt national team pages (HTTP with UA spoofing). Results are cached
for 7 days in `data/raw/squad_market_values.csv`. Market values are
log-transformed before entering the model and are among the top-5 most
important features after Elo ratings. Missing values are left as `NA` —
XGBoost routes them to the default split path.

### Full tournament simulation (stage 04)

- `TOURNAMENT_SIM_N = 10,000` independent bracket runs
- Group stage sampled and vectorised across all N runs simultaneously
- Tie-breaker: Elo proxy (points + Elo fraction), since the W/D/L model has
  no goal difference
- Third-placed qualification follows WC-2026 format (8 best from 12 groups)
  via bipartite matching against the official slot eligibility table
- Bracket routing read from the official fixture API slot labels — no
  hand-coding required
- Knockout draws resolved by redistributing draw probability proportionally
  to each team's win odds

---

## Live benchmarking (stage 06 + dashboard)

`scripts/06_financial_benchmark.R` runs after every pipeline execution to
produce two output files that power the dashboard:

### `output/wc2026_match_log.csv`

One row per finished WC-2026 match, with:
- Model probability vector (`p_home_win`, `p_draw`, `p_away_win`)
- Proper scoring metrics: log-loss, Brier score, correct-prediction flag
- The real bookmaker used (`bookmaker`), decimal odds (`real_odds`), model
  edge (`edge = model_prob − 1/real_odds`)
- Kelly stake and P&L for that match

### `output/financial_benchmark.csv`

Cumulative bankroll time series (starting at 1,000 units), updated after every
bet. Bets are only placed when both a real odds cache entry exists **and**
`edge ≥ 3 %`. Stake = Quarter-Kelly fraction of current bankroll, capped at 10 %.

### Real odds pipeline

```
ODDS_API_KEY env var
        ↓
scripts/01c_fetch_real_odds.R
        ↓ (GET soccer_fifa_world_cup, regions=eu, markets=h2h)
The Odds API → selects Pinnacle odds (or best available bookmaker)
        ↓ (upsert cache — keeps finished-match odds after they leave the live feed)
data/raw/real_market_odds.csv
        ↓
scripts/06_financial_benchmark.R
        ↓ (left-join on home_team + away_team; skip match if no odds)
output/wc2026_match_log.csv
```

**Important timing note:** pre-match odds are only available in the API feed
*before* a match kicks off. The daily cron ensures odds are cached for upcoming
matches; the upsert strategy retains them after the match finishes and
disappears from the live feed.

---

## CI/CD — GitHub Actions

`.github/workflows/benchmark.yml` runs the full pipeline daily at 07:00 UTC
and on every push to `main` that touches R, scripts, or dashboard files.

### Steps

1. Restore renv library (cached between runs)
2. Install system dependencies (`cmake`, `libcurl4-openssl-dev`, etc.)
3. Install dashboard rendering packages (`quarto`, `plotly`, `DT`, …)
4. Try to refresh `data/raw/wc2026_fixtures.json` via curl; fall back to the
   committed version if `worldcup26.ir` is unreachable from the runner
5. Fetch market values if not cached
6. Stages 01 → 05 (build → train → predict → simulate → scorelines)
7. Fetch real odds (requires `ODDS_API_KEY` secret in repo Settings)
8. Stage 06 — financial benchmark
9. Render Quarto dashboard with `quarto render dashboard/index.qmd`
10. Deploy rendered HTML to the `gh-pages` branch via `peaceiris/actions-gh-pages`

### Required repository secret

| Secret | Purpose |
|--------|---------|
| `ODDS_API_KEY` | The Odds API key (free tier: 500 requests/month). Get one at [the-odds-api.com](https://the-odds-api.com). If unset, the odds step exits cleanly and the benchmark runs without bets. |

### GitHub Pages setup

In your repo: **Settings → Pages → Source → `gh-pages` branch, `/ (root)`**.

---

## Limitations & possible next steps

- **No player-level data** — injuries, line-ups, and suspensions are not
  modelled. The fast-Elo momentum partially proxies recent form, but cannot
  capture a star player being absent.
- **No goal difference in the group-stage Monte-Carlo.** The Poisson model
  predicts scorelines (stage 05), but the vectorised group simulator uses
  W/D/L for speed. Integrating Poisson draws would give proper GD tie-breakers.
- **Third-place routing** uses bipartite matching, not FIFA's exact published
  permutation table — a negligible difference in aggregate probabilities.
- **Elo-driven concentration.** Title odds for favourites run above the
  betting market because team strength enters mainly through Elo across seven
  rounds with no upset variance from tactical mismatches.
- **Group matches are re-sampled** even if already played; finished results
  feed Elo ratings but are not pinned in the simulation. Conditioning on known
  results is an easy refinement.
- **Market efficiency gap.** Pinnacle's lines are set by professional quants
  with live squad data. An edge ≥ 3 % against Pinnacle is rare; this pipeline
  is a calibration benchmark rather than a live betting system.

---

*Academic / personal project. Predictions are statistical estimates, not
betting advice.*
