# 04 · Optimization Report

**Team T0069 · Section D** · Google Pay (UPI) database · PostgreSQL 17.12 · same laptop as the baseline (MacBook Air M4, 16 GB)

## 1. Result in one line

The 30-query workload went from **7,691.784 ms to 237.731 ms** (sum of the 3-run averages), a **96.9 % cut (32× faster)**. We got there with 17 indexes (`sql/05_indexes.sql`) and 8 rewritten queries (`sql/06_optimized_queries.sql`). One rewrite also fixes a query that returned a **wrong answer** (R13). Every other query returns the same rows as before (see §4).

## 2. How we measured

- **Before:** `benchmarks/results/baseline/`, from Phase 3 (no indexes except PK/UNIQUE).
- **After:** `./benchmarks/run_benchmark.sh gpay optimized 3 sql/06_optimized_queries.sql` → `benchmarks/results/optimized/`. That means 3 runs per query with `EXPLAIN (ANALYZE, BUFFERS)`, and writes inside `BEGIN … ROLLBACK`.
- **Same conditions:** same database (`gpay`), same data (row counts unchanged), same laptop, and default server settings throughout (no `work_mem` / `enable_*` changes).
- After creating the indexes we ran `VACUUM ANALYZE` on every table. This gives the planner fresh statistics and sets the visibility map, which Index Only Scans need.
- **Every number below** is copied from `benchmarks/results/*/summary.csv`, and every plan is from the raw `*.txt` files.

## 3. The optimization table (all 30 queries)

The index numbers I1–I17 refer to the comments in `sql/05_indexes.sql`.

| Query | Before (ms) | Problem found in the plan | Optimization applied | After (ms) | Improvement | Same result? |
|-------|------------:|---------------------------|----------------------|-----------:|------------:|:------------:|
| R01 | 112.072 | Parallel Seq Scan of all 250k rows: `payer IN (...) OR payee IN (...)` cannot use one index; vpas scanned for user_id | UNION of a sent half and a received half, each `LIMIT 30`; I1, I2, I7 | 0.457 | 99.6% (245×) | ✅ |
| R02 | 0.778 | Already 2 PK index scans | none (already optimal) | 0.154 | 80.2% (5.1×) | ✅ |
| R03 | 20.968 | Seq Scan on vpas + `DATE(initiated_at)` hides the column | sargable day range; I7 + I1 (Index Scan on payer_vpa, initiated_at) | 0.114 | 99.5% (184×) | ✅ |
| R04 | 10.809 | Seq Scan of 250k rows to find 125 PENDING | partial index I5 on PENDING only | 0.086 | 99.2% (126×) | ✅ |
| R05 | 10.470 | Seq Scan, filter merchant 2 + day | I3 `(merchant_id, status, initiated_at) INCLUDE amount`: Index Only Scan | 0.221 | 97.9% (47×) | ✅ |
| R06 | 11.486 | Seq Scan of 250k rows for one day | I4 on initiated_at (one day = ~460 rows) | 1.858 | 83.8% (6.2×) | ✅ |
| R07 | 15.954 | Seq Scan of 250k rows to find 7 days of failures | I4 range on the last 7 days; vpas / bank_accounts still by key | 3.759 | 76.4% (4.2×) | ✅ |
| R08 | 391.086 | Sort of 102,742 rows on 3 text keys spilled to disk (6.9 MB) | I17 partial covering index; rows arrive ordered by payee_vpa → Incremental Sort in memory | 57.276 | 85.4% (6.8×) | ✅ |
| R09 | 1,476.476 | Sort of 232,909 rows spilled to disk (18.7 MB) for the window | I6 `(payer_vpa, payee_vpa, initiated_at)` WHERE SUCCESS: Index Only Scan in window order, no sort | 63.285 | 95.7% (23×) | ✅ |
| R10 | 11.363 | Seq Scan of 39,799 rewards | partial index I10 on UNSCRATCHED (user_id, expires_at) | 0.027 | 99.8% (421×) | ✅ |
| R11 | 2.146 | Seq Scan of rewards | partial index I11 on UNSCRATCHED (expires_at) | 0.041 | 98.1% (52×) | ✅ |
| R12 | 23.833 | Seq Scan of 30,000 bills | partial index I12 on DUE (user_id, due_date) | 0.038 | 99.8% (627×) | ✅ |
| R13 | 36.081 | **Wrong result (0 rows)**: `NOT IN` with NULL merchant_id; hashed SubPlan over 250k rows | `NOT EXISTS` → Anti Join probing I3 | 6.268 | 82.6% (5.8×) | ❌→✅ fixed (450) |
| R14 | 30.727 | Seq Scan on vpas + `EXTRACT(YEAR ...)` not sargable | range `>= 2025-01-01`; I7 + payer index | 0.230 | 99.3% (134×) | ✅ |
| R15 | 11.789 | Seq Scan of 250k rows for June | I4 range scan on June (~14k rows) | 8.874 | 24.7% (1.3×) | ✅ |
| R16 | 2.150 | Seq Scan of disputes | partial index I14 on OPEN (raised_at) | 0.441 | 79.5% (4.9×) | ✅ |
| R17 | 14.924 | Seq Scan + HashAggregate over all P2M rows | `merchant_id IS NOT NULL` (≡ P2M by CHECK) → Index Only Scan on I3; no real gain, all rows still read (see §9) | 16.988 | -13.8% (0.9×) | ✅ |
| R18 | 35.456 | Seq Scans of users, vpas and transactions + hash joins and aggregate | none effective; planner now probes I6 per VPA but total is the same (see below) | 38.099 | -7.5% (0.9×) | ✅ |
| R19 | 5,269.993 | 2 correlated SubPlans, each a full Seq Scan, × 239 merchants (2.2M buffer hits) | one LATERAL aggregate per merchant on I3 (Index Only Scan) + I16 | 1.570 | 100.0% (3,357×) | ✅ |
| R20 | 10.775 | Seq Scan; `initiated_at::date BETWEEN` not sargable | half-open range on I4 | 3.491 | 67.6% (3.1×) | ✅ |
| R21 | 0.934 | Seq Scan of 3,000 merchants with ILIKE | trigram GIN I15 (Bitmap Index Scan) | 0.635 | 32.0% (1.5×) | ✅ |
| R22 | 7.874 | Seq Scan on vpas (53k) for the join; no index on bank_accounts.user_id | I9 on bank_accounts(user_id), I8 on vpas(account_id) | 0.142 | 98.2% (55×) | ✅ |
| R23 | 100.360 | Sort of all 250k rows (spilled 14 MB) to skip 200,000 | keyset pagination on I4: reads 25 index entries | 0.128 | 99.9% (784×) | ✅ |
| R24 | 0.175 | Already unique index on upi_ref | none (already optimal) | 0.141 | 19.4% (1.2×) | ✅ |
| R25 | 28.407 | Seq Scan of transactions + hash of vpas and bank_accounts | I4 range on June; hash of vpas / bank_accounts remains (see below) | 25.903 | 8.8% (1.1×) | ✅ |
| W01 | 1.332 | Insert; 7 more transactions indexes to maintain | (cost of the new indexes, see write overhead) | 0.929 | 30.3% (1.4×) | — |
| W02 | 41.630 | `min(txn_id) WHERE PENDING` = Seq Scan of 250k rows | I5 partial index answers it (Index Only Scan) | 0.659 | 98.4% (63×) | — |
| W03 | 2.013 | Seq Scan of rewards for the user's oldest card | I10 | 0.670 | 66.7% (3.0×) | — |
| W04 | 2.984 | Seq Scan of rewards | I11 finds the 51 expiring cards | 1.266 | 57.6% (2.4×) | — |
| W05 | 6.739 | Seq Scan of 30,000 bills | I13 partial on DUE | 3.981 | 40.9% (1.7×) | — |
| **Total** | **7,691.784** | | | **237.731** | **96.9% (32×)** | |

