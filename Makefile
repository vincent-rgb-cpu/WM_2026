# Makefile -- convenience targets for the WM 2026 pipeline.
#
# R stages:
#   make all        -- run the complete R pipeline (stages 01-05)
#   make data       -- download data + build features
#   make train      -- time-split evaluation + fit final XGBoost model
#   make predict    -- per-fixture W/D/L predictions + group simulation
#   make simulate   -- full-tournament Monte-Carlo (N=10,000)
#   make scorelines -- Poisson xG model -> exact scorelines for SRF
#
# Python automation:
#   make setup-python  -- install playwright + pandas, install Chromium
#   make login         -- interactive one-time session capture
#   make submit        -- headless tip submission (requires srg_session.json)
#   make dry-run       -- inspect without submitting
#
# Full end-to-end:
#   make pipeline   -- R pipeline + Python submission (what cron runs)

RSCRIPT = Rscript
PYTHON  = python3

.PHONY: all setup data train predict simulate simulate-n scorelines \
        setup-python venv login submit dry-run pipeline lock clean mv odds benchmark dashboard

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

# ── Python automation ─────────────────────────────────────────────────────────

setup-python:
	$(PYTHON) -m pip install -r python_bot/requirements.txt
	$(PYTHON) -m playwright install chromium

# Create an isolated venv with pinned versions (recommended over system pip).
venv:
	$(PYTHON) -m venv python_bot/.venv
	python_bot/.venv/bin/pip install --upgrade pip -q
	python_bot/.venv/bin/pip install -r python_bot/requirements.txt
	python_bot/.venv/bin/playwright install chromium
	@echo "Venv ready. Activate with: source python_bot/.venv/bin/activate"

# Pin current R package versions to renv.lock for reproducibility.
lock:
	$(RSCRIPT) -e "if (!requireNamespace('renv', quietly=TRUE)) install.packages('renv'); renv::snapshot(prompt=FALSE)"

# Run once to capture your logged-in SRF session interactively.
login:
	$(PYTHON) python_bot/setup_login.py

# Submit predictions to SRF Tippspiel (requires srg_session.json).
# Optional: make submit ROUND=3
submit:
	$(PYTHON) python_bot/submit_tips.py $(if $(ROUND),--round $(ROUND),)

# Test selector matching without writing anything to the page.
# Optional: make dry-run ROUND=3
dry-run:
	$(PYTHON) python_bot/submit_tips.py --dry-run $(if $(ROUND),--round $(ROUND),)

# ── Full pipeline ─────────────────────────────────────────────────────────────

pipeline:
	bash run_pipeline.sh

# ── Cleanup ───────────────────────────────────────────────────────────────────

# Remove all generated artefacts. Raw data cache is kept (expensive to re-download).
clean:
	rm -f data/processed/*.rds output/*.csv output/models/*.rds logs/pipeline_*.log
