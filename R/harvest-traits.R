# September harvest: leaf length, bivalve diversity and Loripes shell length.
# Source from sampling.qmd or run with Rscript R/harvest-traits.R.
if (dir.exists("artifacts/harvest-r-library")) .libPaths(c("artifacts/harvest-r-library", .libPaths()))
suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(readxl)
  library(brms)
})

harvest_workbook <- "Data/Sept_2026/REWRITE_Exp_BB_092026.xlsx"
harvest_output <- "assets/harvest/generated"
harvest_cache <- "artifacts/harvest-models"
dir.create(harvest_output, recursive = TRUE, showWarnings = FALSE)
dir.create(harvest_cache, recursive = TRUE, showWarnings = FALSE)

read_harvest_sheet <- function(sheet) {
  x <- read_xlsx(harvest_workbook, sheet = sheet, na = c("", "NA"))
  stopifnot(all(x$Treatment %in% c("Natural", "Addition")),
            all(x$Area %in% c("Stable", "Unstable")),
            all(grepl("^[1-6][AN][SU]$", x$Station)))
  x |>
    mutate(Core = factor(Station),
           Pair = factor(paste(Area, substr(Station, 1, 1), sep = "_")),
           Treatment = factor(recode(Treatment, Natural = "Control", Addition = "Treatment"),
                              levels = c("Control", "Treatment")),
           Area = factor(Area, levels = c("Stable", "Unstable")))
}

leaf_data <- read_harvest_sheet("leaf_morphometrics") |>
  select(Station, InnerCore, Core, Pair, Treatment, Area, Replicat,
         Value = Leaf_lenght, remark)
loripes_slots <- read_harvest_sheet("Lorpies_length")
stopifnot(is.numeric(loripes_slots$Length))
loripes_data <- loripes_slots |> filter(!is.na(Length)) |> rename(Value = Length)
bivalve_data <- read_harvest_sheet("Bivalves_densities")

# Validate replication and metadata against the biomass core register.
core_register <- read_harvest_sheet("Seagrass_Biomass") |>
  distinct(Station, InnerCore, Treatment, Area, Pair, Core)
stopifnot(nrow(core_register) == 24L, !anyDuplicated(core_register$Station),
          nrow(bivalve_data) == 24L, !anyDuplicated(bivalve_data$Station),
          nrow(leaf_data) == 120L, all(table(leaf_data$Core) == 5L),
          !anyDuplicated(leaf_data[c("Core", "Replicat")]),
          !anyDuplicated(loripes_slots[c("Core", "Replicat")]),
          all(is.finite(leaf_data$Value)), all(leaf_data$Value > 0),
          all(is.finite(loripes_data$Value)), all(loripes_data$Value > 0))
for (x in list(leaf_data, loripes_slots, bivalve_data)) {
  stopifnot(nrow(anti_join(distinct(x, Station, InnerCore, Treatment, Area),
                         core_register, by = c("Station", "InnerCore", "Treatment", "Area"))) == 0L)
}

# Harmonize identification resolution: unresolved juveniles are not a new species.
bivalve_groups <- bivalve_data |>
  transmute(Cerastoderma = C.Edule, Loripes = L.orbiculatus,
            Mya_Scrobicularia = M.arenaria + Mya.Scrobicularia + S.plana,
            Mytilus = Mytilus, Ruditapes_decussatus = R.decussatus,
            Ruditapes_philippinarum = R.philippinarum, Macoma = M.baltica)
stopifnot(!anyNA(bivalve_groups), all(as.matrix(bivalve_groups) >= 0),
          all(as.matrix(bivalve_groups) == round(as.matrix(bivalve_groups))))

