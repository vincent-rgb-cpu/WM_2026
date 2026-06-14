#!/usr/bin/env bash
# =============================================================================
# run_pipeline.sh  --  Full end-to-end pipeline + SRF tip submission.
#
# Runs all R stages in order (data -> train -> predict -> simulate -> scorelines)
# and then submits the predictions to the SRF Tippspiel website.
#
# Intended to be called by cron. Every invocation writes a timestamped log to
# the logs/ directory so you can audit past runs.
#
# Usage:
#   bash run_pipeline.sh           # full run
#   bash run_pipeline.sh --r-only  # run R pipeline only, skip submission
#
# Crontab (every hour at :00):
#   0 * * * * cd /path/to/WM_2026 && bash run_pipeline.sh >> logs/cron.log 2>&1
#   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
#   Replace /path/to/WM_2026 with the output of:  pwd
# =============================================================================

set -euo pipefail   # exit on error, undefined var, or pipe failure

# ── resolve project root ─────────────────────────────────────────────────────
# Always cd to the project root so relative paths in the R scripts work,
# regardless of which directory cron invoked this script from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── logging ──────────────────────────────────────────────────────────────────
mkdir -p logs
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="logs/pipeline_${TIMESTAMP}.log"

log() {
    # Write to both the per-run log and stdout (so cron's redirect captures it).
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"
}

log "Pipeline started  (log: $LOGFILE)"
log "Project root: $SCRIPT_DIR"

# ── argument parsing ─────────────────────────────────────────────────────────
R_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --r-only) R_ONLY=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ── stage 1: R pipeline ──────────────────────────────────────────────────────
log "--- Running R pipeline (all stages 01-05) ---"

# run_all.R sources each script in order via source(), so a single Rscript
# call runs the complete pipeline: build dataset -> train -> predict ->
# simulate tournament -> generate exact scorelines.
if Rscript run_all.R >> "$LOGFILE" 2>&1; then
    log "R pipeline completed successfully."
else
    log "ERROR: R pipeline failed — check $LOGFILE for details."
    exit 1
fi

# ── stage 2: Python submission bot ───────────────────────────────────────────
if [ "$R_ONLY" = true ]; then
    log "Skipping submission (--r-only flag set)."
else
    log "--- Submitting predictions to SRF Tippspiel ---"

    # Verify prerequisites before launching the browser.
    if [ ! -f "output/srf_predictions.csv" ]; then
        log "ERROR: output/srf_predictions.csv not found — R pipeline may have failed."
        exit 1
    fi
    if [ ! -f "python_bot/srg_session.json" ]; then
        log "ERROR: python_bot/srg_session.json not found."
        log "       Run 'python3 python_bot/setup_login.py' once to create it."
        exit 1
    fi

    if python3 python_bot/submit_tips.py >> "$LOGFILE" 2>&1; then
        log "Submission completed successfully."
    else
        log "ERROR: Submission failed — check $LOGFILE for details."
        # Don't exit with error here; the R pipeline succeeded and predictions
        # are saved. The submission can be retried manually.
    fi
fi

log "Pipeline finished."

# ── log rotation ─────────────────────────────────────────────────────────────
# Keep only the 30 most recent log files to avoid filling disk.
ls -t logs/pipeline_*.log 2>/dev/null | tail -n +31 | xargs -r rm --
