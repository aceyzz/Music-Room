-- Audit and security logging (docs/data-model.md 12).
--
-- Subject V.6: any action on the mobile application must generate a log on the
-- backend, including platform, device and application version.
--
-- This table grows fastest by an order of magnitude, so it is range-partitioned
-- by month from day one -- retrofitting partitioning onto a large table is
-- painful. The PK must include the partition key, hence (id, created_at).
--
-- Every partition is created inside a DO block rather than as literal
-- "CREATE TABLE ... PARTITION OF" statements. sqlc parses this directory to build
-- its catalog, and 25 literal partitions would become 25 phantom Go structs; a
-- DO block is opaque to its parser, so only one ActivityLog model is generated.

-- +goose Up
CREATE TABLE activity_logs (
    id                    BIGSERIAL   NOT NULL,
    -- nullable even though accounts are mandatory: a failed login or an
    -- expired-token call has no authenticated user yet, and those are precisely
    -- the events worth logging
    user_id               BIGINT      REFERENCES users (id) ON DELETE SET NULL,
    device_id             BIGINT      REFERENCES devices (id) ON DELETE SET NULL,
    action                TEXT        NOT NULL,
    resource_type         TEXT,
    -- deliberately NOT a foreign key: it points at whichever table resource_type
    -- names, and logs must outlive the rows they describe
    resource_id           BIGINT,
    -- referenced via device_id AND snapshotted, because the log has to stay
    -- truthful after a device row is removed. One of the few places where
    -- duplication is right.
    platform_snapshot     TEXT,
    app_version_snapshot  TEXT,
    ip_address            INET,
    user_agent            TEXT,
    result_code           SMALLINT,
    metadata              JSONB       NOT NULL DEFAULT '{}'::JSONB,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- Declared on the parent, so every present and future partition inherits them.
CREATE INDEX activity_logs_user_created_at_idx ON activity_logs (user_id, created_at DESC);
CREATE INDEX activity_logs_action_created_at_idx ON activity_logs (action, created_at DESC);
CREATE INDEX activity_logs_resource_idx ON activity_logs (resource_type, resource_id);

-- Monthly partitions covering last month through +23 months, plus a DEFAULT
-- partition so an insert outside that range can never fail. A maintenance job
-- should roll new months forward and detach old ones; the default is the safety
-- net, not the plan.
-- +goose StatementBegin
DO $$
DECLARE
    anchor      DATE := (date_trunc('month', NOW()) - INTERVAL '1 month')::DATE;
    start_month DATE;
    end_month   DATE;
    i           INT;
BEGIN
    FOR i IN 0..24 LOOP
        start_month := (anchor + (i || ' month')::INTERVAL)::DATE;
        end_month   := (start_month + INTERVAL '1 month')::DATE;

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF activity_logs FOR VALUES FROM (%L) TO (%L)',
            'activity_logs_' || to_char(start_month, 'YYYY"m"MM'),
            start_month,
            end_month
        );
    END LOOP;

    EXECUTE 'CREATE TABLE IF NOT EXISTS activity_logs_default PARTITION OF activity_logs DEFAULT';
END
$$;
-- +goose StatementEnd

-- +goose Down
DROP TABLE IF EXISTS activity_logs;