diversity_metrics <- function(counts, scope) {
  counts <- as.matrix(counts)
  total <- rowSums(counts)
  stopifnot(all(total > 0))
  proportions <- counts / total
  entropy <- proportions
  entropy[proportions > 0] <- -proportions[proportions > 0] * log(proportions[proportions > 0])
  bind_cols(core_register[match(bivalve_data$Station, core_register$Station), ],
            tibble(Scope = scope, Total = total, Richness = rowSums(counts > 0),
                   Shannon = rowSums(entropy), Groups = ncol(counts)))
}
diversity_data <- bind_rows(
  diversity_metrics(bivalve_groups, "All bivalves"),
  diversity_metrics(select(bivalve_groups, -Loripes), "Without Loripes")
)
stopifnot(all(diversity_data$Shannon >= 0),
          all(diversity_data$Shannon <= log(diversity_data$Richness) + 1e-10))

loripes_coverage <- core_register |>
  left_join(loripes_data |> count(Station, name = "Measured"), by = "Station") |>
  mutate(Measured = replace_na(Measured, 0L)) |>
  left_join(select(bivalve_data, Station, Count = L.orbiculatus), by = "Station")
leaf_core <- leaf_data |>
  group_by(Station, Core, Pair, Treatment, Area) |>
  summarise(Value = mean(Value), N = n(), .groups = "drop")
loripes_core <- loripes_data |>
  group_by(Station, Core, Pair, Treatment, Area, .drop = TRUE) |>
  summarise(Value = mean(Value), N = n(), .groups = "drop")

write.csv(leaf_data, file.path(harvest_output, "leaf-length-observations.csv"), row.names = FALSE)
write.csv(loripes_coverage, file.path(harvest_output, "loripes-measurement-coverage.csv"), row.names = FALSE)
write.csv(diversity_data, file.path(harvest_output, "bivalve-diversity.csv"), row.names = FALSE)

fit_harvest <- function(data, name, kind, intercept) {
  repeated <- kind == "length"
  formula <- if (repeated) {
    bf(Value ~ Treatment * Area + (1 | Pair) + (1 | Core))
  } else if (kind == "richness") {
    bf(as.formula(sprintf("Value | thres(%d) ~ Treatment * Area + (1 | Pair)", unique(data$Groups))))
  } else {
    bf(Value ~ Treatment * Area + (1 | Pair))
  }
  family <- switch(kind, length = lognormal(), richness = cumulative("logit"), shannon = gaussian())
  priors <- c(set_prior("normal(0, 1)", class = "b"),
              set_prior(if (kind == "richness") "normal(0, 2)" else sprintf("normal(%s, 1)", intercept), class = "Intercept"),
              set_prior("exponential(2)", class = "sd"))
  if (kind != "richness") priors <- c(priors, set_prior("exponential(2)", class = "sigma"))
  # Ordinal indices 1,...,G+1 represent richness counts 0,...,G, including unobserved endpoints.
  if (kind == "richness") data$Value <- data$Value + 1L
  brm(formula, data = data, family = family, prior = priors,
      chains = 4, cores = 4, iter = 4000, warmup = 1000, seed = 20260918,
      control = list(adapt_delta = 0.99, max_treedepth = 12),
      file = file.path(harvest_cache, name), file_refit = "on_change", refresh = 1000)
}

# Leaf length keeps the full Treatment x Area design: both meadows are well
# replicated for this endpoint. Loripes shell length is fitted separately
# below, without Area, because the control data cannot support a
# meadow-specific contrast (see rationale there).
harvest_specs <- list(
  leaf = list(data = leaf_data, kind = "length", intercept = log(100), label = "Leaf length (mm)")
)
diversity_models <- character(0)
for (scope in c("All bivalves", "Without Loripes")) {
  suffix <- if (scope == "All bivalves") "all" else "other"
  d <- filter(diversity_data, Scope == scope)
  harvest_specs[[paste0("richness_", suffix)]] <- list(
    data = mutate(d, Value = Richness), kind = "richness", intercept = 0,
    label = paste("Taxon-group richness:", scope))
  harvest_specs[[paste0("shannon_", suffix)]] <- list(
    data = mutate(d, Value = Shannon), kind = "shannon", intercept = 1,
    label = paste("Shannon diversity:", scope))
  diversity_models <- c(diversity_models, paste0("richness_", suffix), paste0("shannon_", suffix))
}

