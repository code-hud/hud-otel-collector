#!/bin/sh
# Runs setup.sql with ${HUD_CLICKHOUSE_DATABASE} filled in (default hud_otel). The ClickHouse image runs it from
# /docker-entrypoint-initdb.d on first start; by hand: CLICKHOUSE_PASSWORD=... ./setup.sh [clickhouse client args].
set -eu
db=${HUD_CLICKHOUSE_DATABASE:-hud_otel}
case $db in
  '' | [!A-Za-z_]* | *[!A-Za-z0-9_]*) echo "HUD_CLICKHOUSE_DATABASE '$db' is not a plain identifier" >&2; exit 1 ;;
esac
sed "s/\${HUD_CLICKHOUSE_DATABASE}/$db/g" "${SETUP_SQL:-/hud/setup.sql}" |
  clickhouse client --user "${CLICKHOUSE_USER:-default}" --password "${CLICKHOUSE_PASSWORD:-}" --multiquery "$@"
echo "hud setup done for database $db"
