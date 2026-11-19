-- =====================================================================
-- Phase 4 · Optimized workload (Team T0069)
-- Copy of queries/workload_30.sql. Only the queries tagged
-- "REWRITTEN" below were changed; every other query is byte-for-byte the
-- original and gets faster from the indexes in sql/05_indexes.sql alone.
--
-- Rewritten: R01, R03, R13, R14, R17, R19, R20, R23
--   * Every rewrite returns the same rows as the original (proof in
--     docs/04_optimization_report.md), except R13, whose original is WRONG
--     (NOT IN + NULL) and returns 0 rows instead of 450.
--
-- Run: ./benchmarks/run_benchmark.sh gpay optimized 3 sql/06_optimized_queries.sql
-- Safe to run directly: everything is inside BEGIN ... ROLLBACK.
-- =====================================================================
SET search_path TO gpay;
BEGIN;

-- @R01
-- Transaction history: everything user 15177 sent or received, newest first
-- REWRITTEN: "payer IN (...) OR payee IN (...)" cannot use one index, so the
-- original scanned all 250k rows. Split into a sent half and a received half,
-- each reading only its newest 30 rows from idx_txn_payer_time /
-- idx_txn_payee_time, then merge. UNION (not UNION ALL) so a payment between
-- two of the user's own VPAs, which appears in both halves, is listed once,
-- exactly like the original.
SELECT txn_id, upi_ref, payer_vpa, payee_vpa, amount, status, initiated_at
FROM (
    (SELECT t.txn_id, t.upi_ref, t.payer_vpa, t.payee_vpa, t.amount, t.status, t.initiated_at
     FROM vpas v JOIN transactions t ON t.payer_vpa = v.vpa
     WHERE v.user_id = 15177
     ORDER BY t.initiated_at DESC LIMIT 30)
    UNION
    (SELECT t.txn_id, t.upi_ref, t.payer_vpa, t.payee_vpa, t.amount, t.status, t.initiated_at
     FROM vpas v JOIN transactions t ON t.payee_vpa = v.vpa
     WHERE v.user_id = 15177
     ORDER BY t.initiated_at DESC LIMIT 30)
) h
ORDER BY initiated_at DESC
LIMIT 30;

-- @R02
-- "Pay to UPI ID": check that the entered VPA exists and is active
SELECT v.vpa, u.full_name, v.is_active
FROM vpas v
JOIN users u ON u.user_id = v.user_id
WHERE v.vpa = 'aditya.gupta15177@okhdfcbank';

-- @R03
-- UPI limit check: total successfully sent by user 15177 on 30 June 2026 (limit ₹1,00,000/day)
SELECT coalesce(sum(t.amount), 0) AS sent_today
FROM transactions t
JOIN vpas v ON v.vpa = t.payer_vpa
WHERE v.user_id = 15177
  AND t.status IN ('SUCCESS', 'PENDING')
  -- REWRITTEN: DATE(initiated_at) = '2026-06-30' wraps the column in a
  -- function, so no index on initiated_at can be used. The same day as a
  -- half-open range (session time zone Asia/Kolkata, as DATE() uses):
  AND t.initiated_at >= '2026-06-30' AND t.initiated_at < '2026-07-01';

-- @R04
-- Reconciliation: payments still PENDING more than 15 minutes after 23:59 on 30 Jun 2026
SELECT txn_id, upi_ref, payer_vpa, amount, initiated_at
FROM transactions
WHERE status = 'PENDING'
  AND initiated_at < TIMESTAMPTZ '2026-06-30 23:59:00+05:30' - interval '15 minutes'
ORDER BY initiated_at;

-- @R05
-- Google Pay for Business: hourly collections of merchant 2 on 29 June 2026
SELECT EXTRACT(HOUR FROM initiated_at) AS hour, count(*) AS payments, sum(amount) AS collected
FROM transactions
WHERE merchant_id = 2
  AND status = 'SUCCESS'
  AND initiated_at >= '2026-06-29' AND initiated_at < '2026-06-30'
GROUP BY 1
ORDER BY 1;

