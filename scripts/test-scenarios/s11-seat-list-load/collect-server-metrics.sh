#!/usr/bin/env bash
# 부하 한 단계가 걸린 구간(start~end)의 서버 지표를 Prometheus에서 뽑아 JSON으로 저장합니다.
# k6는 클라이언트가 본 응답시간만 알려주므로, 지연이 어디서 생겼는지(DB 커넥션 대기 / 쿼리 /
# Redis / 스레드 풀 / CPU / GC)는 이 값들로 교차검증합니다.
#
# 사용법:
#   ./collect-server-metrics.sh <start_epoch> <end_epoch> <out.json>
#
# 전제: docker-compose.test.yml을 함께 적용해 띄운 상태 (Histogram·Tomcat 스레드 지표가 켜져 있어야 함)

set -euo pipefail

START="$1"
END="$2"
OUT="$3"
PROM_URL="${PROM_URL:-http://localhost:9090}"
W="$((END - START))s"

JOB='job="'"${PROM_JOB:-ticketing-service}"'"'
SEAT_HTTP="${JOB}"',uri="/api/v1/schedules/{eventSessionId}/seats"'
SEAT_QUERY="${JOB}"',repository="ScheduleSeatJpaRepository",method="findSeatSummaries"'
HGETALL="${JOB}"',command="HGETALL"'
CACHE="${JOB}"',cache="seatList"'

ROWS="$(mktemp)"
trap 'rm -f "$ROWS"' EXIT

# 쿼리 결과 한 값을 "키<TAB>값"으로 쌓습니다. 값이 없으면(지표 미노출, 0으로 나눔 등) null.
metric() { # $1=점으로 구분한 키 $2=PromQL
  local value
  value="$(curl -sf --get "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=$2" --data-urlencode "time=${END}" \
    | jq -r '.data.result[0].value[1] // "null"')"
  printf '%s\t%s\n' "$1" "$value" >> "$ROWS"
}

quantile_ms() { # $1=키 $2=분위수 $3=bucket 지표 $4=라벨 셀렉터
  metric "$1" "1000 * histogram_quantile($2, sum by (le) (rate($3{$4}[${W}])))"
}

avg_ms() { # $1=키 $2=지표 접두어(_sum/_count 앞까지) $3=라벨 셀렉터
  metric "$1" "1000 * sum(rate($2_sum{$3}[${W}])) / sum(rate($2_count{$3}[${W}]))"
}

metric      http.rps        "sum(rate(http_server_requests_seconds_count{${SEAT_HTTP}}[${W}]))"
quantile_ms http.p50_ms 0.50 http_server_requests_seconds_bucket "${SEAT_HTTP}"
quantile_ms http.p95_ms 0.95 http_server_requests_seconds_bucket "${SEAT_HTTP}"
quantile_ms http.p99_ms 0.99 http_server_requests_seconds_bucket "${SEAT_HTTP}"
metric      http.status_5xx "sum(increase(http_server_requests_seconds_count{${SEAT_HTTP},status=~'5..'}[${W}])) or vector(0)"

metric tomcat.busy_threads_max "max(max_over_time(tomcat_threads_busy_threads{${JOB}}[${W}]))"
metric tomcat.max_threads      "max(tomcat_threads_config_max_threads{${JOB}})"

metric hikari.pool_max       "max(hikaricp_connections_max{${JOB}})"
metric hikari.active_max     "max(max_over_time(hikaricp_connections_active{${JOB}}[${W}]))"
metric hikari.pending_max    "max(max_over_time(hikaricp_connections_pending{${JOB}}[${W}]))"
avg_ms hikari.acquire_avg_ms hikaricp_connections_acquire_seconds "${JOB}"
metric hikari.acquire_max_ms "1000 * max(max_over_time(hikaricp_connections_acquire_seconds_max{${JOB}}[${W}]))"
metric hikari.timeouts       "sum(increase(hikaricp_connections_timeout_total{${JOB}}[${W}]))"

metric cache.seat_list_hit_ratio "sum(increase(cache_gets_total{${CACHE},result='hit'}[${W}])) / sum(increase(cache_gets_total{${CACHE}}[${W}]))"

metric      seat_query.per_sec "sum(rate(spring_data_repository_invocations_seconds_count{${SEAT_QUERY}}[${W}]))"
avg_ms      seat_query.avg_ms  spring_data_repository_invocations_seconds "${SEAT_QUERY}"
quantile_ms seat_query.p95_ms 0.95 spring_data_repository_invocations_seconds_bucket "${SEAT_QUERY}"

metric      redis.commands_per_sec "sum(rate(lettuce_command_completion_seconds_count{${JOB}}[${W}]))"
avg_ms      redis.hgetall_avg_ms   lettuce_command_completion_seconds "${HGETALL}"
quantile_ms redis.hgetall_p95_ms 0.95 lettuce_command_completion_seconds_bucket "${HGETALL}"
quantile_ms redis.hgetall_p99_ms 0.99 lettuce_command_completion_seconds_bucket "${HGETALL}"

metric jvm.process_cpu_avg   "avg_over_time(process_cpu_usage{${JOB}}[${W}])"
metric jvm.process_cpu_max   "max_over_time(process_cpu_usage{${JOB}}[${W}])"
metric jvm.system_cpu_max    "max_over_time(system_cpu_usage{${JOB}}[${W}])"
metric jvm.heap_used_max_mb  "max_over_time((sum(jvm_memory_used_bytes{${JOB},area='heap'}))[${W}:]) / 1048576"
metric jvm.gc_pause_total_ms "1000 * sum(increase(jvm_gc_pause_seconds_sum{${JOB}}[${W}]))"
metric jvm.gc_pause_max_ms   "1000 * max(max_over_time(jvm_gc_pause_seconds_max{${JOB}}[${W}]))"

jq -R -n --argjson start "$START" --argjson end "$END" '
  reduce (inputs | split("\t")) as [$key, $value]
    ({window: {start: $start, end: $end, seconds: ($end - $start)}};
     setpath($key | split(".");
       if ($value | test("^-?[0-9.]+(e-?[0-9]+)?$")) then ($value | tonumber * 1000 | round / 1000) else null end))
' "$ROWS" > "$OUT"
