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

### Held-out model accuracy

Evaluated on international matches from **2021 onwards** (never seen during training):

| Model                     | Accuracy | Log-loss | Brier |
|---------------------------|:--------:|:--------:|:-----:|
| **xgboost (this model)**  | **0.613**| **0.859**| **0.504** |
| Baseline: class priors    |   0.480  |   1.049  | 0.633 |
| Baseline: majority class  |   0.480  |  17.97   | 1.040 |

~61 % three-way accuracy is realistic for international football (draws are
inherently hard to predict). Live WC-2026 accuracy is updated on the dashboard
after each result.

### WC-2026 live results

**40 matches played** (through 21 Jun 2026) — accuracy **60.0 %**, mean log-loss **0.861**

| Date | Match | Score | Predicted | Correct |
|------|-------|-------|-----------|---------|
| 11 Jun | Mexico vs South Africa | 2-0 | Home win | ✓ |
| 11 Jun | South Korea vs Czech Republic | 2-1 | Home win | ✓ |
| 12 Jun | Canada vs Bosnia and Herzegovina | 1-1 | Home win | ✗ |
| 12 Jun | United States vs Paraguay | 4-1 | Home win | ✓ |
| 13 Jun | Haiti vs Scotland | 0-1 | Away win | ✓ |
| 13 Jun | Australia vs Turkey | 2-0 | Away win | ✗ |
| 13 Jun | Brazil vs Morocco | 1-1 | Home win | ✗ |
| 13 Jun | Qatar vs Switzerland | 1-1 | Away win | ✗ |
| 14 Jun | Germany vs Curaçao | 7-1 | Home win | ✓ |
| 14 Jun | Netherlands vs Japan | 2-2 | Draw | ✓ |
| 14 Jun | Sweden vs Tunisia | 5-1 | Home win | ✓ |
| 14 Jun | Ivory Coast vs Ecuador | 1-0 | Away win | ✗ |
| 15 Jun | Iran vs New Zealand | 2-2 | Home win | ✗ |
| 15 Jun | Spain vs Cape Verde | 0-0 | Home win | ✗ |
| 15 Jun | Belgium vs Egypt | 1-1 | Home win | ✗ |
| 15 Jun | Saudi Arabia vs Uruguay | 1-1 | Away win | ✗ |
| 16 Jun | France vs Senegal | 3-1 | Home win | ✓ |
| 16 Jun | Iraq vs Norway | 1-4 | Away win | ✓ |
| 16 Jun | Argentina vs Algeria | 3-0 | Home win | ✓ |
| 16 Jun | Austria vs Jordan | 3-1 | Home win | ✓ |
| 17 Jun | Portugal vs DR Congo | 1-1 | Home win | ✗ |
| 17 Jun | England vs Croatia | 4-2 | Home win | ✓ |
| 17 Jun | Uzbekistan vs Colombia | 1-3 | Away win | ✓ |
| 17 Jun | Ghana vs Panama | 1-0 | Away win | ✗ |
| 18 Jun | Mexico vs South Korea | 1-0 | Home win | ✓ |
| 18 Jun | Switzerland vs Bosnia and Herzegovina | 4-1 | Home win | ✓ |
| 18 Jun | Canada vs Qatar | 6-0 | Home win | ✓ |
| 18 Jun | Czech Republic vs South Africa | 1-1 | Home win | ✗ |
| 19 Jun | Brazil vs Haiti | 3-0 | Home win | ✓ |
| 19 Jun | Scotland vs Morocco | 0-1 | Away win | ✓ |
| 19 Jun | United States vs Australia | 2-0 | Home win | ✓ |
| 19 Jun | Turkey vs Paraguay | 0-1 | Home win | ✗ |
| 20 Jun | Germany vs Ivory Coast | 2-1 | Home win | ✓ |
| 20 Jun | Ecuador vs Curaçao | 0-0 | Home win | ✗ |
| 20 Jun | Netherlands vs Sweden | 5-1 | Home win | ✓ |
| 20 Jun | Tunisia vs Japan | 0-4 | Away win | ✓ |
| 21 Jun | Belgium vs Iran | 0-0 | Home win | ✗ |
| 21 Jun | New Zealand vs Egypt | 1-3 | Away win | ✓ |
| 21 Jun | Spain vs Saudi Arabia | 4-0 | Home win | ✓ |
| 21 Jun | Uruguay vs Cape Verde | 2-2 | Home win | ✗ |

Draws remain the model's weak spot (10 of 40 games ended in a draw, correctly called only once). The financial simulation has placed 8 Quarter-Kelly bets; bankroll stands at **1,063 units (+6.3 % ROI)**.

### Tournament odds (Monte-Carlo, N = 10,000)

