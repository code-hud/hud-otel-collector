#!/bin/sh
# Runs setup.sql, and setup-promql.sql too with HUD_TIMESERIES_TABLE=true, with ${HUD_CLICKHOUSE_DATABASE} filled in
# (default hud_otel). Both only create or grant what is missing, so running it again (say, to add PromQL) is safe.
# The ClickHouse image runs it from /docker-entrypoint-initdb.d on first start; by hand:
# SETUP_DIR=. CLICKHOUSE_PASSWORD=... ./setup.sh [clickhouse client args].
set -eu
db=${HUD_CLICKHOUSE_DATABASE:-hud_otel}
case $db in
  '' | [!A-Za-z_]* | *[!A-Za-z0-9_]*) echo "HUD_CLICKHOUSE_DATABASE '$db' is not a plain identifier" >&2; exit 1 ;;
esac
dir=${SETUP_DIR:-/hud}
files=$dir/setup.sql
[ "${HUD_TIMESERIES_TABLE:-false}" != true ] || files="$files $dir/setup-promql.sql"
# shellcheck disable=SC2086 # $files is split on purpose
sed "s/\${HUD_CLICKHOUSE_DATABASE}/$db/g" $files |
  clickhouse client --user "${CLICKHOUSE_USER:-default}" --password "${CLICKHOUSE_PASSWORD:-}" --multiquery "$@"
echo "hud setup done for database $db: $files"
