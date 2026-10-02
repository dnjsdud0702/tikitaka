-- =========================================================
-- 부하테스트 대상 회차의 판매 기간을 "지금 판매 중"으로 다시 맞춥니다.
-- platform-seed.sql은 판매 종료 시각을 시드 시점 + 2시간으로 넣기 때문에, 시드한 지 2시간이
-- 지나면 대기열 진입이 Q-006(현재 회차는 대기열 진입이 불가능합니다)으로 전부 거절됩니다.
-- 이 스크립트는 해당 회차 1건의 시각만 갱신하고 다른 데이터는 건드리지 않습니다.
--
-- 사용 예:
--   docker exec -i tikitaka-platform-postgres psql -U platform -d tikitaka_platform \
--     -v session_id="'31000000-0000-0000-0000-000000000001'" \
--     < scripts/test-scenarios/s11-seat-list-load/open-sales-window.sql
-- =========================================================

UPDATE p_event_session
SET sales_open_at        = CURRENT_TIMESTAMP - INTERVAL '1 hour',
    sales_close_at       = CURRENT_TIMESTAMP + INTERVAL '6 hours',
    performance_start_at = CURRENT_TIMESTAMP + INTERVAL '7 hours',
    performance_end_at   = CURRENT_TIMESTAMP + INTERVAL '9 hours'
WHERE id = :session_id::uuid;