**Reading the table:**

- **Big wins came from the 25 READ queries.** 20 of them now run in under 10 ms. The 11 real-time queries (R01–R04, R10, R12, R22, R24, W01–W03) all run under 1 ms here, well inside the 5 ms target.
- **R02 and R24** were already index lookups (PK / UNIQUE). Their small differences are run-to-run noise on sub-millisecond queries.
- **W01** looks faster, but a single-row insert under 1.5 ms is dominated by noise. Its real cost is measured properly in §6.

## 4. Proof that the results did not change

**Method:** we saved every READ query's output on the database *before* adding any index (original query). We then compared it with the output of the optimized query *after* the indexes, comparing:

- the row count;
- an MD5 of the **sorted** rows (same set of rows);
- an MD5 of the rows **in output order** (same order).

Script: run each query with `psql -A -t`, then `sort | md5` and `md5`.

| Query | Rows before | Rows after | MD5 of sorted rows (before → after) | MD5 in output order (before → after) | Same? |
|-------|-----:|-----:|---------------------|------------------|:----:|
| R01 (rewritten) | 14 | 14 | 64b764b332ad → 64b764b332ad | 9b6759da852a → 9b6759da852a | ✅ identical |
| R03 (rewritten) | 1 | 1 | 897316929176 → 897316929176 | 897316929176 → 897316929176 | ✅ identical |
| R14 (rewritten) | 3 | 3 | fa603d906386 → fa603d906386 | fa603d906386 → fa603d906386 | ✅ identical |
| R17 (rewritten) | 20 | 20 | 0ceac453a935 → 0ceac453a935 | ef6ac3ee7a25 → eb4cb92a1938 | ✅ same rows, same `refund_pct` order (see note) |
| R19 (rewritten) | 239 | 239 | 4162bcbb4aee → 4162bcbb4aee | 7428dff6f763 → 7428dff6f763 | ✅ identical |
| R20 (rewritten) | 30 | 30 | d3cbdbb6e616 → d3cbdbb6e616 | d3cbdbb6e616 → d3cbdbb6e616 | ✅ identical |
| R23 (rewritten) | 25 | 25 | 20780c7614ab → 20780c7614ab | 32f09b4ab0a3 → 32f09b4ab0a3 | ✅ identical |
| R13 (rewritten, bug fix) | **0** | **450** | d41d8cd98f00 → 681f0856a885 | — | ❌ → ✅ fixed on purpose (§5) |

