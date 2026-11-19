-- =====================================================================
-- Phase 4 (CP3): Performance Indexes for Google Pay (UPI) Schema
-- Database: PostgreSQL 15+ (tested on PostgreSQL 17.12)
-- =====================================================================
SET search_path TO gpay;

-- R21: GIN trigram index so ILIKE '%chai%' on merchants.merchant_name can use an index
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA gpay;
CREATE INDEX IF NOT EXISTS idx_merchants_name_trgm
    ON merchants USING gin (merchant_name gin_trgm_ops);

-- R19 (and R05, R06, R15, R17): composite B-tree on (merchant_id, initiated_at DESC)
-- with INCLUDE (status, amount) to speed merchant transaction lookups and aggregates
CREATE INDEX IF NOT EXISTS idx_txn_merchant_time
    ON transactions (merchant_id, initiated_at DESC)
    INCLUDE (status, amount)
    WHERE merchant_id IS NOT NULL;

-- R01, R03, R09, R14, R18, R25: equality on payer_vpa first, then initiated_at DESC
CREATE INDEX IF NOT EXISTS idx_txn_payer_time
    ON transactions (payer_vpa, initiated_at DESC)
    INCLUDE (status, amount, payee_vpa);

-- R01 (payee side): incoming payments by payee_vpa ordered newest first
CREATE INDEX IF NOT EXISTS idx_txn_payee_time
    ON transactions (payee_vpa, initiated_at DESC)
    INCLUDE (status, amount, payer_vpa);

-- R04, W02: small partial index on PENDING rows for fast reconciliation and min(txn_id)
CREATE INDEX IF NOT EXISTS idx_txn_pending_txn_id
    ON transactions (txn_id, initiated_at)
    WHERE status = 'PENDING';

-- R07: partial index on FAILED rows ordered by initiated_at
CREATE INDEX IF NOT EXISTS idx_txn_failed_time
    ON transactions (initiated_at, payer_vpa, failure_code)
    WHERE status = 'FAILED';

-- R06, R15, R20, R25: date-range scans on initiated_at
CREATE INDEX IF NOT EXISTS idx_txn_initiated_at
    ON transactions (initiated_at)
    INCLUDE (status, amount, merchant_id);

-- R01, R03, R07, R14, R18, R22, R25: foreign-key / join lookups on vpas and bank_accounts
CREATE INDEX IF NOT EXISTS idx_vpas_user_id
    ON vpas (user_id)
    INCLUDE (vpa, is_active, account_id);

CREATE INDEX IF NOT EXISTS idx_vpas_account_id
    ON vpas (account_id)
    INCLUDE (vpa, is_active, user_id);

CREATE INDEX IF NOT EXISTS idx_ba_user_id
    ON bank_accounts (user_id, is_primary DESC)
    INCLUDE (bank_name, account_last4);

-- R10, R11, W03, W04: partial indexes on UNSCRATCHED rewards
CREATE INDEX IF NOT EXISTS idx_rewards_unscratched_user_exp
    ON rewards (user_id, expires_at, reward_id)
    WHERE status = 'UNSCRATCHED';

CREATE INDEX IF NOT EXISTS idx_rewards_unscratched_expires
    ON rewards (expires_at)
    WHERE status = 'UNSCRATCHED';

-- R12, W05: partial indexes on DUE bill_payments
CREATE INDEX IF NOT EXISTS idx_bills_due_user_date
    ON bill_payments (user_id, due_date)
    WHERE status = 'DUE';

CREATE INDEX IF NOT EXISTS idx_bills_due_date
    ON bill_payments (due_date)
    WHERE status = 'DUE';

-- R16: partial index on OPEN disputes
CREATE INDEX IF NOT EXISTS idx_disputes_open_raised
    ON disputes (raised_at)
    WHERE status = 'OPEN';

ANALYZE;
