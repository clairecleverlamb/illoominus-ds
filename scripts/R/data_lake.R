library(DBI)
library(duckdb)

DATA_LAKE_BASE_URL_DEFAULT <- "s3://illoominus-data-engineering/data-lake"
DATA_LAKE_S3_REGION_DEFAULT <- "us-east-1"

get_data_lake_base_url <- function() {
  env_value <- Sys.getenv("DATA_LAKE_BASE_URL")
  if (nchar(env_value) > 0) env_value else DATA_LAKE_BASE_URL_DEFAULT
}

get_data_lake_s3_region <- function() {
  env_value <- Sys.getenv("DATA_LAKE_S3_REGION")
  if (nchar(env_value) > 0) env_value else DATA_LAKE_S3_REGION_DEFAULT
}

read_and_substitute_sql <- function(path, base_url, s3_region) {
  if (!file.exists(path)) return(character(0L))
  sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
  sql <- gsub("__BASE_URL__", base_url, sql, fixed = TRUE)
  sql <- gsub("__S3_REGION__", s3_region, sql, fixed = TRUE)
  sql
}

init_data_lake_session <- function(con, base_url = get_data_lake_base_url()) {
  s3_region <- get_data_lake_s3_region()
  duckdb_dir <- file.path(here::here(), "scripts", "duckdb")
  bootstrap_path <- file.path(duckdb_dir, "data_lake_bootstrap.sql.template")
  schema_path <- file.path(duckdb_dir, "data_lake_schema.sql.template")

  bootstrap_sql <- read_and_substitute_sql(bootstrap_path, base_url, s3_region)
  if (nchar(bootstrap_sql) > 0) {
    DBI::dbExecute(con, bootstrap_sql)
  }

  schema_sql <- read_and_substitute_sql(schema_path, base_url, s3_region)
  if (nchar(schema_sql) > 0) {
    DBI::dbExecute(con, schema_sql)
  }

  invisible(con)
}

get_companies <- function(con) {
  DBI::dbGetQuery(con, "SELECT company_id, legal_name, created_at, updated_at FROM companies")
}

query <- function(con, sql) {
  DBI::dbGetQuery(con, sql)
}
