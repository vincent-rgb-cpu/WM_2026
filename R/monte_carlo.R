# =============================================================================
# monte_carlo.R  --  Full-tournament Monte-Carlo simulation of WC 2026.
#
# Simulates the whole tournament (group stage -> R32 -> R16 -> QF -> SF ->
# Final) N times and aggregates how far each team gets, producing tournament
# advancement probabilities.
#
# Design notes
# ------------
# * Match probabilities are PRE-COMPUTED once for every possible team pairing
#   (48x48 lookup matrices) so the simulation loop only does cheap lookups.
# * The group stage is fully VECTORISED across all N simulations (matrix ops).
# * The knockout stage is a per-simulation loop, because match-ups chain
#   (winner of match X feeds match Y) and the 3rd-place routing varies per run.
# * The bracket structure (who plays whom) is read from the fixtures API
#   labels -- it is the official FIFA 2026 bracket, not hard-coded here.
# * Tie-breaker (no goal difference in a W/D/L model): higher Elo wins. This is
#   encoded as `points + elo_fraction`, a key in [points, points+1), so points
#   dominate and Elo breaks exact ties -- works both within a group and when
#   ranking 3rd-placed teams across groups.
#
# Everything here is a PURE function; file I/O lives in scripts/04_simulate.R.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
})

# Map "A".."L" -> 1..12 for a given sorted vector of group letters.
.group_index <- function(group_letters) {
  setNames(seq_along(group_letters), group_letters)
}

# --- Pairwise match probabilities -------------------------------------------
# For every ordered pair (home, away) of the 48 teams, the model's W/D/L
# probabilities, stored as three [n x n] matrices indexed by team position.
precompute_match_probs <- function(model, teams, ratings, team_form,
                                   fast_ratings = list()) {
  n    <- length(teams)
  grid <- expand.grid(home_team = teams, away_team = teams,
                      stringsAsFactors = FALSE)
  grid <- grid[grid$home_team != grid$away_team, , drop = FALSE]
  grid$match_id <- as.character(seq_len(nrow(grid)))
  grid$date     <- Sys.Date()
  grid$group    <- NA_character_
  grid$stage    <- "ko"
  grid$neutral  <- TRUE   # hypothetical KO matchups have no home venue

  pr  <- predict_fixtures(model, grid, ratings, team_form, fast_ratings)
  idx <- setNames(seq_len(n), teams)

  PH <- PD <- PA <- matrix(0, n, n, dimnames = list(teams, teams))
  cells <- cbind(idx[pr$home_team], idx[pr$away_team])
  PH[cells] <- pr$p_home_win
  PD[cells] <- pr$p_draw
  PA[cells] <- pr$p_away_win

  list(PH = PH, PD = PD, PA = PA, idx = idx, teams = teams)
}

# --- Group structure ---------------------------------------------------------
# Teams and the 6 fixtures of each group, as integer team indices.
build_groups <- function(group_fixtures, idx) {
  groups <- sort(unique(group_fixtures$group))
  team_idx <- lapply(groups, function(g) {
    gt <- group_fixtures %>% filter(group == g)
    sort(unique(unname(idx[c(gt$home_team, gt$away_team)])))
  })
  matches <- lapply(groups, function(g) {
    gt <- group_fixtures %>% filter(group == g)
    data.frame(home_idx = unname(idx[gt$home_team]),
               away_idx = unname(idx[gt$away_team]))
  })
  list(groups = groups, team_idx = team_idx, matches = matches)
}

# --- Bracket structure -------------------------------------------------------
# Parse the knockout fixtures into a compact, integer-coded spec, the per-round
# match ids, and the third-place slot eligibility used for routing.
#
# Slot/source type codes:  1 = group winner, 2 = group runner-up,
#                          3 = a 3rd-placed team, 4 = winner of an earlier match
build_bracket <- function(fixtures, gidx) {
  ko <- fixtures %>%
    filter(stage %in% c("r32", "r16", "qf", "sf", "final")) %>%
    mutate(id = as.integer(match_id)) %>%
    arrange(id)

  parse_label <- function(lbl, this_id) {
    if (grepl("^Winner Group ",    lbl)) return(c(1L, gidx[[sub("^Winner Group ",    "", lbl)]]))
    if (grepl("^Runner-up Group ", lbl)) return(c(2L, gidx[[sub("^Runner-up Group ", "", lbl)]]))
    if (grepl("^3rd Group ",       lbl)) return(c(3L, this_id))
    if (grepl("^Winner Match ",    lbl)) return(c(4L, as.integer(sub("^Winner Match ", "", lbl))))
    c(NA_integer_, NA_integer_)
  }

  spec <- do.call(rbind, lapply(seq_len(nrow(ko)), function(i) {
    h <- parse_label(ko$home_label[i], ko$id[i])
    a <- parse_label(ko$away_label[i], ko$id[i])
    data.frame(id = ko$id[i], stage = ko$stage[i],
               h_type = h[1], h_ref = h[2], a_type = a[1], a_ref = a[2])
  }))

  # Third-place slots: matches with a "3rd Group ..." label (home or away).
  third_rows <- which(grepl("^3rd Group ", ko$home_label) |
                      grepl("^3rd Group ", ko$away_label))
  slot_ids  <- ko$id[third_rows]
  slot_elig <- lapply(third_rows, function(i) {
    lbl <- if (grepl("^3rd Group ", ko$home_label[i])) ko$home_label[i]
           else ko$away_label[i]
    unname(unlist(gidx[strsplit(sub("^3rd Group ", "", lbl), "/")[[1]]]))
  })

  list(
    spec      = spec,
    slot_ids  = slot_ids,
    slot_elig = slot_elig,
    round_ids = list(
      r32   = spec$id[spec$stage == "r32"],
      r16   = spec$id[spec$stage == "r16"],
      qf    = spec$id[spec$stage == "qf"],
      sf    = spec$id[spec$stage == "sf"],
      final = spec$id[spec$stage == "final"]
    )
  )
}

