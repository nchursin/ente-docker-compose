-- Give all users 100 TB storage and 100-year validity.
-- Run after user signup: docker compose exec -T postgres psql -U pguser ente_db < storage-fix.sql

UPDATE subscriptions
SET storage = 109951162777600,
    expiry_time = EXTRACT(EPOCH FROM (NOW() + INTERVAL '100 years')) * 1000000
WHERE storage < 109951162777600;
