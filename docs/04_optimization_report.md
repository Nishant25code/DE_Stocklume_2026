# 04 · Optimization Report

**Team T0069** · PostgreSQL 17.12 · MacBook Air M4 (Mac16,1), 16 GB RAM · database `gpay`, seed data (250,468 transactions)

**Headline summary:** Total average execution time across all 30 queries dropped from **7,691.784 ms** (baseline) to **551.383 ms** (optimized), a **92.83%** reduction (**13.95×** overall speedup). **R19** dropped from **5,269.993 ms** to **16.458 ms** (**99.69%**, **320.2×**), **R03** dropped from **20.968 ms** to **0.033 ms** (**99.84%**, **635.4×**), **R12** dropped from **23.833 ms** to **0.022 ms** (**99.91%**, **1,083.3×**), and **R13** was fixed from returning `0` rows (wrong due to `NULL` in `NOT IN`) to returning all **450** merchants with zero transactions in **3.125 ms**.

---

## 1. Full 30-Query Optimization Table

> **Note on averages:** Baseline averages are from `docs/03_baseline_timings.md` / `benchmarks/results/baseline/summary.csv` (3 runs each). Optimized averages are from `benchmarks/results/optimized/summary.csv` (5 runs per query via `./benchmarks/run_benchmark.sh gpay optimized 5 sql/06_optimized_queries.sql`).