summarize_draws80 <- function(x) {
  interval <- coda::HPDinterval(coda::as.mcmc(x), prob = 0.8)
  tibble(Estimate = median(x), Lower = interval[1, 1], Upper = interval[1, 2],
         Probability_positive = mean(x > 0))
}

harvest_fits <- list()
harvest_estimates <- list()
harvest_effects <- list()
harvest_interactions <- list()
harvest_diagnostics <- list()
harvest_ppc <- list()
for (name in names(harvest_specs)) {
  spec <- harvest_specs[[name]]
  message("Harvest model: ", name)
  fit <- fit_harvest(spec$data, name, spec$kind, spec$intercept)
  harvest_fits[[name]] <- fit
  grid <- expand_grid(Treatment = factor(c("Control", "Treatment"), levels = c("Control", "Treatment")),
                      Area = factor(c("Stable", "Unstable"), levels = c("Stable", "Unstable")))
  if (spec$kind == "richness") grid$Groups <- unique(spec$data$Groups)
  # Response expectations at zero station/core random effects, matching biomass convention.
  expected <- posterior_epred(fit, newdata = grid, re_formula = NA)
  if (spec$kind == "richness") {
    counts <- 0:unique(spec$data$Groups)
    stopifnot(dim(expected)[3] == length(counts))
    expected <- apply(sweep(expected, 3, counts, `*`), c(1, 2), sum)
  }
  harvest_estimates[[name]] <- bind_cols(grid,
    bind_rows(lapply(seq_len(nrow(grid)), function(j) summarize_draws80(expected[, j])))) |>
    mutate(Model = name, Outcome = spec$label)
  harvest_effects[[name]] <- bind_rows(lapply(levels(grid$Area), function(area) {
    delta <- expected[, grid$Treatment == "Treatment" & grid$Area == area] -
      expected[, grid$Treatment == "Control" & grid$Area == area]
    summarize_draws80(delta) |> mutate(Area = area, Model = name, Outcome = spec$label)
  }))
  contrast_stable <- expected[, grid$Treatment == "Treatment" & grid$Area == "Stable"] -
    expected[, grid$Treatment == "Control" & grid$Area == "Stable"]
  contrast_unstable <- expected[, grid$Treatment == "Treatment" & grid$Area == "Unstable"] -
    expected[, grid$Treatment == "Control" & grid$Area == "Unstable"]
  harvest_interactions[[name]] <- summarize_draws80(contrast_unstable - contrast_stable) |>
    mutate(Model = name, Outcome = spec$label)
  parameters <- posterior::summarise_draws(posterior::as_draws_array(fit))
  np <- nuts_params(fit)
  harvest_diagnostics[[name]] <- tibble(
    Model = name, Rhat_max = max(parameters$rhat, na.rm = TRUE),
    ESS_bulk_min = min(parameters$ess_bulk, na.rm = TRUE),
    ESS_tail_min = min(parameters$ess_tail, na.rm = TRUE),
    Divergences = sum(np$Value[np$Parameter == "divergent__"]),
    Treedepth_hits = sum(np$Value[np$Parameter == "treedepth__"] >= 12))
  set.seed(20260918)
  replicated <- posterior_predict(fit, ndraws = 1000)
  if (spec$kind == "richness") replicated <- replicated - 1L
  upper_bound <- if (spec$kind == "shannon") log(unique(spec$data$Groups)) else Inf
  harvest_ppc[[name]] <- tibble(
    Model = name, Statistic = c("Mean", "SD", "Minimum", "Maximum"),
    Observed = c(mean(spec$data$Value), sd(spec$data$Value), min(spec$data$Value), max(spec$data$Value)),
    Lower = c(quantile(rowMeans(replicated), .1), quantile(apply(replicated, 1, sd), .1),
              quantile(apply(replicated, 1, min), .1), quantile(apply(replicated, 1, max), .1)),
    Upper = c(quantile(rowMeans(replicated), .9), quantile(apply(replicated, 1, sd), .9),
              quantile(apply(replicated, 1, min), .9), quantile(apply(replicated, 1, max), .9)),
    Outside_support = mean(replicated < 0 | replicated > upper_bound))
  # Core means are the relevant replication level for length-model checks.
  if (spec$kind == "length") {
    core_indices <- split(seq_len(nrow(spec$data)), spec$data$Core, drop = TRUE)
    replicated_core <- sapply(core_indices, function(i) rowMeans(replicated[, i, drop = FALSE]))
    observed_core <- sapply(core_indices, function(i) mean(spec$data$Value[i]))
    harvest_ppc[[name]] <- bind_rows(harvest_ppc[[name]], tibble(
      Model = name, Statistic = "SD of core means", Observed = sd(observed_core),
      Lower = quantile(apply(replicated_core, 1, sd), .1),
      Upper = quantile(apply(replicated_core, 1, sd), .9), Outside_support = 0))
  }
}