| Team        | Win Cup | Make Final | Make SF | Make QF | Make R16 |
|-------------|:-------:|:----------:|:-------:|:-------:|:--------:|
| Spain       | 18.2 %  |   28.1 %   | 42.9 %  | 55.3 %  |  99.2 %  |
| Argentina   | 16.9 %  |   31.1 %   | 50.3 %  | 66.8 %  |  98.4 %  |
| England     | 11.0 %  |   18.5 %   | 34.1 %  | 56.0 %  |  98.6 %  |
| France      | 10.5 %  |   19.6 %   | 33.7 %  | 50.0 %  |  97.6 %  |
| Portugal    | 10.1 %  |   19.0 %   | 29.9 %  | 52.5 %  |  98.2 %  |
| Brazil      |  8.7 %  |   16.3 %   | 30.2 %  | 48.5 %  |  97.9 %  |
| Germany     |  6.2 %  |   12.7 %   | 25.4 %  | 41.8 %  |  96.9 %  |
| Belgium     |  3.0 %  |    7.6 %   | 17.1 %  | 41.2 %  |  96.5 %  |
| Netherlands |  2.4 %  |    5.9 %   | 14.6 %  | 30.3 %  |  93.6 %  |
| Colombia    |  2.2 %  |    5.9 %   | 13.5 %  | 31.1 %  |  93.9 %  |
| Morocco     |  2.0 %  |    5.0 %   | 12.3 %  | 29.1 %  |  92.4 %  |
| Japan       |  1.5 %  |    4.2 %   | 11.3 %  | 25.7 %  |  93.1 %  |

Full results for all 48 teams are in `output/tournament_probabilities.csv` and
shown in the dashboard.

> ⚠️ Elo-driven models concentrate probability on historically strong teams.
> Treat these as model estimates, not forecasts.

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

# Fetch real pre-match h2h odds from The Odds API (1-day cache; needs ODDS_API_KEY)
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

### Discord / Slack value-bet notifications (stage 08)

```bash
export WEBHOOK_URL=https://discord.com/api/webhooks/...
Rscript scripts/08_send_notification.R
```

Computes today's value bets (edge ≥ 3 %) and fires a POST to a Discord or Slack
incoming webhook. Run automatically at the end of the daily CI pipeline. For
Slack, change the payload key from `content` to `text` in the script.

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
│   ├── team_mapping.R            # reconcile team names across data sources
│   ├── data_reader.R             # WC-2026 fixtures API  → tidy match tibble
│   ├── historical_data.R         # historical results CSV → tidy match tibble
│   ├── features.R                # Elo (slow + fast), rolling form, match importance
│   ├── model.R                   # xgboost train / calibrate / predict / persist
│   ├── evaluate.R                # time-split metrics vs. baselines
│   ├── predict.R                 # per-fixture W/D/L predictions + dead-rubber sim
│   ├── monte_carlo.R             # full bracket simulation (groups → final)
│   └── scorelines.R              # Poisson xG model → exact scoreline per fixture
│
├── scripts/                      # pipeline drivers (thin wrappers over library code)
│   ├── 00_setup.R                #   install R dependencies via renv
│   ├── 01_build_dataset.R        #   readers + features  → training_data.rds
│   ├── 01b_scrape_market_values.R#   Transfermarkt squad values → squad_market_values.csv
│   ├── 01c_fetch_real_odds.R     #   The Odds API h2h → real_market_odds.csv (upsert)
│   ├── 02_train_evaluate.R       #   evaluate + fit final model → result_model.rds
│   ├── 03_predict_tournament.R   #   per-fixture predictions + group sim → output/*.csv
│   ├── 04_simulate.R             #   tournament Monte-Carlo → tournament_probabilities.csv
│   ├── 05_exact_scores.R         #   Poisson scorelines  → scoreline_predictions.csv
│   ├── 06_financial_benchmark.R  #   live metrics + Quarter-Kelly P&L → output/*.csv
│   ├── 07_tune_hyperparameters.R #   random search for XGBoost hyperparameters
│   └── 08_send_notification.R    #   Discord/Slack webhook for today's value bets
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
├── output/                       # model outputs committed for dashboard
│   ├── fixture_predictions.csv   #   upcoming fixture W/D/L probabilities
│   ├── scoreline_predictions.csv #   most likely exact scorelines per fixture
│   ├── wc2026_match_log.csv      #   live match results + model predictions + P&L
│   ├── financial_benchmark.csv   #   cumulative bankroll time series
│   ├── evaluation_metrics.csv    #   held-out accuracy / log-loss / Brier
│   ├── tournament_probabilities.csv # title & round-advancement odds (all 48 teams)
│   └── tuning_results.csv        #   hyperparameter search results (all trials)
│
├── run_all.R                     # runs R stages 01 → 06 in sequence
├── run_pipeline.sh               # full pipeline shell wrapper (cron entry point)
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
make pipeline       full pipeline (cron entry point: stages 01–06 + odds + notify)
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
| `momentum_home`, `momentum_away` | Fast Elo − Slow Elo: a parallel Elo computed with K×3 (K = 60) that reacts to the last ~3 matches, capturing recent form independently of long-run strength |
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
  via random search (`scripts/07_tune_hyperparameters.R`, 60 trials):

  ```
  eta=0.04  max_depth=3  min_child_weight=10  gamma=0.30
  subsample=0.85  colsample_bytree=0.85  nrounds=300
  ```

  Heavy regularisation (`gamma=0.30`, `min_child_weight=10`) prevents the
  fast-Elo momentum features from dominating shallow splits.