| Query | Before (ms) | Problem found in the plan | Optimization applied | After (ms) | Improvement | Same result? |
|-------|------------:|---------------------------|----------------------|-----------:|------------:|:------------:|
| R01 | 112.072 | Parallel Seq Scan on `transactions` (`payer_vpa` / `payee_vpa` `OR` subqueries) + Seq Scan on `vpas` | Indexes `idx_vpas_user_id`, `idx_txn_payer_time`, `idx_txn_payee_time`, `idx_txn_initiated_at` | 31.858 | 71.57% (3.5×) | ✅ |
| R02 | 0.778 | PK index scans on `vpas` and `users`; cold-cache Run 1 took 2.139 ms | Warm index access on `vpas_pkey` and `users_pkey` | 0.032 | 95.89% (24.3×) | ✅ |
| R03 | 20.968 | Non-sargable `date(initiated_at)` + Parallel Seq Scan on `transactions` + Seq Scan on `vpas` | Sargable `initiated_at` half-open range + `idx_vpas_user_id` & `idx_txn_payer_time` (Index Only Scan) | 0.033 | 99.84% (635.4×) | ✅ |
| R04 | 10.809 | Seq Scan on `transactions` (250,468 rows) for 125 `PENDING` rows | Partial index `idx_txn_pending_txn_id` on `(txn_id, initiated_at) WHERE status = 'PENDING'` | 0.057 | 99.47% (189.6×) | ✅ |
| R05 | 10.470 | Seq Scan on `transactions` for merchant 2 on `2026-06-29` | Partial composite covering index `idx_txn_merchant_time` on `(merchant_id, initiated_at DESC) INCLUDE (status, amount)` | 0.101 | 99.04% (103.7×) | ✅ |
| R06 | 11.486 | Seq Scan on `transactions` for `2026-06-29` + PK lookup on `merchants` | Covering index `idx_txn_initiated_at` on `(initiated_at) INCLUDE (status, amount, merchant_id)` | 0.471 | 95.90% (24.4×) | ✅ |
| R07 | 15.954 | Seq Scan on `transactions` for `FAILED` rows since `2026-06-24` | Indexes `idx_txn_failed_time`, `idx_txn_initiated_at`, `idx_vpas_user_id`, `idx_vpas_account_id` | 0.956 | 94.01% (16.7×) | ✅ |
| R08 | 391.086 | Seq Scan on `transactions` + external merge sort (6,912 kB disk spill) + `count(DISTINCT)` | Covering/time indexes (`idx_txn_payee_time`, `idx_txn_initiated_at`); still aggregates ~102.7k `P2P` `SUCCESS` rows | 121.620 | 68.90% (3.2×) | ✅ |
| R09 | 1,476.476 | Seq Scan on `transactions` + sort on `(payer_vpa, payee_vpa, initiated_at)` spilling 18,712 kB to disk + `LAG()` window | `idx_txn_payer_time` and `ANALYZE` statistics; still sorts ~232.9k `SUCCESS` rows for `LAG()` | 265.661 | 82.01% (5.6×) | ✅ |
| R10 | 11.363 | Seq Scan on `rewards` (39,799 rows) | Partial index `idx_rewards_unscratched_user_exp` on `(user_id, expires_at, reward_id) WHERE status = 'UNSCRATCHED'` | 0.026 | 99.77% (437.0×) | ✅ |
| R11 | 2.146 | Seq Scan on `rewards` | Partial index `idx_rewards_unscratched_expires` on `(expires_at) WHERE status = 'UNSCRATCHED'` | 0.027 | 98.74% (79.5×) | ✅ |
| R12 | 23.833 | Seq Scan on `bill_payments` (30,000 rows) | Partial index `idx_bills_due_user_date` on `(user_id, due_date) WHERE status = 'DUE'` | 0.022 | 99.91% (1,083.3×) | ✅ |
| R13 | 36.081 | Seq Scan on `merchants` and `transactions`; `NOT IN` with `NULL`s returned **0 rows** (wrong answer) | Rewrote with `NOT EXISTS (...)` + `idx_txn_merchant_time` (now returns all **450** unpaid merchants) | 3.125 | 91.34% (11.5×) | ❌→✅ (fixed `NULL` bug) |
| R14 | 30.727 | Non-sargable `EXTRACT(YEAR FROM t.initiated_at) >= 2025` + Parallel Seq Scan on `transactions` & Seq Scan on `vpas` | Sargable `initiated_at >= TIMESTAMPTZ '2025-01-01 00:00:00+05:30'` + `idx_vpas_user_id` & `idx_txn_payer_time` | 0.098 | 99.68% (313.5×) | ✅ |
| R15 | 11.789 | Seq Scan on `transactions` and `merchants` for June 2026 GMV ranking | Covering index `idx_txn_initiated_at` + `idx_txn_merchant_time` | 3.167 | 73.14% (3.7×) | ✅ |
| R16 | 2.150 | Seq Scan on `disputes` (3,569 rows) + PK lookup on `transactions` | Partial index `idx_disputes_open_raised` on `(raised_at) WHERE status = 'OPEN'` | 0.164 | 92.37% (13.1×) | ✅ |
| R17 | 14.924 | Seq Scan on `transactions` aggregating all `P2M` rows per merchant | `idx_txn_merchant_time` added; still aggregates all `P2M` rows across merchants | 11.171 | 25.15% (1.3×) | ✅ |
| R18 | 35.456 | Parallel Seq Scan on `transactions`, `vpas`, and `users` for unverified KYC users ≥ ₹10,000 | `idx_txn_payer_time` and `idx_vpas_user_id` accelerate transaction lookup | 18.957 | 46.53% (1.9×) | ✅ |
| R19 | 5,269.993 | Seq Scan on `merchants` + 2 correlated subqueries scanning all 250k `transactions` (478 scans, 2,206,484 shared hits) | Rewrote into single `LEFT JOIN` + `GROUP BY` with `FILTER (WHERE t.status = 'SUCCESS')` + `idx_txn_merchant_time` | 16.458 | 99.69% (320.2×) | ✅ |
| R20 | 10.775 | Non-sargable `initiated_at::date BETWEEN '2026-06-01' AND '2026-06-30'` + Parallel Seq Scan | Sargable half-open timestamp range (`>= '2026-06-01 00:00:00+05:30'` and `< '2026-07-01 00:00:00+05:30'`) + `idx_txn_initiated_at` | 2.065 | 80.84% (5.2×) | ✅ |
| R21 | 0.934 | Seq Scan on `merchants` for `ILIKE '%chai%'` | GIN trigram index `idx_merchants_name_trgm` (`gin_trgm_ops`) | 0.244 | 73.88% (3.8×) | ✅ |
| R22 | 7.874 | Seq Scan on `vpas` + full scan of `(account_id, user_id)` index on `bank_accounts` | `idx_ba_user_id` on `(user_id, is_primary DESC)` + `idx_vpas_account_id` on `(account_id)` | 0.035 | 99.56% (225.0×) | ✅ |
| R23 | 100.360 | Seq Scan on `transactions` + full 250,468-row sort spilling 14,256 kB to disk for `OFFSET 200000` | Keyset pagination using `(initiated_at, txn_id)` boundary with `idx_txn_initiated_at` | 58.815 | 41.40% (1.7×) | ✅ |
| R24 | 0.175 | Unique index scan on `transactions_upi_ref_key` (cold Run 1 = 0.435 ms) | Warm index scan on `transactions_upi_ref_key` | 0.029 | 83.43% (6.0×) | ✅ |
| R25 | 28.407 | Parallel Seq Scan on `transactions`, Seq Scan on `vpas` and `bank_accounts` | `idx_txn_initiated_at`, `idx_vpas_account_id`, `idx_ba_user_id` | 13.828 | 51.32% (2.1×) | ✅ |
| W01 | 1.332 | Single-row `INSERT` checking constraints/FKs | Constraint/FK/index maintenance on `INSERT` | 0.785 | 41.07% (1.7×) | ✅ |
| W02 | 41.630 | `Index Scan using transactions_pkey` walking IDs and filtering 249,875 rows to find `min(txn_id)` for `PENDING` | Partial index `idx_txn_pending_txn_id` (`Index Only Scan`, 0–1 heap fetches) | 0.269 | 99.35% (154.8×) | ✅ |
| W03 | 2.013 | Seq Scan on `rewards` to locate oldest `UNSCRATCHED` reward for user 15177 | Partial index `idx_rewards_unscratched_user_exp` | 0.179 | 91.11% (11.2×) | ✅ |
| W04 | 2.984 | Seq Scan on `rewards` for expiring `UNSCRATCHED` rows | Partial index `idx_rewards_unscratched_expires` | 0.265 | 91.12% (11.3×) | ✅ |
| W05 | 6.739 | Seq Scan on `bill_payments` for overdue `DUE` bills | Partial index `idx_bills_due_date` | 0.865 | 87.16% (7.8×) | ✅ |
| **Total** | **7,691.784** | | | **551.383** | **92.83% (13.95×)** | |

