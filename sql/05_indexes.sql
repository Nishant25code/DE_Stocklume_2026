-- =====================================================================
-- Phase 4 · Indexes for the 30-query workload
-- Team T0069 · Google Pay (UPI) · schema gpay · PostgreSQL 17
--
-- Run after 01_schema.sql and 02_load_data.sql:
--   psql -d gpay -f sql/05_indexes.sql
--
-- Rules we followed
--   * Equality columns first, then the range / ORDER BY column.
--   * Partial indexes for rare statuses (PENDING 125 rows, UNSCRATCHED 502,
--     DUE 1,508, OPEN disputes 116), so the index stays tiny and the nightly
--     jobs touch only the rows they change.
--   * INCLUDE (...) where it lets the query run as an Index Only Scan.
--   * Every index below is used by at least one query in
--     sql/06_optimized_queries.sql (checked with EXPLAIN).
--   * Indexes that already exist from PK / UNIQUE constraints (upi_ref,
--     vpas.vpa, rewards.txn_id, ...) are not repeated.
-- =====================================================================
SET search_path TO gpay;

-- ---------------------------------------------------------------------
-- transactions (250,468 rows, 36 MB): the table every slow query reads
-- ---------------------------------------------------------------------

-- I1 · R01, R03, R14, R18 (and R07/R25 joins)
-- "What did this VPA send, in a time window / newest first?"
-- payer_vpa is the equality column, initiated_at the range/sort column.
CREATE INDEX idx_txn_payer_time
    ON transactions (payer_vpa, initiated_at);

-- I2 · R01 (received half of the history after the UNION rewrite)
-- Same shape as I1 for the payee side. Without it the OR in R01 forces
-- a full scan, because one index cannot answer "payer = x OR payee = x".
CREATE INDEX idx_txn_payee_time
    ON transactions (payee_vpa, initiated_at);

-- I3 · R05, R13, R17, R19 (and R06/R15 can use it)
-- Merchant dashboards: merchant_id = ? AND status = ? AND time range.
-- Order: merchant_id (equality), status (equality), initiated_at (range).
-- INCLUDE amount so R05 and R19 never visit the table (Index Only Scan).
-- Partial (merchant_id IS NOT NULL): P2P rows (110,581) have no merchant,
-- so they are left out and the index is ~44% smaller.
CREATE INDEX idx_txn_merchant_status_time
    ON transactions (merchant_id, status, initiated_at)
    INCLUDE (amount)
    WHERE merchant_id IS NOT NULL;

-- I4 · R06, R07, R15, R20, R23, R25
-- Platform-wide date-range reports ("29 June", "June 2026", "last 7 days")
-- and the newest-first operations console (R23, keyset pagination).
-- B-tree, not BRIN: R23 needs the rows in order, and the date ranges
-- here select < 6% of the table, where a B-tree is clearly better.
CREATE INDEX idx_txn_initiated
    ON transactions (initiated_at);

-- I5 · R04, W02
-- Reconciliation: only 125 of 250,468 payments are PENDING.
-- Partial index = 125 entries; ordered by initiated_at for R04,
-- INCLUDE txn_id so W02's min(txn_id) is answered from the index.
CREATE INDEX idx_txn_pending
    ON transactions (initiated_at)
    INCLUDE (txn_id)
    WHERE status = 'PENDING';

-- I6 · R09
-- Duplicate-payment detection: lag() OVER (PARTITION BY payer_vpa,
-- payee_vpa ORDER BY initiated_at) over SUCCESS payments.
-- The index already returns rows in exactly the window's order, so the
-- 233k-row sort that spilled to disk in the baseline disappears.
-- Partial on SUCCESS (the only rows R09 reads); INCLUDE the other output
-- columns so it is an Index Only Scan.
CREATE INDEX idx_txn_success_pair_time
    ON transactions (payer_vpa, payee_vpa, initiated_at)
    INCLUDE (txn_id, amount)
    WHERE status = 'SUCCESS';