# --- Loripes shell length: area-pooled model -------------------------------
# The shell-length sheet yields only 3 measured control individuals in total,
# from 3 cores, and just 1 of those cores is in the unstable meadow. A
# Treatment x Area interaction (or even meadow-specific main effects) is not
# identifiable from a single unstable-meadow control observation, so a
# meadow-specific contrast for this endpoint would be an artefact of the
# prior rather than the data. We instead fit a single, area-pooled treatment
# contrast and report it as one exploratory number, retaining the same
# lognormal family, random-effect structure and prior style as the other
# length model (leaf).
message("Harvest model: loripes")
loripes_priors <- c(set_prior("normal(0, 1)", class = "b"),
                     set_prior("normal(log(10), 1)", class = "Intercept"),
                     set_prior("exponential(2)", class = "sd"),
                     set_prior("exponential(2)", class = "sigma"))
loripes_fit <- brm(bf(Value ~ Treatment + (1 | Pair) + (1 | Core)),
                    data = loripes_data, family = lognormal(), prior = loripes_priors,
                    chains = 4, cores = 4, iter = 4000, warmup = 1000, seed = 20260918,
                    control = list(adapt_delta = 0.99, max_treedepth = 12),
                    file = file.path(harvest_cache, "loripes"), file_refit = "on_change", refresh = 1000)
harvest_fits[["loripes"]] <- loripes_fit

loripes_grid <- tibble(Treatment = factor(c("Control", "Treatment"), levels = c("Control", "Treatment")),
                       Area = "Pooled")
loripes_expected <- posterior_epred(loripes_fit, newdata = loripes_grid, re_formula = NA)
harvest_estimates[["loripes"]] <- bind_cols(loripes_grid,
  bind_rows(lapply(1:2, function(j) summarize_draws80(loripes_expected[, j])))) |>
  mutate(Model = "loripes", Outcome = "Loripes shell length (mm)")
loripes_delta <- loripes_expected[, 2] - loripes_expected[, 1]
harvest_effects[["loripes"]] <- summarize_draws80(loripes_delta) |>
  mutate(Area = "Pooled", Model = "loripes", Outcome = "Loripes shell length (mm)")

loripes_parameters <- posterior::summarise_draws(posterior::as_draws_array(loripes_fit))
loripes_np <- nuts_params(loripes_fit)
harvest_diagnostics[["loripes"]] <- tibble(
  Model = "loripes", Rhat_max = max(loripes_parameters$rhat, na.rm = TRUE),
  ESS_bulk_min = min(loripes_parameters$ess_bulk, na.rm = TRUE),
  ESS_tail_min = min(loripes_parameters$ess_tail, na.rm = TRUE),
  Divergences = sum(loripes_np$Value[loripes_np$Parameter == "divergent__"]),
  Treedepth_hits = sum(loripes_np$Value[loripes_np$Parameter == "treedepth__"] >= 12))