**The 17 queries we did not rewrite** (R02, R04–R12, R15, R16, R18, R21, R22, R24, R25) were also re-run after the indexes. All of them return the same set of rows; for example, R08 is 13 rows with sorted MD5 39a87b8bd832 before and after.

**Note on ties (R06 and R17):** these queries sort on a value that has ties.

- **R06** sorts by `settle_amount`, and several merchants share the same total.
- **R17** sorts by `refund_pct`, where for example four merchants have 6.67 %.

The original queries never said how to order tied rows, so with an index PostgreSQL returns them in a different but equally valid order. We checked that the sort column comes out in exactly the same sequence (`cut` the sort column and `diff`: no difference).

R17 also has a tie at the `LIMIT 20` cut-off: six merchants have 5.71 % and only one of them fits. The original query can therefore legally return any of the six. Both versions happen to return the same merchant. Adding `merchant_id` as a tie-breaker would make it deterministic, but we kept the original semantics.

## 5. The wrong-answer query: R13 (`NOT IN` and NULL)

```sql
-- original: returns 0 rows
WHERE m.merchant_id NOT IN (SELECT t.merchant_id FROM transactions t);
```

**Why it is wrong:**

- 110,581 P2P payments have `merchant_id = NULL`, so the subquery's list contains NULL.
- `x NOT IN (a, b, NULL)` means `x<>a AND x<>b AND x<>NULL`.
- `x<>NULL` is **UNKNOWN**, never TRUE, so the whole condition is never TRUE and every merchant is filtered out.

The baseline plan shows it: `Rows Removed by Filter: 3000`, `rows=0`. The merchant success team gets an empty call list, even though 450 merchants have never been paid.

**Fix:**

```sql
WHERE NOT EXISTS (SELECT 1 FROM transactions t WHERE t.merchant_id = m.merchant_id);
```

`NOT EXISTS` asks "is there a matching row?", and NULLs simply never match. It returns **450 merchants**.

**Cross-check:** `SELECT count(*) FROM merchants WHERE merchant_id NOT IN (SELECT merchant_id FROM transactions WHERE merchant_id IS NOT NULL)` also gives 450.

**Speed:** the new form is a `Nested Loop Anti Join` that probes I3 once per merchant. It went from 36.081 ms to 6.268 ms.

## 6. Before / after plans: the 5 biggest improvements

Each block shows **run 3** of each query, copied from the raw files (Buffers/Planning lines removed for space).

### 6.1 R19 Bengaluru merchant report: 5,269.993 → 1.570 ms (99.97 %, 3,357×)

**Problem:**

- Two correlated subqueries ran once per merchant, and each one was a full Seq Scan of `transactions`.
- 239 merchants × 2 scans × 250,468 rows ≈ 120 million rows read.

**Before** (`baseline/R19.txt`):
```
Sort  (cost=3917277.79..3917278.40 rows=243 width=39) (actual time=5350.790..5350.796 rows=239 loops=1)
  Sort Key: ((SubPlan 2)) DESC
  Sort Method: quicksort  Memory: 38kB
  ->  Seq Scan on merchants m  (cost=0.00..3917268.17 rows=243 width=39) (actual time=24.894..5350.521 rows=239 loops=1)
        Filter: (is_verified AND (city_id = 1))
        Rows Removed by Filter: 2761
        SubPlan 1
          ->  Aggregate  (cost=7746.99..7747.00 rows=1 width=8) (actual time=9.310..9.310 rows=1 loops=239)
                ->  Seq Scan on transactions t  (cost=0.00..7746.85 rows=55 width=8) (actual time=1.314..9.299 rows=58 loops=239)
                      Filter: (merchant_id = m.merchant_id)
                      Rows Removed by Filter: 250410
        SubPlan 2
          ->  Aggregate  (cost=8373.15..8373.16 rows=1 width=8) (actual time=13.071..13.071 rows=1 loops=239)
                ->  Seq Scan on transactions t_1  (cost=0.00..8373.02 rows=51 width=0) (actual time=1.870..13.062 rows=54 loops=239)
                      Filter: ((merchant_id = m.merchant_id) AND ((status)::text = 'SUCCESS'::text))
                      Rows Removed by Filter: 250414
Execution Time: 5350.839 ms
```

**After** (`optimized/R19.txt`):

- One `LATERAL` aggregate per merchant computes both `max(initiated_at)` and the SUCCESS count.
- It reads only that merchant's ~58 entries in I3 (Index Only Scan), and I16 finds the 239 merchants.

