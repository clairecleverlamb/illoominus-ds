library(DBI)
library(readr)
library(here)
library(logger)
library(optparse)
library(aws.s3)
library(httr)
library(duckdb)
library(ggplot2)

init_logger <- function(level = "INFO") {
  level_upper <- toupper(level)
  threshold <- switch(
    level_upper,
    "TRACE" = logger::TRACE,
    "DEBUG" = logger::DEBUG,
    "WARN" = logger::WARN,
    "ERROR" = logger::ERROR,
    "FATAL" = logger::FATAL,
    logger::INFO
  )
  logger::log_threshold(threshold)
}

with_logged_step <- function(step, expr) {
  log_info("Starting: {step}")
  out <- tryCatch(
    eval.parent(substitute(expr)),
    error = function(e) {
      log_error("Failed: {step} - {e$message}")
      stop(e)
    }
  )
  log_info("Completed: {step}")
  out
}

setup_aws_credentials_from_ecs <- function() {
  ecs_credentials_uri <- Sys.getenv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")
  if (nchar(ecs_credentials_uri) == 0) {
    log_info("Not running in ECS metadata mode; using default AWS credential chain")
    return(invisible(NULL))
  }

  metadata_url <- paste0("http://169.254.170.2", ecs_credentials_uri)
  tryCatch({
    creds_response <- httr::GET(metadata_url)
    creds <- httr::content(creds_response, as = "parsed")

    Sys.setenv(
      AWS_ACCESS_KEY_ID = creds$AccessKeyId,
      AWS_SECRET_ACCESS_KEY = creds$SecretAccessKey,
      AWS_SESSION_TOKEN = creds$Token
    )
    log_info("Loaded AWS credentials from ECS metadata endpoint")
  }, error = function(e) {
    log_error("Unable to load ECS credentials: {e$message}")
  })

  invisible(NULL)
}

parse_cli_args <- function() {
  option_list <- list(
    make_option(
      c("-t", "--output-type"),
      type = "character",
      default = "local",
      help = "Output destination type: local or s3 [default: %default]"
    ),
    make_option(
      c("-d", "--output-path"),
      type = "character",
      default = NULL,
      help = "Destination path. Local: directory path. S3: s3://bucket/prefix"
    ),
    make_option(
      c("-o", "--output-dir"),
      type = "character",
      default = NULL,
      help = "(Deprecated: use --output-path) Local output directory path"
    ),
    make_option(
      c("-c", "--company-id"),
      type = "integer",
      default = NULL,
      help = "Optional company_id filter for targeted runs"
    ),
    make_option(
      c("-l", "--company-limit"),
      type = "integer",
      default = NULL,
      help = "Optional cap on number of companies to process"
    ),
    make_option(
      c("-f", "--company-id-file"),
      type = "character",
      default = NULL,
      help = "Optional file containing company IDs (one per line)"
    )
  )

  opt_parser <- OptionParser(option_list = option_list)
  opts <- parse_args(opt_parser)

  if (!opts$`output-type` %in% c("local", "s3")) {
    stop("--output-type must be either 'local' or 's3'")
  }
  if (!is.null(opts$`company-limit`) && opts$`company-limit` <= 0) {
    stop("--company-limit must be > 0")
  }
  if (!is.null(opts$`company-id-file`) && !file.exists(opts$`company-id-file`)) {
    stop("--company-id-file does not exist: ", opts$`company-id-file`)
  }
  opts
}

read_company_ids_from_file <- function(path) {
  lines <- readLines(path, warn = FALSE)
  lines <- trimws(lines)
  lines <- lines[nzchar(lines)]
  ids <- suppressWarnings(as.integer(lines))
  ids <- ids[!is.na(ids)]
  unique(ids)
}

build_output_config <- function(opts) {
  output_type <- opts$`output-type`
  run_timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

  if (output_type == "local") {
    base_output_dir <- if (!is.null(opts$`output-path`)) {
      opts$`output-path`
    } else if (!is.null(opts$`output-dir`)) {
      opts$`output-dir`
    } else {
      here::here("data", "outputs")
    }

    return(list(
      output_type = output_type,
      run_timestamp = run_timestamp,
      output_dir = file.path(base_output_dir, run_timestamp),
      output_dir_latest = file.path(base_output_dir, "latest"),
      s3_bucket = NULL,
      s3_prefix = NULL,
      s3_prefix_latest = NULL
    ))
  }

  if (is.null(opts$`output-path`) || !grepl("^s3://", opts$`output-path`)) {
    stop("--output-path must be an s3:// URI when --output-type=s3")
  }

  clean_uri <- sub("^s3://", "", opts$`output-path`)
  uri_parts <- strsplit(clean_uri, "/", fixed = TRUE)[[1]]
  bucket <- uri_parts[1]
  base_prefix <- if (length(uri_parts) > 1) paste(uri_parts[-1], collapse = "/") else ""
  s3_prefix <- if (nchar(base_prefix) > 0) paste0(base_prefix, "/", run_timestamp) else run_timestamp
  s3_prefix_latest <- if (nchar(base_prefix) > 0) paste0(base_prefix, "/latest") else "latest"

  list(
    output_type = output_type,
    run_timestamp = run_timestamp,
    output_dir = NULL,
    output_dir_latest = NULL,
    s3_bucket = bucket,
    s3_prefix = s3_prefix,
    s3_prefix_latest = s3_prefix_latest
  )
}