# --- Third-place -> slot assignment (bipartite matching) ---------------------
# Given the 8 group indices whose 3rd-placed team qualified, assign each to a
# distinct eligible slot (Kuhn's augmenting-path algorithm). Returns matchSlot,
# where matchSlot[i] is the group routed to slot i. Falls back to an arbitrary
# assignment in the (FIFA-design-prevented) case of no perfect matching.
match_thirds <- function(qgroups, slot_elig) {
  nslot <- length(slot_elig)
  env <- new.env()
  env$matchSlot <- rep(NA_integer_, nslot)

  augment <- function(g, visited) {
    for (i in seq_len(nslot)) {
      if (!visited[i] && (g %in% slot_elig[[i]])) {
        visited[i] <- TRUE
        cur <- env$matchSlot[i]
        if (is.na(cur) || augment(cur, visited)) {
          env$matchSlot[i] <- g
          return(TRUE)
        }
      }
    }
    FALSE
  }
  for (g in qgroups) augment(g, logical(nslot))

  if (anyNA(env$matchSlot)) {                     # safety net
    leftover <- setdiff(qgroups, env$matchSlot)
    free     <- which(is.na(env$matchSlot))
    for (k in seq_along(free)) {
      if (k <= length(leftover)) env$matchSlot[free[k]] <- leftover[k]
    }
  }
  env$matchSlot
}

# --- Group stage (vectorised across all N simulations) -----------------------
# Returns N x 12 matrices of the winner / runner-up / 3rd-placed team index per
# group, plus the 3rd-placed team's ranking key (for cross-group comparison).
simulate_groups <- function(gstruct, P, elo_frac, N) {
  G <- length(gstruct$groups)
  winnerM <- runnerM <- thirdM <- matrix(0L, N, G)
  thirdKeyM <- matrix(0, N, G)
  rows <- seq_len(N)

  for (gi in seq_len(G)) {
    tt  <- gstruct$team_idx[[gi]]                 # 4 team indices
    nt  <- length(tt)
    col <- setNames(seq_len(nt), as.character(tt))
    pts <- matrix(0L, N, nt)
    mm  <- gstruct$matches[[gi]]

    for (r in seq_len(nrow(mm))) {
      h <- mm$home_idx[r]; a <- mm$away_idx[r]
      ph <- P$PH[h, a]; pd <- P$PD[h, a]
      u  <- runif(N)
      ch <- col[[as.character(h)]]; ca <- col[[as.character(a)]]
      pts[, ch] <- pts[, ch] + ifelse(u < ph, 3L, ifelse(u < ph + pd, 1L, 0L))
      pts[, ca] <- pts[, ca] + ifelse(u < ph, 0L, ifelse(u < ph + pd, 1L, 3L))
    }

    # Ranking key: points + Elo fraction (points dominate, Elo breaks ties).
    sk <- sweep(pts, 2, elo_frac[tt], "+")
    s1 <- max.col(sk, "first"); sk[cbind(rows, s1)] <- -Inf
    s2 <- max.col(sk, "first"); sk[cbind(rows, s2)] <- -Inf
    s3 <- max.col(sk, "first")

    winnerM[, gi]   <- tt[s1]
    runnerM[, gi]   <- tt[s2]
    thirdM[, gi]    <- tt[s3]
    thirdKeyM[, gi] <- pts[cbind(rows, s3)] + elo_frac[tt[s3]]
  }

  list(winnerM = winnerM, runnerM = runnerM,
       thirdM = thirdM, thirdKeyM = thirdKeyM)
}