```
Sort  (cost=2436.87..2437.48 rows=243 width=39) (actual time=1.547..1.552 rows=239 loops=1)
  Sort Key: (count(*) FILTER (WHERE ((t.status)::text = 'SUCCESS'::text))) DESC
  Sort Method: quicksort  Memory: 38kB
  ->  Nested Loop  (cost=15.96..2427.24 rows=243 width=39) (actual time=0.116..1.512 rows=239 loops=1)
        ->  Bitmap Heap Scan on merchants m  (cost=6.16..42.20 rows=243 width=23) (actual time=0.018..0.056 rows=239 loops=1)
              Recheck Cond: ((city_id = 1) AND is_verified)
              Heap Blocks: exact=33
              ->  Bitmap Index Scan on idx_merchants_city_verified  (cost=0.00..6.10 rows=243 width=0) (actual time=0.012..0.012 rows=239 loops=1)
                    Index Cond: (city_id = 1)
        ->  Aggregate  (cost=9.79..9.80 rows=1 width=16) (actual time=0.006..0.006 rows=1 loops=239)
              ->  Index Only Scan using idx_txn_merchant_status_time on transactions t  (cost=0.42..9.38 rows=55 width=15) (actual time=0.002..0.004 rows=58 loops=239)
                    Index Cond: (merchant_id = m.merchant_id)
                    Heap Fetches: 2
Execution Time: 1.585 ms
```

### 6.2 R09 duplicate payments: 1,476.476 → 63.285 ms (95.7 %, 23×)

**Problem:** the window `PARTITION BY payer_vpa, payee_vpa ORDER BY initiated_at` needs all 232,909 SUCCESS rows sorted on three columns. The sort spilled to disk (`external merge Disk: 18712kB`).

**Run 3 before** was the slowest (2,553 ms). Runs 1–2 were about 940 ms; see `03_baseline_timings.md`.

```
Sort  (cost=56855.74..57049.95 rows=77684 width=83) (actual time=2545.524..2545.543 rows=468 loops=1)
  Sort Key: t.initiated_at DESC
  Sort Method: quicksort  Memory: 72kB
  ->  Subquery Scan on t  (cost=38085.80..46825.23 rows=77684 width=83) (actual time=2337.369..2545.444 rows=468 loops=1)
        Filter: (t.gap < '00:10:00'::interval)
        Rows Removed by Filter: 232441
        ->  WindowAgg  (cost=38085.80..43912.08 rows=233052 width=83) (actual time=2337.001..2540.479 rows=232909 loops=1)
              ->  Sort  (cost=38085.78..38668.41 rows=233052 width=67) (actual time=2315.944..2478.150 rows=232909 loops=1)
                    Sort Key: transactions.payer_vpa, transactions.payee_vpa, transactions.initiated_at
                    Sort Method: external merge  Disk: 18712kB
                    ->  Seq Scan on transactions  (cost=0.00..7746.85 rows=233052 width=67) (actual time=0.007..26.549 rows=232909 loops=1)
                          Filter: ((status)::text = 'SUCCESS'::text)
                          Rows Removed by Filter: 17559
Execution Time: 2553.546 ms
```

**After:**

- I6 stores exactly those rows (partial `WHERE status='SUCCESS'`) in exactly the window's order.
- The Sort node is gone and the WindowAgg reads the index directly (Index Only Scan, 20 heap fetches).
- The query is unchanged; only the index was added.

```
Sort  (cost=33001.55..33196.04 rows=77795 width=83) (actual time=62.043..62.057 rows=468 loops=1)
  Sort Key: t.initiated_at DESC
  Sort Method: quicksort  Memory: 72kB
  ->  Subquery Scan on t  (cost=0.50..22957.72 rows=77795 width=83) (actual time=0.132..61.971 rows=468 loops=1)
        Filter: (t.gap < '00:10:00'::interval)
        Rows Removed by Filter: 232441
        ->  WindowAgg  (cost=0.50..20040.39 rows=233386 width=83) (actual time=0.030..57.286 rows=232909 loops=1)
              ->  Index Only Scan using idx_txn_success_pair_time on transactions  (cost=0.42..14789.21 rows=233386 width=67) (actual time=0.026..10.405 rows=232909 loops=1)
                    Heap Fetches: 20
Execution Time: 62.085 ms
```

### 6.3 R08 mule detection: 391.086 → 57.276 ms (85.4 %, 6.8×)

**Problem:** `count(DISTINCT payer_vpa) … GROUP BY payee_vpa, day` sorts 102,742 rows on three text keys. That sort spilled 6.9 MB to disk.

```
Sort  (cost=26429.57..26516.29 rows=34689 width=65) (actual time=375.833..375.833 rows=13 loops=1)
  Sort Key: (count(DISTINCT payer_vpa)) DESC
  Sort Method: quicksort  Memory: 25kB
  ->  GroupAggregate  (cost=20865.10..23813.64 rows=34689 width=65) (actual time=343.585..375.827 rows=13 loops=1)
        Group Key: payee_vpa, ((initiated_at)::date)
        Filter: (count(DISTINCT payer_vpa) >= 5)
        Rows Removed by Filter: 102266
        ->  Sort  (cost=20865.10..21125.26 rows=104066 width=55) (actual time=322.794..355.769 rows=102742 loops=1)
              Sort Key: payee_vpa, ((initiated_at)::date), payer_vpa
              Sort Method: external merge  Disk: 6912kB
              ->  Seq Scan on transactions  (cost=0.00..8633.19 rows=104066 width=55) (actual time=0.010..24.488 rows=102742 loops=1)
                    Filter: (((txn_type)::text = 'P2P'::text) AND ((status)::text = 'SUCCESS'::text))
                    Rows Removed by Filter: 147726
Execution Time: 382.232 ms
```

