# S11-B 인기 회차 좌석맵 조회 부하테스트 (Seat List Load)

대량 데이터 상황에서 인기 회차의 좌석 목록(`GET /api/v1/schedules/{eventSessionId}/seats`)을
여러 사용자가 조회할 때 어디까지 버티고, 지연이 어느 구간에서 생기는지 확인하는 부하테스트입니다.

- 주 담당: Seat / 협업: Queue·Infra
- 도구: k6, jq, Docker, Prometheus·Grafana

## 측정 기준

| 항목 | 기준 | 이유 |
|---|---|---|
| 측정 단위 | **좌석맵 1회 조회** = 회차의 전체 좌석을 받는 데 필요한 요청 전체 (`size=200`으로 `hasNext`가 false가 될 때까지) | 요청 1건 기준으로는 페이지 크기만 줄여도 응답 크기·응답시간이 좋아 보입니다. 사용자가 하는 일(좌석맵 한 화면 보기)을 단위로 잡아야 페이지 크기나 API 구조가 바뀌어도 전후 비교가 됩니다. |
| 부하 모델 | **초당 조회 시작 수 고정** (k6 `constant-arrival-rate`) | VU 수를 고정하면 서버가 느려질수록 요청 수도 같이 줄어 포화 구간이 실제보다 좋게 나옵니다. 도착률을 고정하면 처리하지 못한 조회가 `dropped_iterations`로 드러납니다. |
| 판정 | 조회 p95 < 1,000ms, 조회 실패율 < 1%, 못 시작한 조회 0건 | 요청 단위가 아니라 조회 단위 SLA로 판정합니다. |
| 서버 지표 | 단계마다 같은 시간 구간의 Prometheus 값을 JSON으로 저장 | k6는 클라이언트가 본 시간만 알려주므로, 원인은 서버 지표로 교차검증합니다. |
| 실행 조건 기록 | 커밋·이미지·캐시/풀/TTL 설정·좌석 수를 `run-meta.txt`에 저장 | 재빌드 누락이나 설정 차이로 결과가 달라진 경우를 구분하기 위함입니다. |

> 2026-09-15~17 결과(`docs/test-results/S11-seat-list-load/`)는 요청 1건 기준 + VU 고정 방식으로
> 측정한 값이라, 이 방식으로 측정한 결과와 직접 비교할 수 없습니다.

## Quickstart

```bash
# 1) 스택 기동 - test 파일을 함께 적용해야 Histogram·Tomcat 지표와 환경변수 오버라이드가 켜집니다
docker compose -f docker-compose.yml -f docker-compose.test.yml up -d --build \
  ticketing-service platform-service prometheus grafana

# 2) (최초 1회) 플랫폼·티켓팅 기본 시드 + 대량 더미 좌석 시드
#    기본 시드는 scripts/test-scenarios/s01-happy-path/seed/ 참고
docker exec -i tikitaka-ticketing-postgres psql -U ticketing -d tikitaka_ticketing \
  -v session_id="'31000000-0000-0000-0000-000000000001'" \
  -v seat_count=3000 -v available_ratio=0.05 -v held_ratio=0.05 \
  < scripts/test-scenarios/s11-seat-list-load/seed-seat-list-load.sql

# 3) 단계별 실행 (워밍업 1분 → 초당 10 → 20 → 30 → 50 → 100회 조회, 단계별 2분)
scripts/test-scenarios/s11-seat-list-load/run-seat-list-load-steps.sh

# 4) (테스트가 끝난 뒤) 더미 좌석 정리
docker exec -i tikitaka-ticketing-postgres psql -U ticketing -d tikitaka_ticketing \
  -v session_id="'31000000-0000-0000-0000-000000000001'" \
  < scripts/test-scenarios/s11-seat-list-load/cleanup-seat-list-load.sql
```

실행 스크립트가 매번 자동으로 하는 일:

- 대상 회차의 판매 기간을 다시 엽니다(`open-sales-window.sql`). 기본 시드는 판매 종료를 시드 시점 + 2시간으로
  넣기 때문에, 시간이 지나면 대기열 진입이 전부 `Q-006`으로 거절됩니다.
- 시드된 좌석 수를 DB에서 읽어, 조회 1회마다 받은 좌석 수가 그 값과 같은지 검증합니다.
- 목록·COUNT 쿼리의 `EXPLAIN (ANALYZE, BUFFERS)` 결과를 저장합니다.

## 구성 파일

| 파일 | 역할 |
|---|---|
| `run-seat-list-load-steps.sh` | 사전 준비 → 워밍업 → 단계별 k6 실행 → 서버 지표 수집 → 요약 표 출력 |
| `seat-list-load.js` | k6 스크립트. `view` 시나리오가 표준이고, `setup()`에서 큐 토큰을 자체 발급합니다 |
| `collect-server-metrics.sh` | 지정한 시간 구간의 서버 지표를 Prometheus에서 뽑아 JSON으로 저장 |
| `explain-seat-list.sql` | 좌석 목록·COUNT 쿼리 실행 계획 확인 |
| `open-sales-window.sql` | 대상 회차의 판매 기간을 "지금 판매 중"으로 갱신 |
| `seed-seat-list-load.sql` / `cleanup-seat-list-load.sql` | 더미 좌석 생성 / 삭제 (`created_by=900099`로 구분) |
| `seat-list.js` | 단일 요청으로 API를 빠르게 확인하는 스모크 스크립트 |

