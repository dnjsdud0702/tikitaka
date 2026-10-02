-- =========================================================
-- 좌석 목록 조회가 실제로 실행하는 쿼리의 실행 계획을 확인합니다.
-- (ScheduleSeatJpaRepository.findSeatSummaries가 만드는 목록 쿼리 + COUNT 쿼리와 같은 형태)
--
-- 사용 예:
--   docker exec -i tikitaka-ticketing-postgres psql -U ticketing -d tikitaka_ticketing \
--     -v session_id="'31000000-0000-0000-0000-000000000001'" -v size=200 -v last_offset=2800 \
--     < scripts/test-scenarios/s11-seat-list-load/explain-seat-list.sql
-- =========================================================

\echo '=== 1) 목록 쿼리 - 첫 페이지 (OFFSET 0) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT schedule_seat_id, section, row_label, seat_number, seat_grade, price, seat_status
FROM p_schedule_seat
WHERE event_session_id = :session_id::uuid
ORDER BY section, row_label, seat_number
OFFSET 0 ROWS FETCH FIRST :size ROWS ONLY;

\echo '=== 2) 목록 쿼리 - 마지막 페이지 (OFFSET이 커질 때 비용 비교) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT schedule_seat_id, section, row_label, seat_number, seat_grade, price, seat_status
FROM p_schedule_seat
WHERE event_session_id = :session_id::uuid
ORDER BY section, row_label, seat_number
OFFSET :last_offset ROWS FETCH FIRST :size ROWS ONLY;

\echo '=== 3) COUNT 쿼리 - 페이지 요청마다 함께 실행됨 ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM p_schedule_seat
WHERE event_session_id = :session_id::uuid;