**After:**

- I17 (partial on `txn_type='P2P' AND status='SUCCESS'`, ordered by `payee_vpa`) delivers the rows already grouped by payee.
- PostgreSQL then uses an **Incremental Sort** (`Presorted Key: payee_vpa`): 3,119 tiny in-memory sorts of about 28 kB instead of one big sort on disk.
- The query is unchanged.

```
Sort  (cost=14739.05..14825.37 rows=34528 width=65) (actual time=51.862..51.863 rows=13 loops=1)
  Sort Key: (count(DISTINCT payer_vpa)) DESC
  Sort Method: quicksort  Memory: 25kB
  ->  GroupAggregate  (cost=0.79..12136.42 rows=34528 width=65) (actual time=20.914..51.855 rows=13 loops=1)
        Group Key: payee_vpa, ((initiated_at)::date)
        Filter: (count(DISTINCT payer_vpa) >= 5)
        Rows Removed by Filter: 102266
        ->  Incremental Sort  (cost=0.79..9460.47 rows=103585 width=55) (actual time=0.055..30.394 rows=102742 loops=1)
              Sort Key: payee_vpa, ((initiated_at)::date), payer_vpa
              Presorted Key: payee_vpa
              Full-sort Groups: 3119  Sort Method: quicksort  Average Memory: 28kB  Peak Memory: 28kB
              ->  Index Only Scan using idx_txn_p2p_success_payee on transactions  (cost=0.42..6549.15 rows=103585 width=55) (actual time=0.029..9.992 rows=102742 loops=1)
                    Heap Fetches: 8
Execution Time: 51.884 ms
```

### 6.4 R01 transaction history: 112.072 → 0.457 ms (99.6 %, 245×)

**Problem:**

- `payer_vpa IN (…) OR payee_vpa IN (…)` cannot be answered by one index, so the plan is a Parallel Seq Scan of all 250k rows, followed by a sort.
- It also Seq Scans `vpas` to find the user's VPAs.
- The baseline average of 112 ms includes a cold first run (268.304 ms); run 3 below took 29.7 ms.

```
Limit  (cost=11882.47..11885.97 rows=30 width=87) (actual time=25.522..29.669 rows=14 loops=1)
  ->  Gather Merge  (cost=11882.47..30146.98 rows=156542 width=87) (actual time=25.521..29.667 rows=14 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        ->  Sort  (cost=10882.45..11078.12 rows=78271 width=87) (actual time=23.372..23.373 rows=5 loops=3)
              Sort Key: t.initiated_at DESC
              Sort Method: quicksort  Memory: 25kB
              Worker 0:  Sort Method: quicksort  Memory: 25kB
              Worker 1:  Sort Method: quicksort  Memory: 25kB
              ->  Parallel Seq Scan on transactions t  (cost=2389.33..8570.76 rows=78271 width=87) (actual time=7.010..23.355 rows=5 loops=3)
                    Filter: ((ANY ((payer_vpa)::text = ((hashed SubPlan 1).col1)::text)) OR (ANY ((payee_vpa)::text = ((hashed SubPlan 2).col1)::text)))
                    Rows Removed by Filter: 83485
                    SubPlan 1
                      ->  Seq Scan on vpas  (cost=0.00..1194.66 rows=1 width=24) (actual time=0.161..2.389 rows=2 loops=3)
                            Filter: (user_id = 15177)
                            Rows Removed by Filter: 53331
                    SubPlan 2
                      ->  Seq Scan on vpas vpas_1  (cost=0.00..1194.66 rows=1 width=24) (actual time=0.097..2.186 rows=2 loops=3)
                            Filter: (user_id = 15177)
                            Rows Removed by Filter: 53331
Execution Time: 29.716 ms
```

**After:**

- The rewrite splits the query into a "sent" half and a "received" half.
- Each half finds the user's 2 VPAs with I7 (Index Only Scan), then reads only that VPA's rows through I1 / I2. Each half is limited to 30 rows.
- `UNION` merges the halves and removes any payment that appears in both, i.e. a payment between two of the user's own VPAs. The original's `OR` lists such a payment once, so the results are the same; `UNION ALL` would have listed it twice.

