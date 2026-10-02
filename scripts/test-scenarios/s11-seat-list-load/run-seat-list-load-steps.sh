#!/usr/bin/env bash
# 좌석맵 조회 단계별 부하테스트 (도착률 기반)
#
# 측정 단위는 "좌석 목록 요청 1건"이 아니라 "한 사용자가 회차의 좌석맵 전체를 한 번 받는 것"이고,
# 부하는 VU 수가 아니라 초당 조회 시작 수로 고정합니다 (seat-list-load.js의 view 시나리오).
# 단계마다 k6 결과와 같은 시간 구간의 서버 지표(HikariCP·캐시 적중률·Redis·Tomcat·CPU·GC)를 함께 저장하므로,
# API 구조나 캐시 설정을 바꾼 뒤 같은 명령으로 다시 돌리면 그대로 전후 비교가 됩니다.
#
# 사용법:
#   scripts/test-scenarios/s11-seat-list-load/run-seat-list-load-steps.sh
#   STAGES="25 50" VIEW_DURATION=1m LABEL=cache-off scripts/test-scenarios/s11-seat-list-load/run-seat-list-load-steps.sh
#
# 전제:
#   - docker compose -f docker-compose.yml -f docker-compose.test.yml 로 스택이 떠 있을 것
#     (test 파일이 Histogram·Tomcat 스레드 지표와 캐시/풀/토큰 TTL 환경변수 오버라이드를 켭니다)
#   - seed-seat-list-load.sql로 좌석이 시드돼 있을 것
#   - k6, jq, docker 설치
#
# ⚠️ 한 단계(토큰 발급 + VIEW_DURATION)가 admission-token-ttl(기본 3분)보다 길면 후반 요청이
#    Q-001로 실패합니다. VIEW_DURATION을 2분보다 늘릴 때는 QUEUE_ADMISSION_TOKEN_TTL=PT30M으로
#    ticketing-service를 다시 띄우세요.
#
# 결과는 artifacts/k6/s11-seat-list-load/<타임스탬프>[_LABEL]/ 에 쌓입니다 (Git에 올리지 않는 원본 자료).

set -euo pipefail
cd "$(dirname "$0")"

BASE_URL="${BASE_URL:-http://localhost:8082}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
SESSION_ID="${SESSION_ID:-31000000-0000-0000-0000-000000000001}"
# 초당 좌석맵 조회 시작 수 (단계별)
read -r -a STAGES <<< "${STAGES:-10 20 30 50 100}"
VIEW_DURATION="${VIEW_DURATION:-2m}"
VIEW_PAGE_SIZE="${VIEW_PAGE_SIZE:-200}"
VIEW_MAX_VUS="${VIEW_MAX_VUS:-300}"
RECOVERY_WAIT="${RECOVERY_WAIT:-30}"
LABEL="${LABEL:-}"

TICKETING_CONTAINER="${TICKETING_CONTAINER:-tikitaka-ticketing-service}"
TICKETING_DB_CONTAINER="${TICKETING_DB_CONTAINER:-tikitaka-ticketing-postgres}"
PLATFORM_DB_CONTAINER="${PLATFORM_DB_CONTAINER:-tikitaka-platform-postgres}"

TS="$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="../../../artifacts/k6/s11-seat-list-load/${TS}${LABEL:+_${LABEL}}"

for tool in k6 jq docker curl; do
  command -v "$tool" >/dev/null || { echo "!! ${tool}이(가) 필요합니다"; exit 1; }
done

# 호스트에 psql이 없어도 되도록 DB 컨테이너 안의 psql을 씁니다 (접속 정보는 컨테이너 환경변수 사용).
db_psql() { # $1=컨테이너, 나머지=psql 인자 (SQL 파일은 stdin으로)
  local container="$1"; shift
  docker exec -i "$container" sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 "$@"' sh "$@"
}

duration_seconds() { # k6 형식(예: 90s, 2m, 1m30s)을 초로 변환
  local value="$1" total=0
  [[ "$value" =~ ([0-9]+)m ]] && total=$(( total + BASH_REMATCH[1] * 60 ))
  [[ "$value" =~ ([0-9]+)s ]] && total=$(( total + BASH_REMATCH[1] ))
  echo "$total"
}

container_env() { # $1=환경변수 이름 -> ticketing-service 컨테이너에 실제로 들어간 값
  docker exec "$TICKETING_CONTAINER" printenv "$1" 2>/dev/null || echo "(미설정)"
}

