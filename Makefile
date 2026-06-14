# Makefile -- convenience targets for the WM 2026 pipeline.
#
# R stages:
#   make all        -- run the complete R pipeline (stages 01-05)
#   make data       -- download data + build features
#   make train      -- time-split evaluation + fit final XGBoost model
#   make predict    -- per-fixture W/D/L predictions + group simulation
#   make simulate   -- full-tournament Monte-Carlo (N=10,000)
#   make scorelines -- Poisson xG model -> exact scoreline predictions
#   make benchmark  -- live metrics + Kelly P&L for completed WC-2026 matches
#   make dashboard  -- render Quarto dashboard locally
#
# Full end-to-end:
#   make pipeline   -- run the complete R pipeline via run_pipeline.sh

RSCRIPT = Rscript

.PHONY: all setup data train predict simulate simulate-n scorelines \
        pipeline lock clean mv odds benchmark dashboard

# ── R pipeline ───────────────────────────────────────────────────────────────

all: data train predict simulate scorelines

setup:
	$(RSCRIPT) scripts/00_setup.R

# Fetch squad market values from Transfermarkt (cached 7 days; run before `data`).
mv:
	$(RSCRIPT) scripts/01b_scrape_market_values.R

# Fetch real pre-match h2h odds from The Odds API (cached 1 day; requires ODDS_API_KEY).
# Run before `benchmark` to enable real-odds Kelly simulation.
#   export ODDS_API_KEY=<your_key> && make odds
odds:
	$(RSCRIPT) scripts/01c_fetch_real_odds.R

data:
	$(RSCRIPT) scripts/01_build_dataset.R

train:
	$(RSCRIPT) scripts/02_train_evaluate.R

predict:
	$(RSCRIPT) scripts/03_predict_tournament.R

simulate:
	$(RSCRIPT) scripts/04_simulate.R

# Override number of simulations:  make simulate-n N=2000
simulate-n:
	$(RSCRIPT) scripts/04_simulate.R $(N)

scorelines:
	$(RSCRIPT) scripts/05_exact_scores.R

# Live benchmarking: metrics + simulated P&L for completed WC-2026 matches.
benchmark:
	$(RSCRIPT) scripts/06_financial_benchmark.R

# Render Quarto dashboard locally (opens in browser).
dashboard:
	quarto render dashboard/index.qmd --output-dir docs && open docs/index.html

# Pin current R package versions to renv.lock for reproducibility.
lock:
	$(RSCRIPT) -e "if (!requireNamespace('renv', quietly=TRUE)) install.packages('renv'); renv::snapshot(prompt=FALSE)"

# ── Full pipeline ─────────────────────────────────────────────────────────────

pipeline:
	bash run_pipeline.sh

# ── Cleanup ───────────────────────────────────────────────────────────────────

# Remove all generated artefacts. Raw data cache is kept (expensive to re-download).
clean:
	rm -f data/processed/*.rds output/*.csv output/models/*.rds logs/pipeline_*.log
