-- =====================================================================
-- Phase 5 · Partitioning transactions by month
-- Team T0069 · Google Pay (UPI) · PostgreSQL 17
--
-- Run after 01_schema.sql, 02_load_data.sql and 05_indexes.sql:
--   psql -d gpay -f sql/08_partitioning.sql
--
-- What it does
--   Builds a partitioned copy of gpay.transactions in a separate schema,
--   gpay_part, loads the same rows into it, and shows partition pruning with
--   EXPLAIN. The original gpay schema is not touched, so the optimized
--   benchmark keeps running on it, and both versions can be compared on the
--   same data.
--
-- Design (reasons in docs/05_scalability_report.md, section "Partitioning")
--   * Table:   transactions (the only table that grows by millions of rows;
--              every other table stays at about 1 M rows or fewer even at 20x).
--   * Method:  RANGE on initiated_at, one partition per calendar month (IST).
--              10 of our 30 queries filter transactions on initiated_at ("today", "29 June",
--              "June 2026", "last 7 days"); the date-bounded ones read 1 partition instead
--              of the whole table. Old months can be detached and archived
--              with no DELETE and no VACUUM storm.
--   * Not HASH on payer_vpa: it spreads one user's history evenly, but no
--              query could skip partitions by time, and archiving old data
--              would still need DELETE.
--   * Not LIST on status: 93 % of rows are SUCCESS, so the partitions would
--              be badly unbalanced.
--
-- The primary-key rule for partitioned tables
--   PostgreSQL can only enforce PRIMARY KEY / UNIQUE on a partitioned table if
--   the constraint includes the partition key. So:
--     PRIMARY KEY (txn_id)        -> PRIMARY KEY (txn_id, initiated_at)
--     UNIQUE (upi_ref)            -> UNIQUE (upi_ref, initiated_at)
--   Consequences, and what we do about them:
--     1. txn_id alone is no longer guaranteed unique by the table. txn_id
--        comes from one sequence, so duplicates cannot happen in practice.
--     2. upi_ref must be unique across ALL months (it is the NPCI reference
--        support searches for, R24). We keep a small, unpartitioned registry
--        table upi_refs (upi_ref PRIMARY KEY) that the payment path writes in
--        the same transaction. It enforces global uniqueness AND gives R24 a
--        single index lookup instead of one probe per partition.
--     3. rewards.txn_id and disputes.txn_id cannot have a foreign key to
--        transactions(txn_id) any more: a FK must point at a unique key, and
--        the only unique key is (txn_id, initiated_at). In production we would
--        add txn_initiated_at to rewards and disputes and use a composite FK.
--        This demo leaves gpay.rewards / gpay.disputes as they are.
-- =====================================================================

DROP SCHEMA IF EXISTS gpay_part CASCADE;
CREATE SCHEMA gpay_part;
SET search_path TO gpay_part, gpay;