```
Limit  (cost=92.35..92.37 rows=10 width=548) (actual time=0.314..0.320 rows=14 loops=1)
  ->  Sort  (cost=92.35..92.37 rows=10 width=548) (actual time=0.313..0.317 rows=14 loops=1)
        Sort Key: t.initiated_at DESC
        Sort Method: quicksort  Memory: 26kB
        ->  Unique  (cost=91.98..92.18 rows=10 width=548) (actual time=0.284..0.294 rows=14 loops=1)
              ->  Sort  (cost=91.98..92.01 rows=10 width=548) (actual time=0.282..0.286 rows=14 loops=1)
                    Sort Key: t.txn_id, t.upi_ref, t.payer_vpa, t.payee_vpa, t.amount, t.status, t.initiated_at
                    Sort Method: quicksort  Memory: 26kB
                    ->  Append  (cost=36.30..91.82 rows=10 width=548) (actual time=0.152..0.256 rows=14 loops=1)
                          ->  Limit  (cost=36.30..36.32 rows=5 width=87) (actual time=0.151..0.154 rows=11 loops=1)
                                ->  Sort  (cost=36.30..36.32 rows=5 width=87) (actual time=0.150..0.152 rows=11 loops=1)
                                      Sort Key: t.initiated_at DESC
                                      Sort Method: quicksort  Memory: 26kB
                                      ->  Nested Loop  (cost=4.89..36.25 rows=5 width=87) (actual time=0.081..0.133 rows=11 loops=1)
                                            ->  Index Only Scan using idx_vpas_user on vpas v  (cost=0.41..4.43 rows=1 width=24) (actual time=0.018..0.019 rows=2 loops=1)
                                                  Index Cond: (user_id = 15177)
                                                  Heap Fetches: 0
                                            ->  Bitmap Heap Scan on transactions t  (cost=4.47..31.74 rows=7 width=87) (actual time=0.029..0.053 rows=6 loops=2)
                                                  Recheck Cond: ((v.vpa)::text = (payer_vpa)::text)
                                                  Heap Blocks: exact=11
                                                  ->  Bitmap Index Scan on idx_txn_payer_time  (cost=0.00..4.47 rows=7 width=0) (actual time=0.021..0.021 rows=6 loops=2)
                                                        Index Cond: ((payer_vpa)::text = (v.vpa)::text)
                          ->  Limit  (cost=55.44..55.45 rows=5 width=87) (actual time=0.097..0.099 rows=3 loops=1)
                                ->  Sort  (cost=55.44..55.45 rows=5 width=87) (actual time=0.097..0.098 rows=3 loops=1)
                                      Sort Key: t_1.initiated_at DESC
                                      Sort Method: quicksort  Memory: 25kB
                                      ->  Nested Loop  (cost=4.93..55.38 rows=5 width=87) (actual time=0.079..0.087 rows=3 loops=1)
                                            ->  Index Only Scan using idx_vpas_user on vpas v_1  (cost=0.41..4.43 rows=1 width=24) (actual time=0.021..0.021 rows=2 loops=1)
                                                  Index Cond: (user_id = 15177)
                                                  Heap Fetches: 0
                                            ->  Bitmap Heap Scan on transactions t_1  (cost=4.51..50.83 rows=12 width=87) (actual time=0.027..0.030 rows=2 loops=2)
                                                  Recheck Cond: ((v_1.vpa)::text = (payee_vpa)::text)
                                                  Heap Blocks: exact=3
                                                  ->  Bitmap Index Scan on idx_txn_payee_time  (cost=0.00..4.51 rows=12 width=0) (actual time=0.022..0.022 rows=2 loops=2)
                                                        Index Cond: ((payee_vpa)::text = (v_1.vpa)::text)
Execution Time: 0.451 ms
```

### 6.5 R23 operations console, page 8,001: 100.360 → 0.128 ms (99.9 %, 784×)

**Problem:** `OFFSET 200000` makes PostgreSQL sort the whole table (spilled 14 MB) and throw away 200,000 rows to show 25.

```
Limit  (cost=37787.48..37787.54 rows=25 width=46) (actual time=86.913..86.916 rows=25 loops=1)
  ->  Sort  (cost=37287.48..37913.65 rows=250468 width=46) (actual time=76.277..83.405 rows=200025 loops=1)
        Sort Key: initiated_at DESC
        Sort Method: external merge  Disk: 14256kB
        ->  Seq Scan on transactions  (cost=0.00..7120.68 rows=250468 width=46) (actual time=0.017..18.446 rows=250468 loops=1)
Execution Time: 93.012 ms
```

**After: keyset pagination.**

- The console remembers the `initiated_at` of the last row it showed. Page 8,000 ends at `2025-04-21 00:17:55+05:30`.
- It then asks for `initiated_at < that value ORDER BY initiated_at DESC LIMIT 25`, and I4 reads just 25 entries backwards.
- `initiated_at` is unique in this data (250,468 distinct values for 250,468 rows), so this is exactly the same page.
- With ties possible in production, we would page on `(initiated_at, txn_id)` instead.
- **Trade-off:** the console can go to the *next* page instantly, but cannot jump straight to "page 8,001" without knowing where page 8,000 ended.

```
Limit  (cost=0.42..1.68 rows=25 width=46) (actual time=0.046..0.057 rows=25 loops=1)
  ->  Index Scan Backward using idx_txn_initiated on transactions  (cost=0.42..2547.51 rows=50372 width=46) (actual time=0.045..0.053 rows=25 loops=1)
        Index Cond: (initiated_at < '2025-04-21 00:17:55+05:30'::timestamp with time zone)
Execution Time: 0.097 ms
```