# --- Full tournament ---------------------------------------------------------
# Orchestrates the whole simulation and returns a tidy probabilities data frame
# with columns: Team, Group_Winner, Make_R32, Make_R16, Make_QF, Make_SF,
# Make_Final, Win_World_Cup (all as percentages, sorted by title odds).
run_tournament_simulation <- function(model, fixtures, ratings, team_form,
                                      fast_ratings = list(),
                                      N = TOURNAMENT_SIM_N, seed = SIM_SEED) {
  set.seed(seed)

  gfx   <- fixtures %>% filter(stage == "group",
                               !is.na(home_team), !is.na(away_team))
  teams <- sort(unique(c(gfx$home_team, gfx$away_team)))
  n     <- length(teams)
  gidx  <- .group_index(sort(unique(gfx$group)))

  log_msg("Pre-computing pairwise match probabilities (", n, " teams) ...")
  P <- precompute_match_probs(model, teams, ratings, team_form, fast_ratings)

  elo_vals <- vapply(teams, function(t) ratings[[t]] %||% ELO_PARAMS$init_rating,
                     numeric(1))
  elo_frac <- (elo_vals - min(elo_vals)) /
              (max(elo_vals) - min(elo_vals) + 1e-9) * 0.999

  gstruct <- build_groups(gfx, P$idx)
  bracket <- build_bracket(fixtures, gidx)
  spec    <- bracket$spec
  nko     <- nrow(spec)
  rid     <- bracket$round_ids

  log_msg("Simulating group stage x ", N, " ...")
  gr <- simulate_groups(gstruct, P, elo_frac, N)

  # Round counters: number of simulations in which a team reaches each round.
  cntGW <- tabulate(as.vector(gr$winnerM), nbins = n)   # won their group
  cnt32 <- cnt16 <- cntQF <- cntSF <- cntF <- cntW <- numeric(n)

  log_msg("Simulating knockout bracket x ", N, " ...")
  Uko     <- matrix(runif(N * nko), N, nko)
  res     <- integer(max(spec$id))
  assignG <- integer(max(spec$id))
  cache   <- new.env(hash = TRUE)

  resolve <- function(type, ref, s) {
    if (type == 1L) gr$winnerM[s, ref]
    else if (type == 2L) gr$runnerM[s, ref]
    else if (type == 3L) gr$thirdM[s, assignG[ref]]
    else res[ref]
  }

  for (s in seq_len(N)) {
    # 8 best 3rd-placed teams, ranked by (points, Elo); routed to slots.
    qg  <- order(gr$thirdKeyM[s, ], decreasing = TRUE)[seq_len(N_THIRDS_ADV)]
    key <- paste0(sort(qg), collapse = ",")
    ms  <- cache[[key]]
    if (is.null(ms)) { ms <- match_thirds(qg, bracket$slot_elig); cache[[key]] <- ms }
    assignG[bracket$slot_ids] <- ms

    # Everyone who reached the Round of 32.
    q32 <- c(gr$winnerM[s, ], gr$runnerM[s, ], gr$thirdM[s, qg])
    cnt32[q32] <- cnt32[q32] + 1

    # Play the bracket in id order (dependencies already satisfied).
    for (k in seq_len(nko)) {
      h <- resolve(spec$h_type[k], spec$h_ref[k], s)
      a <- resolve(spec$a_type[k], spec$a_ref[k], s)
      ph <- P$PH[h, a]; pd <- P$PD[h, a]; pa <- P$PA[h, a]
      # Knockout: redistribute draw probability proportionally to win odds.
      p_home <- ph + pd * ph / (ph + pa)
      res[spec$id[k]] <- if (Uko[s, k] < p_home) h else a
    }

    # Tally how far each team got: winners of round X reached round X+1.
    cnt16[res[rid$r32]]   <- cnt16[res[rid$r32]]   + 1
    cntQF[res[rid$r16]]   <- cntQF[res[rid$r16]]   + 1
    cntSF[res[rid$qf]]    <- cntSF[res[rid$qf]]    + 1
    cntF[res[rid$sf]]     <- cntF[res[rid$sf]]     + 1
    cntW[res[rid$final]]  <- cntW[res[rid$final]]  + 1
  }

  pct <- function(x) round(100 * x / N, 2)
  data.frame(
    Team          = teams,
    Group_Winner  = pct(cntGW),
    Make_R32      = pct(cnt32),
    Make_R16      = pct(cnt16),
    Make_QF       = pct(cntQF),
    Make_SF       = pct(cntSF),
    Make_Final    = pct(cntF),
    Win_World_Cup = pct(cntW),
    stringsAsFactors = FALSE
  ) %>%
    arrange(desc(Win_World_Cup), desc(Make_Final), desc(Make_SF))
}
