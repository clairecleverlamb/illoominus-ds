#!/usr/bin/env bash
set -e

DATA_LAKE_S3_REGION="${DATA_LAKE_S3_REGION:-us-east-1}"
DATA_LAKE_BASE_URL="${DATA_LAKE_BASE_URL:-s3://illoominus-data-engineering/data-lake}"

sed -e "s|__S3_REGION__|${DATA_LAKE_S3_REGION}|g" \
    -e "s|__BASE_URL__|${DATA_LAKE_BASE_URL}|g" \
    /app/scripts/duckdb/data_lake_bootstrap.sql.template > /tmp/duckdb_init.sql

if [ -f /app/scripts/duckdb/data_lake_schema.sql.template ]; then
  sed -e "s|__S3_REGION__|${DATA_LAKE_S3_REGION}|g" \
      -e "s|__BASE_URL__|${DATA_LAKE_BASE_URL}|g" \
      /app/scripts/duckdb/data_lake_schema.sql.template >> /tmp/duckdb_init.sql
fi

exec duckdb ':memory:?read_only=true' -init /tmp/duckdb_init.sql
