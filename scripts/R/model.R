library(ggplot2)

run_model_for_company <- function(company_id,
                                  company_name,
                                  con,
                                  output_cfg,
                                  write_data_destination,
                                  save_plot_destination) {
  months <- seq.Date(
    from = as.Date(format(Sys.Date(), "%Y-%m-01")),
    by = "month",
    length.out = 6
  )
  forecast <- seq(2.0, 2.5, length.out = 6)
  lower_80 <- pmax(0, forecast - 0.4)
  upper_80 <- forecast + 0.4
  lower_95 <- pmax(0, forecast - 0.7)
  upper_95 <- forecast + 0.7

  forecast_df <- data.frame(
    company_id = company_id,
    legal_name = company_name,
    month = months,
    forecast = forecast,
    lower_80 = lower_80,
    upper_80 = upper_80,
    lower_95 = lower_95,
    upper_95 = upper_95,
    model_used = "placeholder_model",
    stringsAsFactors = FALSE
  )

  output_path <- file.path(as.character(company_id), "model", "forecast.csv")
  write_data_destination(
    data = forecast_df,
    path = output_path,
    output_type = output_cfg$output_type,
    output_dir = output_cfg$output_dir,
    output_dir_latest = output_cfg$output_dir_latest,
    s3_bucket = output_cfg$s3_bucket,
    s3_prefix = output_cfg$s3_prefix,
    s3_prefix_latest = output_cfg$s3_prefix_latest
  )

  plot_df <- data.frame(
    month = months,
    forecast = forecast
  )
  p <- ggplot2::ggplot(plot_df, ggplot2::aes(x = month, y = forecast)) +
    ggplot2::geom_line() +
    ggplot2::geom_point() +
    ggplot2::labs(
      title = paste0("Placeholder Forecast: ", company_name),
      x = "Month",
      y = "Forecast"
    ) +
    ggplot2::theme_minimal()

  plot_path <- file.path(as.character(company_id), "model", "forecast_plot.png")
  save_plot_destination(
    plot = p,
    path = plot_path,
    output_type = output_cfg$output_type,
    output_dir = output_cfg$output_dir,
    output_dir_latest = output_cfg$output_dir_latest,
    s3_bucket = output_cfg$s3_bucket,
    s3_prefix = output_cfg$s3_prefix,
    s3_prefix_latest = output_cfg$s3_prefix_latest
  )

  list(
    company_id = company_id,
    company_name = company_name,
    status = "success",
    note = "Placeholder model completed"
  )
}