-- @R06
-- Settlement: amount to settle to every merchant for 29 June 2026
SELECT m.merchant_id, m.merchant_name, count(*) AS payments, sum(t.amount) AS settle_amount
FROM transactions t
JOIN merchants m ON m.merchant_id = t.merchant_id
WHERE t.status = 'SUCCESS'
  AND t.initiated_at >= '2026-06-29' AND t.initiated_at < '2026-06-30'
GROUP BY m.merchant_id, m.merchant_name
ORDER BY settle_amount DESC;

-- @R07
-- Bank health: failure codes per payer bank in the last 7 days
SELECT ba.bank_name, t.failure_code, count(*) AS failures
FROM transactions t
JOIN vpas v           ON v.vpa = t.payer_vpa
JOIN bank_accounts ba ON ba.account_id = v.account_id
WHERE t.status = 'FAILED'
  AND t.initiated_at >= '2026-06-24'
GROUP BY ba.bank_name, t.failure_code
ORDER BY failures DESC;

-- @R08
-- Fraud: VPAs that received P2P money from 5+ different people on the same day
SELECT payee_vpa, initiated_at::date AS day, count(DISTINCT payer_vpa) AS distinct_payers, sum(amount) AS received
FROM transactions
WHERE txn_type = 'P2P' AND status = 'SUCCESS'
GROUP BY payee_vpa, initiated_at::date
HAVING count(DISTINCT payer_vpa) >= 5
ORDER BY distinct_payers DESC;

-- @R09
-- Fraud: repeated payments—same payer to the same payee within 10 minutes of the previous one
SELECT *
FROM (
    SELECT txn_id, payer_vpa, payee_vpa, amount, initiated_at,
           initiated_at - lag(initiated_at) OVER (PARTITION BY payer_vpa, payee_vpa ORDER BY initiated_at) AS gap
    FROM transactions
    WHERE status = 'SUCCESS'
) t
WHERE gap < interval '10 minutes'
ORDER BY initiated_at DESC;

-- @R10
-- Rewards tab: user 15177's unscratched cards that have not expired
SELECT reward_id, reward_type, issued_at, expires_at
FROM rewards
WHERE user_id = 15177 AND status = 'UNSCRATCHED'
  AND expires_at > '2026-06-30 23:59:00+05:30'
ORDER BY expires_at;

-- @R11
-- Notification job: unscratched rewards that expire in the first 3 days of July
SELECT reward_id, user_id, expires_at
FROM rewards
WHERE status = 'UNSCRATCHED'
  AND expires_at < '2026-07-04'
ORDER BY expires_at;

-- @R12
-- Bill reminders: user 1072's unpaid bills due in the next 7 days
SELECT bill_id, biller_name, amount, due_date
FROM bill_payments
WHERE user_id = 1072 AND status = 'DUE'
  AND due_date BETWEEN '2026-07-01' AND '2026-07-07'
ORDER BY due_date;

-- @R13
-- Merchant success team: merchants who have never received a payment (to call and help them)
-- REWRITTEN (bug fix): the original NOT IN returns 0 rows. P2P payments
-- have merchant_id NULL, and "x NOT IN (..., NULL)" is NULL (never TRUE),
-- so every merchant is filtered out. NOT EXISTS ignores NULLs and returns
-- the 450 merchants that really have no payment; it also becomes an
-- Anti Join probing idx_txn_merchant_status_time instead of hashing 250k rows.
SELECT m.merchant_id, m.merchant_name, m.onboarded_on
FROM merchants m
WHERE NOT EXISTS (SELECT 1 FROM transactions t WHERE t.merchant_id = m.merchant_id);

-- @R14
-- Spend analysis: user 15177's 2026 spending per merchant category code (MCC)
SELECT m.mcc, count(*) AS payments, sum(t.amount) AS spent
FROM transactions t
JOIN merchants m ON m.merchant_id = t.merchant_id
JOIN vpas v      ON v.vpa = t.payer_vpa
WHERE v.user_id = 15177
  AND t.status = 'SUCCESS'
  -- REWRITTEN: EXTRACT(YEAR FROM initiated_at) >= 2025 is not sargable;
  -- the same condition as a plain range on the column:
  AND t.initiated_at >= '2025-01-01'
