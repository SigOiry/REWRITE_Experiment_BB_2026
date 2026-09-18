# Targeted robustness checks; all observations remain in the primary analyses.
if (dir.exists("artifacts/harvest-r-library")) .libPaths(c("artifacts/harvest-r-library", .libPaths()))
suppressPackageStartupMessages(library(brms))
sensitivity_results <- list()
for (endpoint in c("leaf", "loripes")) {
  original <- readRDS(file.path("artifacts/harvest-models", paste0(endpoint, ".rds")))
  data <- original$data
  if (endpoint == "leaf") {
    # Remove both cores at the station containing the largest observed leaf.
    largest_pair <- as.character(data$Pair[which.max(data$Value)])
    data <- data[as.character(data$Pair) != largest_pair, ]
    description <- paste("Exclude pair containing the largest leaf:", largest_pair)
    grid <- expand.grid(Area = c("Stable", "Unstable"), Treatment = c("Control", "Treatment"))
  } else {
    data <- data[as.character(data$Core) != "2AS", ]
    description <- "Exclude core 2AS with inconsistent count and length records"
    # The Loripes model is area-pooled (see R/harvest-traits.R), so the
    # sensitivity check is a single pooled contrast, not one per meadow.
    grid <- data.frame(Treatment = c("Control", "Treatment"))
  }
  fit <- update(original, newdata = data, recompile = FALSE,
                file = file.path("artifacts/harvest-models", paste0(endpoint, "_sensitivity")),
                file_refit = "on_change", seed = 20260919, refresh = 1000)
  e <- posterior_epred(fit, newdata = grid, re_formula = NA)
  diagnostics <- posterior::summarise_draws(posterior::as_draws_array(fit))
  np <- nuts_params(fit)
  divergences <- sum(np$Value[np$Parameter == "divergent__"])
  stopifnot(max(diagnostics$rhat, na.rm = TRUE) < 1.01, divergences == 0,
            min(diagnostics$ess_bulk, na.rm = TRUE) > 400,
            min(diagnostics$ess_tail, na.rm = TRUE) > 400)
  if (endpoint == "leaf") {
    for (i in 1:2) {
      delta <- e[, i + 2] - e[, i]
      interval <- coda::HPDinterval(coda::as.mcmc(delta), prob = .8)
      sensitivity_results[[paste(endpoint, i)]] <- data.frame(
        Model = endpoint, Sensitivity = description, Area = grid$Area[i],
        Estimate = median(delta), Lower = interval[1, 1], Upper = interval[1, 2],
        Probability_positive = mean(delta > 0), Rhat_max = max(diagnostics$rhat, na.rm = TRUE),
        ESS_bulk_min = min(diagnostics$ess_bulk, na.rm = TRUE),
        ESS_tail_min = min(diagnostics$ess_tail, na.rm = TRUE), Divergences = divergences)
    }
  } else {
    delta <- e[, 2] - e[, 1]
    interval <- coda::HPDinterval(coda::as.mcmc(delta), prob = .8)
    sensitivity_results[[endpoint]] <- data.frame(
      Model = endpoint, Sensitivity = description, Area = "Pooled",
      Estimate = median(delta), Lower = interval[1, 1], Upper = interval[1, 2],
      Probability_positive = mean(delta > 0), Rhat_max = max(diagnostics$rhat, na.rm = TRUE),
      ESS_bulk_min = min(diagnostics$ess_bulk, na.rm = TRUE),
      ESS_tail_min = min(diagnostics$ess_tail, na.rm = TRUE), Divergences = divergences)
  }
}
harvest_sensitivity <- do.call(rbind, sensitivity_results)
write.csv(harvest_sensitivity, "assets/harvest/generated/sensitivity-effects.csv", row.names = FALSE)