---

## 2. Wrong-Result Query (R13) & Result-Equivalence Proof

### Why R13 returned the wrong result in the baseline
In `queries/workload_30.sql`, **R13** uses `WHERE m.merchant_id NOT IN (SELECT t.merchant_id FROM transactions t)`. In SQL three-valued logic, `x NOT IN (...)` expands to `x <> v_1 AND x <> v_2 ...`. Because `transactions.merchant_id` is `NULL` for all `P2P` transactions, `m.merchant_id <> NULL` evaluates to `UNKNOWN`, making the `WHERE` predicate falsy for **every** merchant and returning **0 rows**.

Rewriting R13 using `NOT EXISTS (SELECT 1 FROM transactions t WHERE t.merchant_id = m.merchant_id)` evaluates strictly to `TRUE` or `FALSE`, returning all **450** merchants with zero payments.

### Verification checks run on `gpay`
* `R13_orig_count` (`NOT IN`): `0` rows
* `R13_opt_count` (`NOT EXISTS`): `450` rows
* `R19_diff` (symmetric `EXCEPT` between baseline and optimized R19): `0` differing rows across all 239 verified Bengaluru merchants.

---

## 3. Before / After `EXPLAIN (ANALYZE, BUFFERS)` Plans (Top 5 Improvements)