mkdir -p "$RESULT_DIR"
echo "결과: ${RESULT_DIR}"

echo
echo "================================================"
echo " 0) 사전 준비"
echo "================================================"

# 판매 기간이 지나 있으면 대기열 진입이 전부 Q-006으로 거절되므로 매 실행마다 다시 엽니다.
db_psql "$PLATFORM_DB_CONTAINER" -q -v session_id="'${SESSION_ID}'" < open-sales-window.sql

SEAT_COUNT="$(db_psql "$TICKETING_DB_CONTAINER" -tA \
  -c "SELECT count(*) FROM p_schedule_seat WHERE event_session_id = '${SESSION_ID}'")"
if [ "$SEAT_COUNT" -eq 0 ]; then
  echo "!! 회차 ${SESSION_ID}에 좌석이 없습니다 - seed-seat-list-load.sql을 먼저 실행하세요"
  exit 1
fi
LAST_OFFSET=$(( (SEAT_COUNT - 1) / VIEW_PAGE_SIZE * VIEW_PAGE_SIZE ))

# 어떤 코드·설정으로 측정했는지 결과 옆에 남깁니다 (재빌드 누락·설정 차이로 인한 혼동 방지).
REPO_ROOT="$(git rev-parse --show-toplevel)"
{
  echo "실행 시각: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "commit: $(git rev-parse HEAD)$([ -n "$(git status --porcelain -- "${REPO_ROOT}/ticketing-service")" ] && echo ' (+ ticketing-service 미커밋 변경 있음)')"
  echo "ticketing-service image: $(docker inspect -f '{{.Image}}' "$TICKETING_CONTAINER")"
  echo "ticketing-service 컨테이너 시작: $(docker inspect -f '{{.State.StartedAt}}' "$TICKETING_CONTAINER")"
  echo "k6: $(k6 version)"
  echo "docker: CPU $(docker info -f '{{.NCPU}}')개, 메모리 $(( $(docker info -f '{{.MemTotal}}') / 1048576 ))MB (부하 생성기 k6도 같은 장비에서 실행)"
  echo "좌석 수: ${SEAT_COUNT} (session ${SESSION_ID})"
  echo "워크로드: 좌석맵 1회 조회 = size ${VIEW_PAGE_SIZE}로 전체 페이지 순차 요청"
  echo "단계(초당 조회 수): ${STAGES[*]} / 단계별 유지 ${VIEW_DURATION} / 최대 VU ${VIEW_MAX_VUS}"
  echo "SEAT_LIST_CACHE_ENABLED: $(container_env SEAT_LIST_CACHE_ENABLED)"
  echo "SEAT_LIST_CACHE_TTL_SECONDS: $(container_env SEAT_LIST_CACHE_TTL_SECONDS)"
  echo "p_schedule_seat 인덱스: $(db_psql "$TICKETING_DB_CONTAINER" -tA -c "SELECT string_agg(indexname, ', ' ORDER BY indexname) FROM pg_indexes WHERE tablename = 'p_schedule_seat'")"
  echo "SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE: $(container_env SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE)"
  echo "QUEUE_ADMISSION_TOKEN_TTL: $(container_env QUEUE_ADMISSION_TOKEN_TTL)"
} | tee "${RESULT_DIR}/run-meta.txt"

db_psql "$TICKETING_DB_CONTAINER" \
  -v session_id="'${SESSION_ID}'" -v size="$VIEW_PAGE_SIZE" -v last_offset="$LAST_OFFSET" \
  < explain-seat-list.sql > "${RESULT_DIR}/explain.txt"
echo "쿼리 실행 계획: ${RESULT_DIR}/explain.txt"

run_view() { # $1=초당 조회 수 $2=유지 시간, 나머지=k6 추가 옵션
  local rate="$1" duration="$2"; shift 2
  k6 run \
    --env SCENARIO=view --env VIEW_RATE="$rate" --env VIEW_DURATION="$duration" \
    --env VIEW_PAGE_SIZE="$VIEW_PAGE_SIZE" --env VIEW_MAX_VUS="$VIEW_MAX_VUS" \
    --env EXPECTED_SEATS="$SEAT_COUNT" \
    --env BASE_URL="$BASE_URL" --env SESSION_ID="$SESSION_ID" \
    "$@" seat-list-load.js
}

