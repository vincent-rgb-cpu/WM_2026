#!/usr/bin/env bash
# =============================================================================
# run_pipeline.sh  --  Full R prediction pipeline.
#
# Runs all R stages in order:
#   01 build dataset -> 02 train/evaluate -> 03 predict -> 04 simulate ->
#   05 scorelines -> 06 financial benchmark
#
# Every invocation writes a timestamped log to logs/ for audit.
#
# Usage:
#   bash run_pipeline.sh
#
# Crontab (daily at 07:00):
#   0 7 * * * cd /path/to/WM_2026 && bash run_pipeline.sh >> logs/cron.log 2>&1
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

mkdir -p logs
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="logs/pipeline_${TIMESTAMP}.log"

log() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"
}

log "Pipeline started  (log: $LOGFILE)"
log "Project root: $SCRIPT_DIR"

# ── R pipeline ────────────────────────────────────────────────────────────────
log "--- Running R pipeline (stages 01-06) ---"

if Rscript run_all.R >> "$LOGFILE" 2>&1; then
    log "R pipeline completed successfully."
else
    log "ERROR: R pipeline failed — check $LOGFILE for details."
    exit 1
fi

log "Pipeline finished."

# Keep only the 30 most recent log files.
ls -t logs/pipeline_*.log 2>/dev/null | tail -n +31 | xargs -r rm --