GROUP BY m.mcc
ORDER BY spent DESC;

-- @R15
-- Business insights: top 10 merchants by June 2026 GMV in each city
SELECT *
FROM (
    SELECT m.city_id, m.merchant_id, m.merchant_name, sum(t.amount) AS gmv,
           RANK() OVER (PARTITION BY m.city_id ORDER BY sum(t.amount) DESC) AS rnk
    FROM transactions t
    JOIN merchants m ON m.merchant_id = t.merchant_id
    WHERE t.status = 'SUCCESS'
      AND t.initiated_at >= '2026-06-01' AND t.initiated_at < '2026-07-01'
    GROUP BY m.city_id, m.merchant_id, m.merchant_name
) r
WHERE rnk <= 10
ORDER BY city_id, rnk;

-- @R16
-- Disputes desk: disputes open for more than 7 days (SLA breached)
SELECT d.dispute_id, d.reason, d.raised_at, t.upi_ref, t.amount
FROM disputes d
JOIN transactions t ON t.txn_id = d.txn_id
WHERE d.status = 'OPEN'
  AND d.raised_at < '2026-06-23'
ORDER BY d.raised_at;

-- @R17
-- Merchant risk: refund rate per merchant (at least 30 payments)
-- REWRITTEN: txn_type = 'P2M' replaced by merchant_id IS NOT NULL.
-- They select exactly the same rows: CHECK chk_txn_p2m_merchant enforces
-- (txn_type = 'P2M') = (merchant_id IS NOT NULL). The new form matches the
-- partial index idx_txn_merchant_status_time, which holds merchant_id and
-- status, so the whole report is an Index Only Scan already sorted by
-- merchant_id (no hash, no table access).
SELECT merchant_id, count(*) AS payments,
       round(100.0 * count(*) FILTER (WHERE status = 'REFUNDED') / count(*), 2) AS refund_pct
FROM transactions
WHERE merchant_id IS NOT NULL
GROUP BY merchant_id
HAVING count(*) >= 30
ORDER BY refund_pct DESC
LIMIT 20;

-- @R18
-- Compliance: users without verified KYC who have successfully sent ₹10,000+ in total
SELECT u.user_id, u.full_name, u.kyc_status, sum(t.amount) AS total_sent
FROM users u
JOIN vpas v         ON v.user_id = u.user_id
JOIN transactions t ON t.payer_vpa = v.vpa AND t.status = 'SUCCESS'
WHERE u.kyc_status <> 'VERIFIED'
GROUP BY u.user_id, u.full_name, u.kyc_status
HAVING sum(t.amount) >= 10000
ORDER BY total_sent DESC;

-- @R19
-- Merchant report: last payment time and successful payment count of every verified Bengaluru merchant
-- REWRITTEN: the original runs two correlated subqueries per merchant, and
-- each one was a full Seq Scan of transactions (2 x 239 scans of 250k rows).
-- One LATERAL aggregate per merchant computes both values in a single pass
-- over that merchant's entries in idx_txn_merchant_status_time (Index Only
-- Scan). An aggregate without GROUP BY always returns one row, so merchants
-- with no payments still appear with NULL / 0, exactly as before.
SELECT m.merchant_id, m.merchant_name, s.last_payment_at, s.successful_payments
FROM merchants m
CROSS JOIN LATERAL (
    SELECT max(t.initiated_at) AS last_payment_at,
           count(*) FILTER (WHERE t.status = 'SUCCESS') AS successful_payments
    FROM transactions t
    WHERE t.merchant_id = m.merchant_id
) s
WHERE m.is_verified AND m.city_id = 1
ORDER BY successful_payments DESC;

-- @R20
-- Platform health: daily success rate in June 2026
SELECT initiated_at::date AS day, count(*) AS payments,
       round(100.0 * count(*) FILTER (WHERE status = 'SUCCESS') / count(*), 2) AS success_pct