`seat-list-load.js`의 `load`(VU 고정)·`compare` 시나리오는 이전 결과를 재현할 때만 씁니다.

## 실행 옵션

| 환경변수 | 기본값 | 의미 |
|---|---|---|
| `STAGES` | `10 20 30 50 100` | 단계별 초당 조회 시작 수 |
| `VIEW_DURATION` | `2m` | 단계별 유지 시간 |
| `VIEW_PAGE_SIZE` | `200` | 조회 1회에서 쓰는 페이지 크기 (API 최대값) |
| `VIEW_MAX_VUS` | `300` | 동시에 진행 중일 수 있는 조회 수 상한. 다 차면 새 조회는 시작하지 못하고 `dropped_iterations`로 집계 |
| `RECOVERY_WAIT` | `30` | 단계 사이 정상화 대기(초) |
| `LABEL` | (없음) | 결과 폴더 이름 뒤에 붙는 표시 (예: `cache-off`) |

⚠️ 한 단계(토큰 발급 + `VIEW_DURATION`)가 `queue.admission-token-ttl`(기본 3분)보다 길면 후반 요청이
`Q-001`로 실패합니다. 유지 시간을 2분보다 늘릴 때는 아래처럼 TTL을 늘려서 띄우세요.

## 조건을 바꿔가며 비교하기

서버 조건은 재빌드 없이 환경변수로 바꿉니다(`docker-compose.test.yml`). **한 번에 하나만** 바꾸고 같은
단계로 다시 실행한 뒤 두 결과 폴더의 `summary.md`를 비교하세요.

| 환경변수 | 기본값 | 의미 |
|---|---|---|
| `SEAT_LIST_CACHE_ENABLED` | `true` | 좌석 목록 Caffeine 캐시 on/off |
| `SEAT_LIST_CACHE_TTL_SECONDS` | `2` | 캐시 TTL(초) |
| `TICKETING_DB_POOL_SIZE` | `10` | HikariCP 최대 커넥션 수 |
| `QUEUE_ADMISSION_TOKEN_TTL` | `PT3M` | 큐 입장 토큰 TTL |

```bash
# 예: 캐시를 끈 상태로 재측정
SEAT_LIST_CACHE_ENABLED=false docker compose -f docker-compose.yml -f docker-compose.test.yml up -d ticketing-service
LABEL=cache-off scripts/test-scenarios/s11-seat-list-load/run-seat-list-load-steps.sh
```

서버 코드를 바꿨다면 `--build`를 붙여 이미지를 다시 만들어야 반영됩니다. 실제로 어떤 이미지·설정으로
측정됐는지는 결과 폴더의 `run-meta.txt`로 확인하세요.

## 결과 확인

결과는 `artifacts/k6/s11-seat-list-load/<타임스탬프>[_LABEL]/`에 쌓입니다(Git에 올리지 않는 원본 자료).

| 파일 | 내용 |
|---|---|
| `summary.md` | 단계별 요약 표 (조회 p50/p95/p99, 실패율, 못 시작한 조회, 서버 지표 핵심값) |
| `<rate>rps.k6.json` | k6 요약 원본 |
| `<rate>rps.server.json` | 같은 구간의 서버 지표 |
| `run-meta.txt` | 커밋, 이미지, 설정값, 좌석 수, 단계 구성 |
| `explain.txt` | 목록·COUNT 쿼리 실행 계획 |
| `recovery.txt` | 단계 종료 후 활성 DB 커넥션 수 |

`<rate>rps.server.json`의 값으로 병목 구간을 구분합니다.

| 값 | 의심할 수 있는 원인 |
|---|---|
| `tomcat.busy_threads_max`가 `max_threads`에 근접 | 요청 처리 스레드 부족 (뒤 구간이 느려 스레드가 묶임) |
| `hikari.pending_max` > 0, `acquire_*_ms` 증가 | DB 커넥션 풀 대기 |
| `seat_query.avg_ms`·`p95_ms` 증가 | 쿼리 자체가 느림 (`explain.txt`와 함께 확인) |
| `cache.seat_list_hit_ratio`가 낮음 | 캐시가 부하를 흡수하지 못함 |
| `redis.hgetall_*_ms` 증가 | 대기열 입장 검증(요청마다 Redis 조회) 구간 지연 |
| `jvm.process_cpu_max`가 1에 근접, `gc_pause_*` 증가 | CPU 포화 / GC 정지 |

실시간 추이는 Grafana(`http://localhost:3000`) → Tikitaka 폴더 → **TIKITAKA Load Test - Seat List (S11)**
대시보드에서 봅니다.

## 한계

- k6와 서버가 같은 장비에서 돌아 CPU를 나눠 씁니다. 고부하 단계의 수치는 부하 생성기 영향이 섞여 있을 수
  있으므로, 절대값보다 **같은 장비·같은 조건에서의 전후 비교**로 사용하세요.
- 조회 1회 안의 페이지 요청은 순차로 보냅니다(브라우저의 병렬 요청은 모사하지 않음).
- 서버 지표 구간은 k6 종료 시각에서 `VIEW_DURATION`만큼 거슬러 잡습니다. 종료 직후 몇 초가 포함될 수 있어
  비율·분위수 값이 약간 낮게 나올 수 있습니다(최대값 계열은 영향 없음).