1. **R19 (`5,269.993 ms` -> `16.458 ms`, 320.2x):** Replaced `Seq Scan on merchants` + 2 correlated `SubPlan` sequential scans on `transactions` (`2,206,484` shared hits, 478 scans) with a single `Hash Right Join` + `HashAggregate` (`4,652` shared hits).
2. **R09 (`1,476.476 ms` -> `265.661 ms`, 5.6x):** `WindowAgg` over `232,909` `SUCCESS` rows (`Sort Method: external merge Disk: 18712kB`) dropped from `949.528 ms` (Run 1) to `265.172 ms` (Run 1) with updated index/planner statistics.
3. **R08 (`391.086 ms` -> `121.620 ms`, 3.2x):** `GroupAggregate` over `102,742` `P2P` `SUCCESS` rows (`Sort Method: external merge Disk: 6912kB`) dropped from `421.085 ms` (Run 1) to `119.636 ms` (Run 1).
4. **R03 (`20.968 ms` -> `0.033 ms`, 635.4x):** Replaced `Parallel Seq Scan` + `date(initiated_at)` (`28.692 ms` Run 1) with `Nested Loop` of `Index Only Scan using idx_vpas_user_id` and `Index Only Scan using idx_txn_payer_time` (`0.038 ms` Run 1, `Heap Fetches: 0`).
5. **W02 (`41.630 ms` -> `0.269 ms`, 154.8x):** Replaced `Index Scan using transactions_pkey` filtering `249,875` rows (`70.514 ms` Run 1) with `Index Only Scan using idx_txn_pending_txn_id` (`0.310 ms` Run 1, `Heap Fetches: 0`).

---

## 4. Write Overhead Analysis (`W01`–`W05`)

None of the five write queries became slower; total write average time fell from **54.698 ms** to **2.363 ms** (**95.68%** faster):
* **W01 (`INSERT` into `transactions`):** `1.332 ms` -> `0.785 ms` (`-41.07%`); warm buffer pool + partial index `idx_txn_pending_txn_id` only indexes `PENDING` rows.
* **W02 (`UPDATE` oldest `PENDING` txn):** `41.630 ms` -> `0.269 ms` (`154.8x` faster) via `idx_txn_pending_txn_id`.
* **W03 (`UPDATE` oldest `UNSCRATCHED` reward):** `2.013 ms` -> `0.179 ms` (`11.2x` faster) via `idx_rewards_unscratched_user_exp`.
* **W04 (`UPDATE` expired `UNSCRATCHED` rewards):** `2.984 ms` -> `0.265 ms` (`11.3x` faster) via `idx_rewards_unscratched_expires`.
* **W05 (`UPDATE` overdue `DUE` bills):** `6.739 ms` -> `0.865 ms` (`7.8x` faster) via `idx_bills_due_date`.

---

## 5. Index Storage (`pg_relation_size`)

The 15 new performance indexes occupy **78,356,480 bytes (~74.73 MB)** total vs. **37,814,272 bytes (36 MB)** for `transactions` (~2.07x table size):
* `idx_txn_payer_time` (`transactions`): **24 MB** (24,748,032 B)
* `idx_txn_payee_time` (`transactions`): **23 MB** (24,608,768 B)
* `idx_txn_initiated_at` (`transactions`): **12 MB** (12,427,264 B)
* `idx_txn_merchant_time` (`transactions`): **6,800 kB** (6,963,200 B)
* `idx_vpas_account_id` & `idx_vpas_user_id` (`vpas`): **2,936 kB** each (vs. 4,224 kB table)
* `idx_ba_user_id` (`bank_accounts`): **2,368 kB** (vs. 4,736 kB table)
* `idx_txn_failed_time` (`transactions`): **728 kB** | `idx_txn_pending_txn_id` (`transactions`): **16 kB**
* `idx_merchants_name_trgm` (`merchants`): **224 kB** (vs. 264 kB table)
* Partial indexes on `bill_payments` (`56 kB`, `32 kB`), `rewards` (`40 kB`, `32 kB`), and `disputes` (`16 kB`).

---

## 6. Queries That Still Scan Large Portions of the Table & Why

* **R08 (`121.620 ms`) & R09 (`265.661 ms`):** Must process ~102,742 `P2P` `SUCCESS` rows (`count(DISTINCT)`) and ~232,909 `SUCCESS` rows (`LAG()` window), spilling `6,912 kB` and `18,712 kB` to external merge sorts when exceeding `work_mem`.
* **R17 (`11.171 ms`), R18 (`18.957 ms`), R25 (`13.828 ms`):** Aggregate across large multi-merchant/monthly slices of `transactions`.
* **R23 (`58.815 ms`):** Keyset boundary CTE still evaluates `OFFSET 200000` once to locate the page cursor; passing the client's last-seen `(initiated_at, txn_id)` directly eliminates that offset walk.