## 7. Write overhead

Every index on `transactions` has to be updated on every new payment. We added 7 indexes to that table: I1–I6 and I17.

**Single-statement writes in the workload:**

| Write | Before (ms) | After (ms) | Why |
|-------|------------:|-----------:|-----|
| W01 insert 1 payment | 1.332 | 0.929 | 7 extra index entries; too small to measure in 3 runs (noise ±0.5 ms) |
| W02 bank callback | 41.630 | 0.659 | Faster: `min(txn_id) WHERE status='PENDING'` was a Seq Scan, now uses I5 |
| W03 scratch card | 2.013 | 0.670 | Faster: finds the user's card through I10 |
| W04 expire rewards | 2.984 | 1.266 | Faster: I11 finds the 51 cards, even though it must also update I10 and I11 |
| W05 bills overdue | 6.739 | 3.981 | Faster: I13 finds the DUE rows; updated rows leave I12/I13 because they stop being DUE |

Single inserts are too fast to show the cost, so we measured it with a **bulk insert of 10,000 payments** (copies of existing rows with new ids, inside `BEGIN … ROLLBACK`). We ran it 3 times with all indexes, and 3 times with the 7 new `transactions` indexes dropped inside the same transaction. `DROP INDEX` is transactional, so nothing was really dropped.

Raw output: `benchmarks/results/optimized/write_overhead_bulk_insert.txt`.

| 10,000-row insert | Run 1 | Run 2 | Run 3 | Average | Per payment |
|-------------------|------:|------:|------:|--------:|------------:|
| Without the 7 new indexes | 142.105 | 167.223 | 168.708 | 159.345 ms | 15.9 µs |
| With the 7 new indexes | 361.554 | 320.201 | 361.349 | 347.701 ms | 34.8 µs |

**Inserts became about 2.2× slower**: +18.8 µs per payment, 118 % more time.

**Is it acceptable? Yes:**

- An insert still costs about 0.035 ms, against a 5 ms target for the payment path (W01).
- At 20× volume, about 5 M payments over 18 months is roughly 0.1 payment per second on average. Even a peak of 1,000 payments/s would spend only about 35 ms per second on index maintenance.
- In exchange, the queries that run on every app open (R01, R03) and every bank callback (W02) are 100–1,000× faster.

**The 3 widest indexes (I1, I2, I6) are where we would cut first** if write speed ever mattered more. I6 serves only R09, a batch risk report, and is the biggest (21.6 MB), so it is the first one we would drop.

## 8. Index storage

`pg_relation_size` of each new index, measured after `VACUUM` + `REINDEX`:

| # | Index | Table | Index size | Table size | Index ÷ table |
|---|-------|-------|-----------:|-----------:|--------------:|
| I1 | `idx_txn_payer_time` | transactions | 12.8 MB | 35.6 MB | 36.0% |
| I2 | `idx_txn_payee_time` | transactions | 12.1 MB | 35.6 MB | 34.0% |
| I3 | `idx_txn_merchant_status_time` | transactions | 6.6 MB | 35.6 MB | 18.7% |
| I4 | `idx_txn_initiated` | transactions | 5.4 MB | 35.6 MB | 15.1% |
| I5 | `idx_txn_pending` | transactions | 16 kB | 35.6 MB | 0.0% |
| I6 | `idx_txn_success_pair_time` | transactions | 21.6 MB | 35.6 MB | 60.7% |
| I7 | `idx_vpas_user` | vpas | 2.6 MB | 3.9 MB | 65.6% |
| I8 | `idx_vpas_account` | vpas | 1.2 MB | 3.9 MB | 29.4% |
| I9 | `idx_ba_user` | bank_accounts | 1.1 MB | 4.5 MB | 24.3% |
| I10 | `idx_rw_unscratched_user` | rewards | 48 kB | 3.9 MB | 1.2% |
| I11 | `idx_rw_unscratched_expiry` | rewards | 32 kB | 3.9 MB | 0.8% |
| I12 | `idx_bill_due_user` | bill_payments | 56 kB | 2.9 MB | 1.9% |
| I13 | `idx_bill_due_date` | bill_payments | 32 kB | 2.9 MB | 1.1% |
| I14 | `idx_dsp_open_raised` | disputes | 16 kB | 368 kB | 4.3% |
| I15 | `idx_merchants_name_trgm` | merchants | 224 kB | 264 kB | 84.8% |
| I16 | `idx_merchants_city_verified` | merchants | 32 kB | 264 kB | 12.1% |
| I17 | `idx_txn_p2p_success_payee` | transactions | 8.8 MB | 35.6 MB | 24.8% |

| Table | Table size | New indexes, total | Ratio |
|-------|-----------:|-------------------:|------:|
| transactions | 35.6 MB | 67.5 MB | 189% |
| vpas | 3.9 MB | 3.7 MB | 95% |
| bank_accounts | 4.5 MB | 1.1 MB | 24% |
| merchants | 264 kB | 256 kB | 97% |
| bill_payments | 2.9 MB | 88 kB | 3% |
| rewards | 3.9 MB | 80 kB | 2% |
| disputes | 368 kB | 16 kB | 4% |
| **All 7 tables** | **51.5 MB** | **72.7 MB** | **141%** |