FROM transactions
-- REWRITTEN: initiated_at::date BETWEEN ... hides the column inside a cast.
-- Same days as a half-open range, so idx_txn_initiated is used:
WHERE initiated_at >= '2026-06-01' AND initiated_at < '2026-07-01'
GROUP BY 1
ORDER BY 1;

-- @R21
-- "Search businesses": merchants with "chai" in their name
SELECT merchant_id, merchant_name, merchant_vpa, city_id
FROM merchants
WHERE merchant_name ILIKE '%chai%'
ORDER BY merchant_name
LIMIT 25;

-- @R22
-- Payment screen: user 15177's primary bank account and all their UPI IDs
SELECT ba.bank_name, ba.account_last4, ba.is_primary, v.vpa, v.is_active
FROM bank_accounts ba
LEFT JOIN vpas v ON v.account_id = ba.account_id
WHERE ba.user_id = 15177
ORDER BY ba.is_primary DESC;

-- @R23
-- Operations console: all transactions, newest first, page 8,001 (25 per page)
-- REWRITTEN: OFFSET 200000 makes the database produce and throw away
-- 200,000 rows to show 25. Keyset pagination instead: the console remembers
-- the initiated_at of the last row on the page it is showing (page 8,000
-- ends at 2025-04-21 00:17:55+05:30) and asks for the next 25 older rows.
-- initiated_at is unique in the data (250,468 distinct values), so this is
-- exactly page 8,001. idx_txn_initiated reads just 25 entries.
SELECT txn_id, upi_ref, txn_type, amount, status, initiated_at
FROM transactions
WHERE initiated_at < '2025-04-21 00:17:55+05:30'
ORDER BY initiated_at DESC
LIMIT 25;

-- @R24
-- Customer support: find a payment by its UPI reference number
SELECT txn_id, payer_vpa, payee_vpa, amount, status, failure_code, initiated_at, completed_at
FROM transactions
WHERE upi_ref = '600977648064';

-- @R25
-- Bank health: average seconds from initiation to completion per payer bank (June 2026)
SELECT ba.bank_name,
       round(avg(EXTRACT(EPOCH FROM (t.completed_at - t.initiated_at))), 2) AS avg_seconds,
       count(*) AS payments
FROM transactions t
JOIN vpas v           ON v.vpa = t.payer_vpa
JOIN bank_accounts ba ON ba.account_id = v.account_id
WHERE t.completed_at IS NOT NULL
  AND t.initiated_at >= '2026-06-01'
GROUP BY ba.bank_name
ORDER BY avg_seconds DESC;

-- @W01
-- Pay: user 15177 starts a ₹250 payment to merchant 2 (PENDING until the bank confirms)
INSERT INTO transactions (txn_id, upi_ref, txn_type, payer_vpa, payee_vpa, merchant_id, amount, initiated_at, status)
VALUES (90000001, '999900000001', 'P2M', 'aditya.gupta15177@okhdfcbank', 'balaji2@okbizaxis', 2, 250.00,
        '2026-07-01 09:00:00+05:30', 'PENDING');

-- @W02
-- Bank callback: mark the oldest PENDING payment as successful
UPDATE transactions
SET status = 'SUCCESS', completed_at = initiated_at + interval '4 seconds'
WHERE txn_id = (SELECT min(txn_id) FROM transactions WHERE status = 'PENDING');

-- @W03
-- Scratch card: user 15177 scratches their oldest unscratched card
UPDATE rewards
SET status = 'CREDITED', credited_at = '2026-07-01 09:05:00+05:30'
WHERE reward_id = (SELECT min(reward_id) FROM rewards WHERE user_id = 15177 AND status = 'UNSCRATCHED');

-- @W04
-- Nightly job (run at 00:00 on 4 Jul 2026): expire every reward whose time is up
UPDATE rewards
SET status = 'EXPIRED'
WHERE status = 'UNSCRATCHED'
  AND expires_at < '2026-07-04 00:00:00+05:30';

-- @W05
-- Nightly job: bills past their due date and still unpaid become OVERDUE
UPDATE bill_payments
SET status = 'OVERDUE'
WHERE status = 'DUE'
  AND due_date < '2026-07-05';

-- @END
ROLLBACK;
