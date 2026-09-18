# Integration checks of exported analytical data against the unchanged workbook.
# Run after R/harvest-traits.R. These checks do not fit any models.
suppressPackageStartupMessages(library(readxl))
p <- "Data/Sept_2026/REWRITE_Exp_BB_092026.xlsx"
out <- "assets/harvest/generated"
b <- read_xlsx(p, sheet = "Bivalves_densities")
l <- read_xlsx(p, sheet = "Lorpies_length", na = c("", "NA"))
leaves <- read_xlsx(p, sheet = "leaf_morphometrics")
div <- read.csv(file.path(out, "bivalve-diversity.csv"))
coverage <- read.csv(file.path(out, "loripes-measurement-coverage.csv"))
leaf_export <- read.csv(file.path(out, "leaf-length-observations.csv"))
stopifnot(nrow(leaf_export) == nrow(leaves),
          identical(leaf_export$Value, leaves$Leaf_lenght),
          !any(grepl("width", names(leaf_export), ignore.case = TRUE)),
          sum(coverage$Measured) == sum(!is.na(l$Length)),
          sum(coverage$Measured == 0) == 9L,
          coverage$Measured[coverage$Station == "2AS"] == 16L,
          coverage$Count[coverage$Station == "2AS"] == 11L)
for (i in seq_len(nrow(b))) {
  counts <- c(b$C.Edule[i], b$L.orbiculatus[i],
              b$M.arenaria[i] + b$Mya.Scrobicularia[i] + b$S.plana[i],
              b$Mytilus[i], b$R.decussatus[i], b$R.philippinarum[i], b$M.baltica[i])
  for (scope in c("All bivalves", "Without Loripes")) {
    x <- if (scope == "All bivalves") counts else counts[-2]
    x <- x[x > 0]
    expected_h <- log(sum(x)) - sum(x * log(x)) / sum(x)
    row <- div[div$Station == b$Station[i] & div$Scope == scope, ]
    stopifnot(nrow(row) == 1L, row$Richness == length(x), row$Total == sum(x),
              abs(row$Shannon - expected_h) < 1e-12)
  }
}
for (scope in unique(div$Scope)) {
  d <- div[div$Scope == scope, ]
  stopifnot(length(unique(d$Pair)) == 12L, all(table(d$Pair) == 2L),
            all(table(d$Treatment, d$Area) == 6L))
}
effects <- read.csv(file.path(out, "treatment-effects.csv"))
diag <- read.csv(file.path(out, "model-diagnostics.csv"))
stopifnot(nrow(effects) == 12L, nrow(diag) == 6L,
          all(is.finite(effects$Estimate)), all(effects$Lower <= effects$Upper),
          all(effects$Probability_positive >= 0 & effects$Probability_positive <= 1),
          all(diag$Rhat_max < 1.01), all(diag$Divergences == 0))
cat("Harvest data, missingness, paired design, diversity calculations and model-output checks passed.\n")