- **Probability calibration:** a multinomial logistic regression (Platt scaling)
  is fitted on the XGBoost validation-set outputs and attached to the model
  bundle. Every downstream `predict_proba()` call applies calibration
  automatically, correcting systematic over-confidence before edge calculations.

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

|                | Slow Elo              | Fast Elo              |
|----------------|----------------------|----------------------|
| K-factor       | 20                   | 60 (3×)              |
| Half-life      | ~35 matches          | ~3 matches           |
| Role           | Long-run team strength | Recent momentum     |
| Feature        | `elo_home/away_pre`  | feeds `momentum_home/away` |

Both apply the same log-scale goal-difference multiplier and FiveThirtyEight
autocorrelation correction: upsets earn more Elo points than dominant wins over
weaker opponents.

### Poisson scoreline model (stage 05)

Translates W/D/L probabilities into the most likely exact scoreline:

- Symmetric GLM: `log(E[goals]) = α + β_att·elo_att + β_def·elo_def + β_home·is_home`
- Fitted on matches since 2010 (~15,000 matches, 31,000 scorer-rows) with
  the same recency weighting as the main model
- Dixon-Coles low-score correction applied (ρ = −0.15) to fix the independent
  Poisson model's systematic under-prediction of 0–0 and 1–1 draws
- For each fixture: builds a 6×6 score-probability matrix (0–5 goals per side),
  selects the most-probable cell **that falls in the same W/D/L region**
  predicted by XGBoost — the two models are complementary

### Squad market values

`scripts/01b_scrape_market_values.R` fetches total squad market values from
Transfermarkt national team pages (HTTP with UA spoofing). Results are cached
for 7 days in `data/raw/squad_market_values.csv`. Market values are
log-transformed before entering the model and rank among the top-5 most
important features after Elo ratings. Missing values are left as `NA` —
XGBoost routes them natively to the default split path.

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
*before* a match kicks off. The daily cron at 07:00 UTC caches upcoming-match
odds each morning; the upsert strategy retains them after those matches finish
and disappear from the live feed.

### Value-bet notifications (stage 08)

`scripts/08_send_notification.R` runs at the end of the CI pipeline. It reads
today's fixture predictions, computes `edge = model_prob − 1/market_odds` for
the predicted outcome, and fires a webhook POST to Discord (or Slack) for any
match clearing the 3 % edge threshold. Set `WEBHOOK_URL` as a repository secret.

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
9. Stage 08 — Discord/Slack value-bet notification
10. Render Quarto dashboard with `quarto render dashboard/index.qmd`
11. Deploy rendered HTML to the `gh-pages` branch via `peaceiris/actions-gh-pages`

### Required repository secrets

| Secret | Purpose |
|--------|---------|
| `ODDS_API_KEY` | The Odds API key (free tier: 500 requests/month). Get one at [the-odds-api.com](https://the-odds-api.com). If unset, the odds step exits cleanly and the benchmark runs without bets. |
| `WEBHOOK_URL` | Discord or Slack incoming webhook URL for value-bet alerts. If unset, stage 08 exits cleanly with no notification sent. |

### GitHub Pages setup

In your repo: **Settings → Pages → Source → `gh-pages` branch, `/ (root)`**.

---

## Limitations & possible next steps

- **No player-level data** — injuries, line-ups, and suspensions are not
  modelled. The fast-Elo momentum partially proxies recent form but cannot
  capture a star player being absent.
- **No goal difference in the group-stage Monte-Carlo.** The Poisson model
  predicts scorelines (stage 05), but the vectorised group simulator uses
  W/D/L for speed. Integrating Poisson draws would enable proper GD
  tie-breakers and more realistic advancement probabilities.
- **Group matches are re-sampled** even if already played; finished results
  feed Elo ratings but are not pinned in the simulation. Conditioning on known
  results is a straightforward refinement.
- **Third-place routing** uses bipartite matching, not FIFA's exact published
  permutation table — a negligible difference in aggregate probabilities.
- **Elo-driven concentration.** Title odds for favourites run above the
  betting market because team strength enters mainly through Elo across seven
  rounds with no upset variance from tactical mismatches.
- **Market efficiency gap.** Pinnacle's lines are set by professional quants
  with live squad data. An edge ≥ 3 % against Pinnacle is rare; this pipeline
  is a calibration benchmark rather than a live betting system.

---

*Academic / personal project. Predictions are statistical estimates, not
betting advice.*
