# Compatibility for rstan 2.32.x with the Stan 2.32 headers.
# Installs only into the project; no user-library packages are replaced.
local_library <- "artifacts/harvest-r-library"
dir.create(local_library, recursive = TRUE, showWarnings = FALSE)
.libPaths(c(local_library, .libPaths()))
if (packageVersion("rstan") < "2.33.0" && packageVersion("StanHeaders") >= "2.33.0") {
  install.packages(
    "https://cran.r-project.org/src/contrib/Archive/StanHeaders/StanHeaders_2.32.10.tar.gz",
    repos = NULL, type = "source", lib = local_library
  )
}
cat("rstan:", as.character(packageVersion("rstan")),
    "StanHeaders:", as.character(packageVersion("StanHeaders")), "\n")