ensure_output_dirs <- function(output_cfg) {
  if (output_cfg$output_type != "local") {
    return(invisible(NULL))
  }

  dir.create(output_cfg$output_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(output_cfg$output_dir_latest, recursive = TRUE, showWarnings = FALSE)
  invisible(NULL)
}

open_data_lake_connection <- function() {
  con <- DBI::dbConnect(duckdb::duckdb(), ":memory:", read_only = TRUE)
  init_data_lake_session(con, base_url = get_data_lake_base_url())
  con
}

close_data_lake_connection <- function(con) {
  if (!is.null(con)) {
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
  }
  invisible(NULL)
}

write_data_destination <- function(data,
                                   path,
                                   output_type,
                                   output_dir = NULL,
                                   output_dir_latest = NULL,
                                   s3_bucket = NULL,
                                   s3_prefix = NULL,
                                   s3_prefix_latest = NULL) {
  if (output_type == "local") {
    full_path <- if (!is.null(output_dir)) file.path(output_dir, path) else path
    dir.create(dirname(full_path), recursive = TRUE, showWarnings = FALSE)
    readr::write_csv(data, full_path)

    if (!is.null(output_dir_latest)) {
      latest_path <- file.path(output_dir_latest, path)
      dir.create(dirname(latest_path), recursive = TRUE, showWarnings = FALSE)
      readr::write_csv(data, latest_path)
    }
    return(invisible(NULL))
  }

  if (output_type == "s3") {
    s3_key <- if (!is.null(s3_prefix) && nzchar(s3_prefix)) {
      paste0(s3_prefix, "/", path)
    } else {
      path
    }
    temp_file <- tempfile(fileext = ".csv")
    tryCatch({
      readr::write_csv(data, temp_file)
      aws.s3::put_object(file = temp_file, object = s3_key, bucket = s3_bucket)
      if (!is.null(s3_prefix_latest)) {
        s3_key_latest <- if (nzchar(s3_prefix_latest)) paste0(s3_prefix_latest, "/", path) else path
        aws.s3::put_object(file = temp_file, object = s3_key_latest, bucket = s3_bucket)
      }
    }, error = function(e) {
      stop(paste("Failed to write data to S3:", e$message))
    }, finally = {
      if (file.exists(temp_file)) unlink(temp_file)
    })
    return(invisible(NULL))
  }

  stop("Unsupported output_type: ", output_type)
}

save_plot_destination <- function(plot,
                                  path,
                                  output_type,
                                  output_dir = NULL,
                                  output_dir_latest = NULL,
                                  s3_bucket = NULL,
                                  s3_prefix = NULL,
                                  s3_prefix_latest = NULL,
                                  width = 10,
                                  height = 6,
                                  dpi = 300) {
  if (output_type == "local") {
    full_path <- if (!is.null(output_dir)) file.path(output_dir, path) else path
    dir.create(dirname(full_path), recursive = TRUE, showWarnings = FALSE)
    ggplot2::ggsave(filename = full_path, plot = plot, width = width, height = height, dpi = dpi)

    if (!is.null(output_dir_latest)) {
      latest_path <- file.path(output_dir_latest, path)
      dir.create(dirname(latest_path), recursive = TRUE, showWarnings = FALSE)
      ggplot2::ggsave(filename = latest_path, plot = plot, width = width, height = height, dpi = dpi)
    }
    return(invisible(NULL))
  }

  if (output_type == "s3") {
    s3_key <- if (!is.null(s3_prefix) && nzchar(s3_prefix)) {
      paste0(s3_prefix, "/", path)
    } else {
      path
    }
    temp_file <- tempfile(fileext = ".png")
    tryCatch({
      ggplot2::ggsave(filename = temp_file, plot = plot, width = width, height = height, dpi = dpi)
      aws.s3::put_object(file = temp_file, object = s3_key, bucket = s3_bucket)
      if (!is.null(s3_prefix_latest)) {
        s3_key_latest <- if (nzchar(s3_prefix_latest)) paste0(s3_prefix_latest, "/", path) else path
        aws.s3::put_object(file = temp_file, object = s3_key_latest, bucket = s3_bucket)
      }
    }, error = function(e) {
      stop(paste("Failed to write plot to S3:", e$message))
    }, finally = {
      if (file.exists(temp_file)) unlink(temp_file)
    })
    return(invisible(NULL))
  }

  stop("Unsupported output_type: ", output_type)
}
