library(DBI)
library(logger)
library(here)
library(optparse)
library(duckdb)

source(here::here("scripts", "R", "ds_utils.R"))
source(here::here("scripts", "R", "data_lake.R"))
source(here::here("scripts", "R", "model.R"))

init_logger()
setup_aws_credentials_from_ecs()

opts <- parse_cli_args()
output_cfg <- build_output_config(opts)
ensure_output_dirs(output_cfg)

log_info("Starting project: illoominus-ds")
log_info("Output type: {output_cfg$output_type}")

data_lake_con <- NULL
with_logged_step("DuckDB session", {
  data_lake_con <<- open_data_lake_connection()
})
on.exit(close_data_lake_connection(data_lake_con), add = TRUE)

companies <- with_logged_step("Load companies", {
  get_companies(data_lake_con)
})

if (!is.null(opts$`company-id`)) {
  companies <- companies[companies$company_id == as.integer(opts$`company-id`), , drop = FALSE]
  log_info("Applied --company-id filter: {opts$`company-id`} matched={nrow(companies)}")
}

if (!is.null(opts$`company-id-file`)) {
  file_ids <- read_company_ids_from_file(opts$`company-id-file`)
  companies <- companies[companies$company_id %in% file_ids, , drop = FALSE]
  log_info("Applied --company-id-file filter: ids={length(file_ids)} matched={nrow(companies)}")
}

if (!is.null(opts$`company-limit`)) {
  companies <- head(companies, opts$`company-limit`)
  log_info("Applied --company-limit: processing first {nrow(companies)} companies")
}

if (nrow(companies) == 0) {
  log_warn("No companies found in the data lake view")
} else {
  log_info("Found {nrow(companies)} companies")
}

results <- list()
for (i in seq_len(nrow(companies))) {
  company_id <- companies$company_id[i]
  company_name <- companies$legal_name[i]

  log_info("Running model for company_id={company_id} legal_name={company_name}")
  results[[i]] <- run_model_for_company(
    company_id = company_id,
    company_name = company_name,
    con = data_lake_con,
    output_cfg = output_cfg,
    write_data_destination = write_data_destination,
    save_plot_destination = save_plot_destination
  )
}

summary_df <- if (length(results) > 0) {
  do.call(rbind, lapply(results, function(x) {
    data.frame(
      company_id = x$company_id,
      legal_name = x$company_name,
      status = x$status,
      note = x$note,
      stringsAsFactors = FALSE
    )
  }))
} else {
  data.frame(
    company_id = integer(),
    legal_name = character(),
    status = character(),
    note = character(),
    stringsAsFactors = FALSE
  )
}

write_data_destination(
  data = summary_df,
  path = "summary.csv",
  output_type = output_cfg$output_type,
  output_dir = output_cfg$output_dir,
  output_dir_latest = output_cfg$output_dir_latest,
  s3_bucket = output_cfg$s3_bucket,
  s3_prefix = output_cfg$s3_prefix,
  s3_prefix_latest = output_cfg$s3_prefix_latest
)

log_info("Run complete. Timestamp={output_cfg$run_timestamp}")
