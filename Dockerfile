# -----------------------------------------------------------------------------
# Stage 1: base — R + DuckDB R package and extensions only (no CLI, no app)
# -----------------------------------------------------------------------------
FROM rocker/r-ver:4.5.2 AS base

LABEL maintainer="Data Science Team"
LABEL description="illoominus-ds"

RUN apt-get update && apt-get install -y --no-install-recommends \
    xz-utils \
    libcurl4-openssl-dev \
    libssl-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Use Posit Public Package Manager (p3m.dev) for prebuilt binary packages when available.
# P3M serves Linux binaries for the last 5 R versions; rocker/r-ver:4.5.2 is Ubuntu 24.04 (noble).
# Use a date-pinned snapshot for reproducibility; update the date as needed.
# To list valid snapshot dates: docker compose run --rm <project-slug> Rscript -e "pak::ppm_snapshots()"
RUN Rscript -e 'f <- file.path(R.home("etc"), "Rprofile.site"); cat("\noptions(repos = c(P3M = \"https://packagemanager.posit.co/cran/__linux__/noble/2026-03-04\", CRAN = \"https://cran.rstudio.com/\"))\n", file = f, append = TRUE)'

ENV MAKEFLAGS="-j2"

ARG DUCKDB_VERSION=1.4.4
ENV DUCKDB_VERSION=${DUCKDB_VERSION}

# Install duckdb first in an early layer to avoid expensive rebuilds.
RUN R -e "install.packages('pak', Ncpus=2); \
          pak::pkg_install(paste0('duckdb@', Sys.getenv('DUCKDB_VERSION'))); \
          con <- DBI::dbConnect(duckdb::duckdb(), ':memory:'); \
          DBI::dbExecute(con, 'INSTALL httpfs'); \
          DBI::dbExecute(con, 'LOAD httpfs'); \
          DBI::dbExecute(con, 'INSTALL json'); \
          DBI::dbExecute(con, 'LOAD json'); \
          DBI::dbExecute(con, 'INSTALL aws'); \
          DBI::dbExecute(con, 'LOAD aws'); \
          DBI::dbExecute(con, 'INSTALL icu'); \
          DBI::dbExecute(con, 'LOAD icu'); \
          DBI::dbDisconnect(con, shutdown=TRUE)"

WORKDIR /app

# -----------------------------------------------------------------------------
# Stage 2: duckdb-shell — base + CLI + init/entrypoint for interactive S3 shell
# -----------------------------------------------------------------------------
FROM base AS duckdb-shell

ARG DUCKDB_VERSION=1.4.4
ENV DUCKDB_VERSION=${DUCKDB_VERSION}
# TARGETARCH is set by Docker Buildx (e.g. amd64, arm64); default for legacy docker build
ARG TARGETARCH
ARG TARGETOS=linux

RUN ARCH=${TARGETARCH:-amd64} \
    && apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -sSL "https://install.duckdb.org/v${DUCKDB_VERSION}/duckdb_cli-${TARGETOS}-${ARCH}.gz" -o /tmp/duckdb_cli.gz \
    && gunzip -c /tmp/duckdb_cli.gz > /usr/local/bin/duckdb \
    && chmod +x /usr/local/bin/duckdb \
    && rm /tmp/duckdb_cli.gz \
    && apt-get purge -y --auto-remove curl \
    && rm -rf /var/lib/apt/lists/*

RUN echo "INSTALL aws; INSTALL httpfs; INSTALL json; INSTALL icu;" | duckdb

COPY scripts/duckdb/ /app/scripts/duckdb/
RUN chmod +x /app/scripts/duckdb/duckdb_shell_entrypoint.sh

ENTRYPOINT ["/app/scripts/duckdb/duckdb_shell_entrypoint.sh"]

# -----------------------------------------------------------------------------
# Stage 3: app — production image (last = default build target for CI)
# -----------------------------------------------------------------------------
FROM base AS app

RUN R -e "pak::pkg_install(c( \
            'tidyverse@2.0.0', \
            'DBI', \
            'here', \
            'logger', \
            'janitor', \
            'optparse', \
            'aws.s3', \
            'lubridate', \
            'readr', \
            'scales', \
            'httr', \
            'ggplot2', \
            'quarto' \
          ))"

COPY scripts /app/scripts
COPY data /app/data

CMD ["Rscript", "/app/scripts/main.R"]