-- I17 · R08
-- Mule detection: GROUP BY payee_vpa, day with count(DISTINCT payer_vpa)
-- over successful P2P payments (102,742 rows). The baseline sorted all of
-- them by three text columns and spilled 6.9 MB to disk. With rows already
-- coming out ordered by payee_vpa, PostgreSQL uses an Incremental Sort that
-- only sorts each payee's few rows in memory. Partial on P2P + SUCCESS
-- (exactly R08's filter); INCLUDE payer_vpa and amount so it is an Index
-- Only Scan.
CREATE INDEX idx_txn_p2p_success_payee
    ON transactions (payee_vpa, initiated_at)
    INCLUDE (payer_vpa, amount)
    WHERE txn_type = 'P2P' AND status = 'SUCCESS';

-- ---------------------------------------------------------------------
-- vpas / bank_accounts: "which VPAs / accounts does user X own?"
-- ---------------------------------------------------------------------

-- I7 · R01, R03, R14, R18 (and every "WHERE v.user_id = ?")
-- The PK is on vpa; nothing indexed user_id, so each lookup scanned 53k rows.
-- INCLUDE vpa so the list of a user's VPAs is an Index Only Scan.
CREATE INDEX idx_vpas_user
    ON vpas (user_id) INCLUDE (vpa);

-- I8 · R22 (LEFT JOIN vpas ON v.account_id = ba.account_id), R07, R25
-- Foreign-key column with no index; also makes ON DELETE CASCADE from
-- bank_accounts cheap.
CREATE INDEX idx_vpas_account
    ON vpas (account_id);

-- I9 · R22
-- uq_ba_account_user starts with account_id and the primary-account index
-- is partial (is_primary only), so neither finds ALL accounts of a user.
CREATE INDEX idx_ba_user
    ON bank_accounts (user_id);

-- ---------------------------------------------------------------------
-- rewards: only 502 of 39,799 are UNSCRATCHED
-- ---------------------------------------------------------------------

-- I10 · R10, W03
-- User's live scratch cards ordered by expiry; W03 picks the user's
-- oldest card. Partial on UNSCRATCHED keeps it to 502 entries.
CREATE INDEX idx_rw_unscratched_user
    ON rewards (user_id, expires_at)
    INCLUDE (reward_type, issued_at)
    WHERE status = 'UNSCRATCHED';

-- I11 · R11, W04
-- Notification job and nightly expiry: all unscratched cards expiring
-- before a date, in expiry order.
CREATE INDEX idx_rw_unscratched_expiry
    ON rewards (expires_at)
    INCLUDE (user_id)
    WHERE status = 'UNSCRATCHED';

-- ---------------------------------------------------------------------
-- bill_payments: only 1,508 of 30,000 are DUE
-- ---------------------------------------------------------------------

-- I12 · R12
-- A user's unpaid bills due in the next 7 days.
CREATE INDEX idx_bill_due_user
    ON bill_payments (user_id, due_date)
    WHERE status = 'DUE';

-- I13 · W05
-- Nightly job: DUE bills past their due date become OVERDUE.
CREATE INDEX idx_bill_due_date
    ON bill_payments (due_date)
    WHERE status = 'DUE';

-- ---------------------------------------------------------------------
-- disputes
-- ---------------------------------------------------------------------

-- I14 · R16
-- SLA queue: OPEN disputes (116 of 3,569) raised before a date, oldest first.
CREATE INDEX idx_dsp_open_raised
    ON disputes (raised_at)
    WHERE status = 'OPEN';

-- ---------------------------------------------------------------------
-- merchants
-- ---------------------------------------------------------------------

-- I15 · R21
-- ILIKE '%chai%' has a leading wildcard, so a B-tree cannot help.
-- A trigram GIN index (pg_trgm) can. On 3,000 merchants the gain is
-- small today, but this is the only index type that scales for search.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_merchants_name_trgm
    ON merchants USING gin (merchant_name gin_trgm_ops);

-- I16 · R19
-- Bengaluru verified merchants: city_id equality, partial on is_verified.
CREATE INDEX idx_merchants_city_verified
    ON merchants (city_id)
    WHERE is_verified;

-- Fresh statistics and visibility map (needed for Index Only Scans).
VACUUM ANALYZE transactions;
VACUUM ANALYZE vpas;
VACUUM ANALYZE bank_accounts;
VACUUM ANALYZE rewards;
VACUUM ANALYZE bill_payments;
VACUUM ANALYZE disputes;
VACUUM ANALYZE merchants;