echo
echo "================================================"
echo " 1) JVM/커넥션 풀 워밍업 (측정에 포함하지 않음, 초당 20회 × 1m)"
echo "================================================"
run_view 20 1m --quiet || true

for RATE in "${STAGES[@]}"; do
  echo
  echo "================================================"
  echo " 초당 ${RATE}회 조회 단계 시작 (유지 ${VIEW_DURATION})"
  echo "================================================"

  # threshold 초과는 "실패"가 아니라 관찰 대상이라, k6가 non-zero로 끝나도 다음 단계로 계속 진행합니다.
  if ! run_view "$RATE" "$VIEW_DURATION" --summary-export="${RESULT_DIR}/${RATE}rps.k6.json"; then
    echo "!! 초당 ${RATE}회 단계에서 threshold 초과 (계속 진행)"
  fi
  STAGE_END="$(date +%s)"
  # k6 실행 시간에는 setup()의 토큰 발급이 포함되므로, 부하가 실제로 걸린 뒤쪽 VIEW_DURATION 구간만 봅니다.
  STAGE_START="$(( STAGE_END - $(duration_seconds "$VIEW_DURATION") ))"

  # 마지막 scrape(5s 주기)가 Prometheus에 들어올 때까지 잠깐 기다린 뒤 수집합니다.
  sleep 10
  if PROM_URL="$PROM_URL" ./collect-server-metrics.sh "$STAGE_START" "$STAGE_END" "${RESULT_DIR}/${RATE}rps.server.json"; then
    jq -c '{http, tomcat, hikari, cache, redis}' "${RESULT_DIR}/${RATE}rps.server.json"
  else
    echo "!! 서버 지표 수집 실패 (Prometheus ${PROM_URL} 확인)"
    echo '{}' > "${RESULT_DIR}/${RATE}rps.server.json"
  fi

  echo "-- 시스템 정상화 대기 ${RECOVERY_WAIT}s --"
  sleep "$RECOVERY_WAIT"
  ACTIVE="$(db_psql "$TICKETING_DB_CONTAINER" -tA \
    -c "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND state = 'active' AND pid <> pg_backend_pid()")"
  echo "-- 정상화 후 활성 DB 커넥션 수: ${ACTIVE} --" | tee -a "${RESULT_DIR}/recovery.txt"
done

echo
echo "================================================"
echo " 단계별 요약 (조회 = 좌석맵 1회 전체 조회)"
echo "================================================"
{
  echo "| 목표(조회/s) | 실제(조회/s) | 조회 p50 | 조회 p95 | 조회 p99 | 실패율 | 못 시작한 조회 | 서버 요청 p95 | Tomcat busy | Hikari active/pending 최대 | 캐시 적중률 | HGETALL p95 | CPU 최대 |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  for RATE in "${STAGES[@]}"; do
    K6="${RESULT_DIR}/${RATE}rps.k6.json"
    SERVER="${RESULT_DIR}/${RATE}rps.server.json"
    [ -f "$K6" ] || continue
    jq -r --arg rate "$RATE" --argjson seconds "$(duration_seconds "$VIEW_DURATION")" --slurpfile s "$SERVER" '
      def ms: if . == null then "-" else "\(. * 10 | round / 10)ms" end;
      def pct: if . == null then "-" else "\(. * 1000 | round / 10)%" end;
      def num: if . == null then "-" else tostring end;
      .metrics as $m | $s[0] as $sv |
      "| \($rate) | \($m.iterations.count / $seconds * 10 | round / 10) | \($m.seat_map_view_duration.med | ms) | \($m.seat_map_view_duration["p(95)"] | ms) | \($m.seat_map_view_duration["p(99)"] | ms) | \($m.seat_map_view_failed.value | pct) | \($m.dropped_iterations.count // 0) | \($sv.http.p95_ms | ms) | \($sv.tomcat.busy_threads_max | num)/\($sv.tomcat.max_threads | num) | \($sv.hikari.active_max | num)/\($sv.hikari.pending_max | num) (풀 \($sv.hikari.pool_max | num)) | \($sv.cache.seat_list_hit_ratio | pct) | \($sv.redis.hgetall_p95_ms | ms) | \($sv.jvm.process_cpu_max | pct) |"
    ' "$K6"
  done
} | tee "${RESULT_DIR}/summary.md"

echo
echo "모든 단계 완료. 결과: ${RESULT_DIR}/ (run-meta.txt, explain.txt, <rate>rps.k6.json, <rate>rps.server.json, summary.md)"