**What this shows:**

- **Partial indexes cost almost nothing.** I5, I10–I14 together are under 200 kB, because they index only the rare status their query needs: 125 PENDING, 502 UNSCRATCHED, 1,508 DUE and 116 OPEN rows.
- **Text keys make indexes big.** I1, I2, I6 and I17 store VPAs (about 25-byte strings), which is why `transactions` indexes are 1.9× the table.
- **A partial index can still be large.** I6 is the largest even though it is partial, because it covers 93 % of the table (all SUCCESS payments) with two VPAs per entry.
- **Partial filters do save space when they cut rows.** I3 leaves out the 110,581 P2P rows, and I17 keeps only P2P + SUCCESS.

## 9. Queries we could not speed up (much), and why

| Query | Before → after (ms) | Why it stays about the same |
|-------|---------------------|----------------------------|
| **R18** compliance: non-KYC users who sent ₹10,000+ | 35.456 → 38.099 | See below |
| **R25** bank latency per payer bank (June) | 28.407 → 25.903 | See below |
| **R17** merchant refund rate | 14.924 → 16.988 | See below |
| **R09, R08** | 1,476.476 → 63.285, 391.086 → 57.276 | See below |
| **R02, R24** | 0.778 → 0.154, 0.175 → 0.141 | Already a single unique-index lookup in the baseline. Nothing left to remove. |

**R18:**

- It must add up **every** successful payment of the 3,924 non-VERIFIED users: 5,237 VPAs and about 21k payments, grouped per user.
- We tried two rewrites:
  - aggregate per `payer_vpa` first, then join: 34–42 ms;
  - a `LATERAL` sum per user over I7 + I6: 34–62 ms.
- Neither beat the original, so we kept the original query.
- The ~3 ms difference is within run-to-run noise (baseline runs: 54.4 / 26.8 / 25.3 ms).
- A real fix would be a summary table of "total sent per user", refreshed nightly. That is acceptable for a compliance report, which is already far under its 5 s target.

**R25:**

- The June range now uses I4 (13,639 rows instead of 250,468).
- But each payment still needs its payer's bank, and for 13.6k payments a hash join over all 53,333 VPAs and 53,333 bank accounts is the cheapest plan. Most of the remaining time is building those two hash tables.
- The bank name cannot be taken from the VPA handle instead, because handles do not match banks in this data (D5 in `02_schema_design.md`).

**R17:**

- It groups **all** 139,887 P2M payments by merchant, so every row must be read whatever we do.
- Our rewrite (`merchant_id IS NOT NULL` instead of `txn_type = 'P2M'`, which select the same rows because of CHECK `chk_txn_p2m_merchant`) turns it into an Index Only Scan on I3 that is already in merchant order.
- That removes the table access and the hash, but reading 139,887 index entries costs about the same as the Seq Scan and HashAggregate did. The difference (14.924 vs 16.988 ms) is run-to-run noise: the runs were 13.9–16.0 ms before and 14.2–21.6 ms after.
- We kept the rewrite because it does not need the table at all. On the 20× data that should matter more, and we will check it in Phase 5.

**R09 and R08:**

- These are big wins, but they will never be "instant", because they **must read most of the table**:
  - R09 looks at all 232,909 SUCCESS payments;
  - R08 at all 102,742 P2P successes.
- The indexes removed the big sort, but the rows still have to be read.
- At 20× they will grow linearly. They are reports, with a 5 s target.

## 10. What we changed, in short

| Technique (from the brief) | Where we used it |
|----------------------------|------------------|
| Composite B-tree, equality columns first | I1, I2, I3, I6, I10, I12 |
| Partial index | I3, I5, I6, I10–I14, I16, I17 |
| Covering index (`INCLUDE`) → Index Only Scan | I3, I5, I6, I7, I10, I11, I17 |
| GIN + `pg_trgm` | I15 for `ILIKE '%chai%'` (R21: 0.934 → 0.635 ms) |
| Sargable ranges instead of functions on the column | R03 (`DATE()`), R14 (`EXTRACT`), R20 (`::date`) |
| `NOT EXISTS` instead of `NOT IN` | R13 (also fixes the wrong answer) |
| Join / LATERAL instead of correlated subqueries | R19 |
| Keyset instead of `OFFSET` | R23 |
| Split an `OR` across two columns into a `UNION` | R01 |
| Use a CHECK-guaranteed equivalent predicate to match a partial index | R17 (`txn_type='P2M'` ⇔ `merchant_id IS NOT NULL`) |
| `VACUUM ANALYZE` | after building the indexes (end of `05_indexes.sql`) |

**Not used:**

- **BRIN:** at 250k rows, B-tree I4 is better. We will compare BRIN on `initiated_at` at 20× in Phase 5, where its tiny size matters.
- **Materialized views:** every query met its target without one.