-- ---------------------------------------------------------------------
-- 1. Parent table: same columns and CHECKs as gpay.transactions
-- ---------------------------------------------------------------------
CREATE TABLE gpay_part.transactions (
    txn_id        bigint        NOT NULL,
    upi_ref       varchar(12)   NOT NULL
                  CONSTRAINT chk_txn_upi_ref CHECK (upi_ref ~ '^[0-9]{12}$'),
    txn_type      varchar(3)    NOT NULL
                  CONSTRAINT chk_txn_type CHECK (txn_type IN ('P2P', 'P2M')),
    payer_vpa     varchar(100)  NOT NULL REFERENCES gpay.vpas(vpa) ON DELETE RESTRICT,
    payee_vpa     varchar(100)  NOT NULL
                  CONSTRAINT chk_txn_payee_format CHECK (payee_vpa ~ '^[a-z0-9._-]+@[a-z]+$'),
    merchant_id   integer,
    amount        numeric(10,2) NOT NULL
                  CONSTRAINT chk_txn_amount CHECK (amount > 0 AND amount <= 100000),
    note          varchar(100),
    initiated_at  timestamptz   NOT NULL,
    completed_at  timestamptz,
    status        varchar(10)   NOT NULL
                  CONSTRAINT chk_txn_status CHECK (status IN ('PENDING', 'SUCCESS', 'FAILED', 'REVERSED', 'REFUNDED')),
    failure_code  varchar(3)
                  CONSTRAINT chk_txn_failure_code CHECK (failure_code IN ('U16', 'U30', 'U69', 'XH', 'Z9', 'ZM')),
    CONSTRAINT chk_txn_p2m_merchant    CHECK ((txn_type = 'P2M') = (merchant_id IS NOT NULL)),
    CONSTRAINT chk_txn_failed_code     CHECK ((status = 'FAILED') = (failure_code IS NOT NULL)),
    CONSTRAINT chk_txn_pending_open    CHECK ((status = 'PENDING') = (completed_at IS NULL)),
    CONSTRAINT chk_txn_completed_after CHECK (completed_at >= initiated_at),
    CONSTRAINT chk_txn_refund_p2m      CHECK (status <> 'REFUNDED' OR txn_type = 'P2M'),
    CONSTRAINT chk_txn_not_self        CHECK (payer_vpa <> payee_vpa),
    CONSTRAINT fk_txn_merchant FOREIGN KEY (merchant_id, payee_vpa)
        REFERENCES gpay.merchants(merchant_id, merchant_vpa) ON DELETE RESTRICT,
    -- the partition key must be part of every PRIMARY KEY / UNIQUE constraint
    CONSTRAINT pk_txn PRIMARY KEY (txn_id, initiated_at),
    CONSTRAINT uq_txn_upi_ref_month UNIQUE (upi_ref, initiated_at)
) PARTITION BY RANGE (initiated_at);

-- ---------------------------------------------------------------------
-- 2. One partition per month (IST), Jan 2025 .. Sep 2026, plus DEFAULT
--    The data ends on 30 Jun 2026, so 3 future months are created in
--    advance; a monthly job keeps 3 months ahead (see the report).
-- ---------------------------------------------------------------------
DO $$
DECLARE
    m date := DATE '2025-01-01';
BEGIN
    WHILE m < DATE '2026-10-01' LOOP
        EXECUTE format(
            'CREATE TABLE gpay_part.%I PARTITION OF gpay_part.transactions
                 FOR VALUES FROM (%L) TO (%L)',
            'transactions_' || to_char(m, 'YYYY_MM'),
            (m::timestamp AT TIME ZONE 'Asia/Kolkata'),
            ((m + interval '1 month')::timestamp AT TIME ZONE 'Asia/Kolkata'));
        m := m + interval '1 month';
    END LOOP;
END $$;

-- Safety net: a row with a date outside every range lands here instead of failing.
-- Monitor it: it should stay empty.
CREATE TABLE gpay_part.transactions_default PARTITION OF gpay_part.transactions DEFAULT;

-- ---------------------------------------------------------------------
-- 3. Global uniqueness of upi_ref (see rule 2 in the header)
-- ---------------------------------------------------------------------
CREATE TABLE gpay_part.upi_refs (
    upi_ref       varchar(12) PRIMARY KEY,
    txn_id        bigint      NOT NULL,
    initiated_at  timestamptz NOT NULL,
    FOREIGN KEY (txn_id, initiated_at) REFERENCES gpay_part.transactions (txn_id, initiated_at)
);

-- ---------------------------------------------------------------------
-- 4. The Phase 4 indexes, created once on the parent.
--    PostgreSQL creates the matching index on every partition (and on
--    every partition added later). Same reasons as in 05_indexes.sql.
-- ---------------------------------------------------------------------
CREATE INDEX idx_ptxn_payer_time ON gpay_part.transactions (payer_vpa, initiated_at);
CREATE INDEX idx_ptxn_payee_time ON gpay_part.transactions (payee_vpa, initiated_at);
CREATE INDEX idx_ptxn_merchant_status_time ON gpay_part.transactions (merchant_id, status, initiated_at)
    INCLUDE (amount) WHERE merchant_id IS NOT NULL;
CREATE INDEX idx_ptxn_initiated ON gpay_part.transactions (initiated_at);
CREATE INDEX idx_ptxn_pending ON gpay_part.transactions (initiated_at)
    INCLUDE (txn_id) WHERE status = 'PENDING';
CREATE INDEX idx_ptxn_success_pair_time ON gpay_part.transactions (payer_vpa, payee_vpa, initiated_at)
    INCLUDE (txn_id, amount) WHERE status = 'SUCCESS';