set.seed(20260918)
loripes_replicated <- posterior_predict(loripes_fit, ndraws = 1000)
harvest_ppc[["loripes"]] <- tibble(
  Model = "loripes", Statistic = c("Mean", "SD", "Minimum", "Maximum"),
  Observed = c(mean(loripes_data$Value), sd(loripes_data$Value), min(loripes_data$Value), max(loripes_data$Value)),
  Lower = c(quantile(rowMeans(loripes_replicated), .1), quantile(apply(loripes_replicated, 1, sd), .1),
            quantile(apply(loripes_replicated, 1, min), .1), quantile(apply(loripes_replicated, 1, max), .1)),
  Upper = c(quantile(rowMeans(loripes_replicated), .9), quantile(apply(loripes_replicated, 1, sd), .9),
            quantile(apply(loripes_replicated, 1, min), .9), quantile(apply(loripes_replicated, 1, max), .9)),
  Outside_support = mean(loripes_replicated < 0))
loripes_core_indices <- split(seq_len(nrow(loripes_data)), loripes_data$Core, drop = TRUE)
loripes_replicated_core <- sapply(loripes_core_indices, function(i) rowMeans(loripes_replicated[, i, drop = FALSE]))
loripes_observed_core <- sapply(loripes_core_indices, function(i) mean(loripes_data$Value[i]))
harvest_ppc[["loripes"]] <- bind_rows(harvest_ppc[["loripes"]], tibble(
  Model = "loripes", Statistic = "SD of core means", Observed = sd(loripes_observed_core),
  Lower = quantile(apply(loripes_replicated_core, 1, sd), .1),
  Upper = quantile(apply(loripes_replicated_core, 1, sd), .9), Outside_support = 0))
# ----------------------------------------------------------------------------

harvest_estimates <- bind_rows(harvest_estimates)
harvest_effects <- bind_rows(harvest_effects)
harvest_interactions <- bind_rows(harvest_interactions)
harvest_diagnostics <- bind_rows(harvest_diagnostics)
harvest_ppc <- bind_rows(harvest_ppc)
write.csv(harvest_estimates, file.path(harvest_output, "posterior-estimates.csv"), row.names = FALSE)
write.csv(harvest_effects, file.path(harvest_output, "treatment-effects.csv"), row.names = FALSE)
write.csv(harvest_interactions, file.path(harvest_output, "between-meadow-effect-differences.csv"), row.names = FALSE)
write.csv(harvest_diagnostics, file.path(harvest_output, "model-diagnostics.csv"), row.names = FALSE)
write.csv(harvest_ppc, file.path(harvest_output, "posterior-predictive-checks.csv"), row.names = FALSE)
writeLines(c(paste("Workbook MD5:", unname(tools::md5sum(harvest_workbook))),
             "Lengths in mm, confirmed by the investigator on 2026-09-18.",
             capture.output(sessionInfo())), file.path(harvest_output, "analysis-session.txt"))
stopifnot(all(harvest_diagnostics$Rhat_max < 1.01),
          all(harvest_diagnostics$ESS_bulk_min > 400),
          all(harvest_diagnostics$ESS_tail_min > 400),
          all(harvest_diagnostics$Divergences == 0),
          all(harvest_diagnostics$Treedepth_hits == 0))

harvest_colours <- c(Control = "#009E73", Treatment = "#CC79A7")
harvest_theme <- theme_classic(base_size = 12) +
  theme(legend.position = "top", strip.background = element_blank(),
        strip.text = element_text(face = "bold"))