CREATE INDEX idx_ptxn_p2p_success_payee ON gpay_part.transactions (payee_vpa, initiated_at)
    INCLUDE (payer_vpa, amount) WHERE txn_type = 'P2P' AND status = 'SUCCESS';

-- ---------------------------------------------------------------------
-- 5. Load the same rows (each row is routed to its month automatically)
-- ---------------------------------------------------------------------
INSERT INTO gpay_part.transactions SELECT * FROM gpay.transactions;
INSERT INTO gpay_part.upi_refs SELECT upi_ref, txn_id, initiated_at FROM gpay.transactions;
VACUUM ANALYZE gpay_part.transactions;
VACUUM ANALYZE gpay_part.upi_refs;

-- Rows per partition (non-empty ones), and the check that nothing fell into DEFAULT
SELECT tableoid::regclass AS partition, count(*) AS rows
FROM gpay_part.transactions
GROUP BY 1
ORDER BY 1;

SELECT (SELECT count(*) FROM gpay.transactions)      AS rows_original,
       (SELECT count(*) FROM gpay_part.transactions) AS rows_partitioned,
       (SELECT count(*) FROM gpay_part.transactions_default) AS rows_in_default;

-- ---------------------------------------------------------------------
-- 6. Partition pruning: EXPLAIN shows which partitions are read
-- ---------------------------------------------------------------------

-- R06 (settlement for 29 June 2026): only transactions_2026_06 is scanned.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT m.merchant_id, m.merchant_name, count(*) AS payments, sum(t.amount) AS settle_amount
FROM gpay_part.transactions t
JOIN gpay.merchants m ON m.merchant_id = t.merchant_id
WHERE t.status = 'SUCCESS'
  AND t.initiated_at >= '2026-06-29' AND t.initiated_at < '2026-06-30'
GROUP BY m.merchant_id, m.merchant_name
ORDER BY settle_amount DESC;

-- R20 rewritten (daily success rate in June 2026): one partition.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT initiated_at::date AS day, count(*) AS payments,
       round(100.0 * count(*) FILTER (WHERE status = 'SUCCESS') / count(*), 2) AS success_pct
FROM gpay_part.transactions
WHERE initiated_at >= '2026-06-01' AND initiated_at < '2026-07-01'
GROUP BY 1
ORDER BY 1;

-- R07 (failures since 24 June): the range has no end date, so June is read
-- through its index and the pre-created future months + DEFAULT are opened
-- too (they are empty, so this costs almost nothing).
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM gpay_part.transactions t
WHERE t.status = 'FAILED'
  AND t.initiated_at >= '2026-06-24';

-- Original R20 (initiated_at::date BETWEEN ...): the cast hides the column,
-- so NO pruning: every partition is scanned. Sargable rewrites matter even
-- more with partitioning.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*)
FROM gpay_part.transactions
WHERE initiated_at::date BETWEEN '2026-06-01' AND '2026-06-30';

-- R24 (find by UPI reference) has no date, so on the partitioned table it
-- must probe the upi_ref index of EVERY partition ...
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT txn_id, payer_vpa, payee_vpa, amount, status
FROM gpay_part.transactions
WHERE upi_ref = '600977648064';

-- ... the registry turns it back into one partition. Step 1: one primary-key
-- lookup in upi_refs gives the payment's date. Step 2 (what the support tool
-- runs next): the query with that date, which the planner prunes to a single
-- partition.
SELECT initiated_at AS found_at FROM gpay_part.upi_refs WHERE upi_ref = '600977648064' \gset
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT t.txn_id, t.payer_vpa, t.payee_vpa, t.amount, t.status
FROM gpay_part.transactions t
WHERE t.upi_ref = '600977648064'
  AND t.initiated_at = :'found_at';

-- ---------------------------------------------------------------------
-- 7. Archiving a month (example, commented out):
--    detaching is instant and needs no DELETE / VACUUM on the live table.
-- ---------------------------------------------------------------------
-- ALTER TABLE gpay_part.transactions DETACH PARTITION gpay_part.transactions_2025_01 CONCURRENTLY;
-- -- then dump it to cold storage and DROP TABLE gpay_part.transactions_2025_01;