plot_harvest_lengths <- function(individuals, cores, ylabel) {
  ggplot(individuals, aes(Treatment, Value)) +
    geom_point(aes(colour = Treatment), alpha = .25, size = 1.5,
               position = position_jitter(width = .1, height = 0, seed = 2026)) +
    geom_line(data = cores, aes(group = Pair), colour = "#777777", alpha = .6) +
    geom_point(data = cores, aes(fill = Treatment), shape = 21, size = 3, colour = "#222222") +
    facet_wrap(~Area) + scale_colour_manual(values = harvest_colours) +
    scale_fill_manual(values = harvest_colours) +
    labs(x = NULL, y = ylabel, colour = "Core", fill = "Core") + harvest_theme
}
plot_harvest_effects <- function(models) {
  d <- filter(harvest_effects, Model %in% models) |>
    mutate(Label = sprintf("P(>0) = %.1f%%", 100 * Probability_positive))
  ggplot(d, aes(Area, Estimate)) +
    geom_hline(yintercept = 0, linetype = 2, colour = "#777777") +
    geom_pointrange(aes(ymin = Lower, ymax = Upper)) +
    geom_text(aes(y = Upper, label = Label), vjust = -.8, size = 3.1) +
    facet_wrap(~Outcome, scales = "free_y", ncol = 2) +
    scale_y_continuous(expand = expansion(mult = c(.1, .25))) +
    labs(x = NULL, y = "Treatment minus control") + harvest_theme
}
# Single compact forest plot of all four diversity contrasts (richness and
# Shannon, with and without Loripes), since none show a resolvable effect:
# one figure conveys the null result more clearly than three large ones.
# Exact P(effect > 0) values are left to the companion table rather than
# on-plot labels, to keep this figure legible.
plot_diversity_effects <- function() {
  d <- filter(harvest_effects, Model %in% diversity_models) |>
    mutate(
      Metric = sub(":.*", "", Outcome),
      Scope = trimws(sub(".*:", "", Outcome)),
      Panel = factor(paste(Metric, Scope, sep = "\n"),
                     levels = c("Taxon-group richness\nAll bivalves", "Taxon-group richness\nWithout Loripes",
                                "Shannon diversity\nAll bivalves", "Shannon diversity\nWithout Loripes"))
    )
  ggplot(d, aes(x = Panel, y = Estimate, colour = Area)) +
    geom_hline(yintercept = 0, linetype = 2, colour = "#777777") +
    geom_pointrange(aes(ymin = Lower, ymax = Upper), position = position_dodge(width = 0.45), fatten = 2.2) +
    scale_colour_manual(values = c(Stable = "#0072B2", Unstable = "#D55E00")) +
    coord_flip() +
    labs(x = NULL, y = "Treatment minus control (posterior median, 80% HPD)", colour = "Meadow") +
    harvest_theme
}
harvest_effect_text <- function(model, area, unit = "") {
  x <- filter(harvest_effects, Model == model, Area == area)
  sprintf("%.2f%s (80%% CrI %.2f to %.2f%s; P(effect > 0) = %.1f%%)",
          x$Estimate, unit, x$Lower, x$Upper, unit, 100 * x$Probability_positive)
}
harvest_effect_table <- function(models) {
  filter(harvest_effects, Model %in% models) |>
    transmute(Outcome, Meadow = Area, `Treatment minus control` = sprintf("%.2f", Estimate),
              `80% CrI` = sprintf("%.2f to %.2f", Lower, Upper),
              `P(effect > 0)` = sprintf("%.1f%%", 100 * Probability_positive)) |>
    knitr::kable(align = c("l", "l", "r", "r", "r"))
}
# Compact stand-in for a convergence-diagnostics table (used for leaf,
# diversity and Loripes models, matching how the biomass model reports
# diagnostics as a single sentence rather than a table).
harvest_diagnostics_text <- function(models) {
  d <- filter(harvest_diagnostics, Model %in% models)
  sprintf(
    "All parameters converged (maximum $\\widehat{R}$ = %.3f, minimum bulk ESS = %s, minimum tail ESS = %s, %s divergent transitions).",
    max(d$Rhat_max), formatC(min(d$ESS_bulk_min), format = "d", big.mark = ","),
    formatC(min(d$ESS_tail_min), format = "d", big.mark = ","),
    if (sum(d$Divergences) == 0) "zero" else as.character(sum(d$Divergences))
  )
}

source("R/harvest-sensitivity.R")
