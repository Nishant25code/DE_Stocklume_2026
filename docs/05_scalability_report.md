# 05 · Scalability Report

**Team T0069 · Section D** · Google Pay (UPI) database

> **Machines used.** The seed results (Phases 3 and 4) were measured on a MacBook Air M4, 16 GB, with PostgreSQL 17.12. The large-data run (`benchmarks/results/large/`) was made by Cellina on her own laptop with **PostgreSQL 18**: its plans print fractional row counts (`rows=1.00`) and `Index Searches:` lines, which only PostgreSQL 18 shows. Growth ratios below therefore compare two machines, so small differences (under about 2×) are within machine-to-machine noise.

> **Status (25 Nov 2026).** The large-data round is done: `gpay_large`, 5,009,360 transactions, optimized queries only.
>
> - **Done:** the results table (section 1), growth analysis (2), what broke at scale (3), the design part (5) and the conclusion (6). All timings come from `benchmarks/results/large/summary.csv` and `benchmarks/results/optimized/summary.csv`; plan details come from the raw files in `benchmarks/results/large/` and `benchmarks/results/optimized/`.
> - **Result:** all 30 queries meet their target on the large data (section 1).
> - **Not measured:** the storage sizes of the large database (section 4). The committed results do not contain them; section 4 gives the SQL to measure them.

## 0. How the large-data round was run

These are the steps from README section 5.1, with our files:

```bash
createdb gpay_large
psql -d gpay_large -f sql/01_schema.sql
# sql/02_load_data.sql with the folder name changed: seed_data/ → large_data/
psql -d gpay_large -f sql/02_load_data.sql
psql -d gpay_large -f sql/05_indexes.sql          # ends with VACUUM ANALYZE
./benchmarks/run_benchmark.sh gpay_large large 3 sql/06_optimized_queries.sql
```

- We run **only** the optimized queries on the large data, never the original 30.
- **R23 keyset value.** The page is "page 8,001, newest first", so the "last seen" value is the `initiated_at` of the 200,000th newest row. On the large data we find it once with:
  ```sql
  SELECT initiated_at FROM transactions ORDER BY initiated_at DESC OFFSET 199999 LIMIT 1;
  ```
  We put that value into R23. We also check that `initiated_at` is still unique in the large data. If it is not, we page on `(initiated_at, txn_id)`.
- **What the committed files show for R23.** `benchmarks/results/large/R23.txt` uses `initiated_at < '2026-06-09 04:53:17+05:30'`, which is **not** the seed value in `sql/06_optimized_queries.sql` (`2025-04-21 00:17:55+05:30`, the 200,000th newest of 250,468 rows). It is the large-data value described above. The plan estimates 4,806,480 rows below that timestamp, out of 5,009,360 transactions, so about 202,880 rows are newer; this is only the planner's estimate, and it is consistent with a value near the 200,000th newest row. The committed files do not contain the query that found the value, and they do not show whether `initiated_at` is unique in the large data. `sql/06_optimized_queries.sql` still holds the seed value because it is the seed-data version of the query.

## 1. Results: optimized queries, seed vs large data

| Query | Target | Optimized on seed (ms) | Optimized on large (ms) | Growth (large ÷ seed) | Meets target? | If not, what we changed |
|-------|-------:|-----------------------:|------------------------:|----------------------:|:-------------:|-------------------------|
| R01 | < 5 ms | 0.457 | 0.857 | 1.9× | yes | |
| R02 | < 5 ms | 0.154 | 0.256 | 1.7× | yes | |
| R03 | < 5 ms | 0.114 | 0.102 | 0.9× | yes | |
| R04 | < 5 ms | 0.086 | 1.685 | 19.6× | yes | |
| R05 | < 250 ms | 0.221 | 0.264 | 1.2× | yes | |
| R06 | < 5,000 ms | 1.858 | 13.351 | 7.2× | yes | |
| R07 | < 5,000 ms | 3.759 | 27.810 | 7.4× | yes | |
| R08 | < 5,000 ms | 57.276 | 1018.682 | 17.8× | yes | |
| R09 | < 5,000 ms | 63.285 | 1291.230 | 20.4× | yes | |
| R10 | < 5 ms | 0.027 | 0.079 | 2.9× | yes | |
| R11 | < 250 ms | 0.041 | 0.492 | 12.0× | yes | |
| R12 | < 5 ms | 0.038 | 0.075 | 2.0× | yes | |
| R13 | < 250 ms | 6.268 | 98.714 | 15.7× | yes | |
| R14 | < 250 ms | 0.230 | 0.300 | 1.3× | yes | |
| R15 | < 5,000 ms | 8.874 | 131.363 | 14.8× | yes | |
| R16 | < 250 ms | 0.441 | 18.758 | 42.5× | yes | |
| R17 | < 5,000 ms | 16.988 | 183.455 | 10.8× | yes | |
| R18 | < 5,000 ms | 38.099 | 280.783 | 7.4× | yes | |
| R19 | < 5,000 ms | 1.570 | 29.627 | 18.9× | yes | |
| R20 | < 5,000 ms | 3.491 | 57.762 | 16.5× | yes | |
| R21 | < 250 ms | 0.635 | 4.021 | 6.3× | yes | |
| R22 | < 5 ms | 0.142 | 0.138 | 1.0× | yes | |
| R23 | < 250 ms | 0.128 | 0.059 | 0.5× | yes | |
| R24 | < 5 ms | 0.141 | 0.246 | 1.7× | yes | |
| R25 | < 5,000 ms | 25.903 | 193.276 | 7.5× | yes | |
| W01 | < 5 ms | 0.929 | 1.643 | 1.8× | yes | |
| W02 | < 5 ms | 0.659 | 1.156 | 1.8× | yes | |
| W03 | < 5 ms | 0.670 | 0.532 | 0.8× | yes | |
| W04 | < 1,000 ms | 1.266 | 6.741 | 5.3× | yes | |
| W05 | < 1,000 ms | 3.981 | 120.814 | 30.3× | yes | |

**Reading the table.** All 30 queries meet their target on the large data. Growth is `avg_ms` on large divided by `avg_ms` of the optimized queries on seed, both taken from the two `summary.csv` files. The averages include the first run of each query, which is often a cold-cache run (see W05 and R16 in section 3). The "If not, what we changed" column is empty because no query missed its target.

## 2. Growth analysis

The large data has 20.0× the June 2026 payments (13,764 on seed; 275,280 in the R20 plan on the large data). Growth below is the measured column of section 1. Row counts are from the raw plans (run 2) in `benchmarks/results/optimized/` (seed) and `benchmarks/results/large/`.

| Measured growth | Queries | What the plans show |
|-----------------|---------|---------------------|
| **About the same** (0.5× to 2.9×) | R23 0.5, W03 0.8, R03 0.9, R22 1.0, R05 1.2, R14 1.3, R02 1.7, R24 1.7, W02 1.8, W01 1.8, R01 1.9, R12 2.0, R10 2.9 | They fetch a fixed small number of rows through an index. R10 reads 2 rows on both seed and large; R24 reads 1 row (`transactions_upi_ref_key`); R03 probes the same 2 VPAs of one user and finds 0 rows on both. R01 and R14 read about 5.5 payments per VPA on large against 6 on seed: one user's history did not grow 20×. R23 reads 25 rows through `idx_txn_initiated` (`Buffers: shared hit=28` on large). |
| **Grew 5× to 8×** (less than the data) | W04 5.3, R21 6.3, R06 7.2, R18 7.4, R07 7.4, R25 7.5 | The data they read grew 20×, but the time grew less. R06 reads 8,460 payments for 29 June (423 on seed). R07 reads 2,700 rows (135 on seed). R25 reads about 272,780 June payments (13,639 on seed). R21 finds 6,000 merchants (300). R18 makes 104,740 index probes (5,237). R25 and R18 show `Workers Launched: 2` on large, and R07 uses a `Parallel Bitmap Heap Scan`, so parallel workers share part of the work. W04 expires 1,020 rewards (51). |
| **About 20×** (10× to 21×) | R17 10.8, R11 12.0, R15 14.8, R13 15.7, R20 16.5, R08 17.8, R19 18.9, R04 19.6, R09 20.4 | Their work is proportional to a share of a table. R09 reads 4,658,180 SUCCESS rows (232,909 on seed), a 20.0× increase. R08 reads 2,054,840 P2P rows (102,742). R13 probes `idx_txn_merchant_status_time` once per merchant: 60,000 probes (3,000). R19 joins 4,780 merchants (239). R04 reads 2,400 PENDING rows (120). R11 reads 1,020 rewards (51). R17 reads about 2.8 million rows (139,887; 932,580 × 3 workers). R20 reads 275,280 June rows (13,764). R15 changed plan: on large it reads `idx_txn_merchant_status_time` in a Merge Join (143,740 rows) instead of the date index used on seed. |
| **More than 20×** | W05 30.3, R16 42.5 | Not caused by the data size. Both have one slow first run (a cold-cache run) in the raw plans. See section 3. |

**Where our predictions were right and where they were wrong.** The earlier draft of this section predicted, from the seed plans, three groups:

- *"About the same": R02, R04, R10, R11, R12, R16, R22, R23, R24, W01–W05.*
  - **Right** for R02, R10, R12, R22, R23, R24, W01, W02, W03 (all 2.9× or less).
  - **Wrong** for R04 (19.6×), R11 (12.0×), R16 (42.5×), W04 (5.3×) and W05 (30.3×). We assumed they touch a fixed number of rows. They do not: they read **all** PENDING payments, all rewards expiring in a 3-day window, all open disputes, or all overdue bills, and these sets grew 20× (120 → 2,400 PENDING rows; 51 → 1,020 rewards; 75 → 1,500 disputes; 201 → 4,020 bills). They stayed within their targets because each row is cheap to read through an index.
- *"Roughly 20×": R06, R07, R08, R09, R15, R17, R18, R20, R25.*
  - **Right** for the row counts (20×) and for R08, R09 (17.8×, 20.4×).
  - **Wrong about time** for R06, R07, R18, R25 (7.2× to 7.5×), R15, R17 and R20 (10.8× to 16.5×). The rows grew 20×, but the time grew less. For R17, R18, R20 and R25 the large plans use 2 parallel workers; R08 and R09 are single-process plans and grew almost exactly 20×. We have not tested the effect of parallelism separately, so this is what the plans show, not a measured cause.
- *"Depends on how the data grew": R01, R03, R05, R14, R19, R13, R21.*
  - Per-user queries (R01, R03, R05, R14) stayed flat, 0.9× to 1.9×: users and merchants grew 20×, not the payments of each user or merchant. Merchant-count queries (R13, R19, R21) grew with the merchant count (15.7×, 18.9×, 6.3×), as predicted.

## 3. What broke at scale and how we fixed it

**Nothing missed its target, so nothing needed fixing.** We made no change after the large-data run, and there are no "before/after" large-data plans in the repository. We did not add any index or rewrite after seeing the large results. The points below are the queries that look odd in `summary.csv`, explained from the raw plans.

**W05 (30.3×, avg 120.814 ms, min 15.620, max 326.022).** The average is dominated by the first run.

| Run | Execution time | Evidence in `large/W05.txt` |
|-----|---------------:|-----------------------------|
| 1 | 326.022 ms | `Buffers: shared hit=33672 read=4508 dirtied=4543 written=47`: the pages came from disk and were dirtied |
| 2 | 20.801 ms | no `read=` buffers in the plan |
| 3 | 15.620 ms | no `read=` buffers in the plan |

All three runs use the same plan (`Bitmap Index Scan on idx_bill_due_date` and then `Update on bill_payments`) and update 4,020 rows (201 on seed). The median is 20.801 ms. Even the worst run is under the 1,000 ms target. The planner also estimated 28,804 rows for the scan (about 7× too many) while 4,020 were found; this did not change the plan type.

**R16 (42.5×, avg 18.758 ms, min 2.358, max 51.367).** Same pattern: run 1 shows `Buffers: shared hit=4227 read=1840` (the 1,500 lookups into `transactions_pkey` account for `read=1776` of those buffers), and runs 2 and 3 take 2.549 ms and 2.358 ms. The median is 2.549 ms, 6.9× the seed median of 0.368 ms, which is close to the 20× growth in disputes (75 → 1,500) with a cheap lookup each. The target is 250 ms.

**R08 (1,018.682 ms) and R09 (1,291.230 ms).** These are the slowest queries and both are about 20× their seed time, because they read the whole SUCCESS data:
- R09: `WindowAgg` over 4,658,180 rows from `idx_txn_success_pair_time` (`Heap Fetches: 0`); the filter removes 4,648,820 and keeps 9,360.
- R08: `Incremental Sort` and `GroupAggregate` over 2,054,840 rows; the `HAVING` filter removes 2,045,320 and keeps 260.

Both are index-only (no heap access) but must read every qualifying entry. They are within their 5,000 ms target, with 3.9× (R09) and 4.9× (R08) headroom.

**R18 (280.783 ms) and R20 (54.934 ms median).** Their plans sort on disk: R18 shows `Sort Method: external merge  Disk: 2448kB` for the final sort, and about 6 MB per process for the partial sorts; R20 shows about 2 MB per process. This means the sorts did not fit in `work_mem`. We did not test a larger `work_mem`.

**R13 (15.7×, 98.714 ms).** A `Nested Loop Anti Join` that probes `idx_txn_merchant_status_time` once per merchant (`Index Searches: 60000`, 3,000 on seed), so it grows with the merchant count. Target 250 ms; it has 2.5× headroom, the smallest of the interactive queries.

**R04 (1.685 ms, target 5 ms).** The real-time query with the least headroom, 3.0×. It reads all PENDING rows (2,400 on large) through `idx_txn_pending`. It grows with the PENDING backlog, not with the table size.

**R23.** See section 0: the large run used a value for the 200,000th newest row, and 0.067 ms for run 1 shows it reads 25 entries only.

## 4. Storage

Seed data, measured with `pg_relation_size` / `pg_indexes_size` / `pg_total_relation_size` on schema `gpay`, after `05_indexes.sql`:

| Table | Table (heap) | Indexes | Total |
|-------|-------------:|--------:|------:|
| transactions | 35.6 MB | 80.4 MB | 116.1 MB |
| vpas | 3.9 MB | 6.1 MB | 10.0 MB |
| bank_accounts | 4.5 MB | 4.3 MB | 8.9 MB |
| users | 3.6 MB | 3.7 MB | 7.4 MB |
| rewards | 3.9 MB | 1.8 MB | 5.7 MB |
| bill_payments | 2.9 MB | 0.7 MB | 3.6 MB |
| merchants | 0.3 MB | 0.7 MB | 1.0 MB |
| disputes | 0.4 MB | 0.1 MB | 0.5 MB |
| **All of `gpay`** | **55.1 MB** | **97.8 MB** | **153.2 MB** |

**Large data: not measured in the committed results.** The files in `benchmarks/results/` contain timings and plans, not table or index sizes of `gpay_large`, so we do not state any size here. To measure it, connect to `gpay_large` and run the following (the same kind of query as for the seed table):

```sql
SELECT relname                                        AS "table",
       pg_size_pretty(pg_relation_size(c.oid))        AS heap,
       pg_size_pretty(pg_indexes_size(c.oid))         AS indexes,
       pg_size_pretty(pg_total_relation_size(c.oid))  AS total
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'gpay' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;

-- whole schema, and the whole database
SELECT pg_size_pretty(sum(pg_relation_size(c.oid)))       AS heap,
       pg_size_pretty(sum(pg_indexes_size(c.oid)))        AS indexes,
       pg_size_pretty(sum(pg_total_relation_size(c.oid))) AS total
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'gpay' AND c.relkind = 'r';
SELECT pg_size_pretty(pg_database_size('gpay_large'));
```

Run it after `05_indexes.sql` (which ends with `VACUUM ANALYZE`), as for the seed numbers, and paste the output here.

**Index-to-table ratio.** On the seed data, indexes are **1.8× the size of the tables** (97.8 MB vs 55.1 MB). Most of that is the 7 `transactions` indexes, 80.4 MB against a 35.6 MB heap (the Phase 4 report has the per-index sizes). We expect a similar ratio at 20×, because each index grows with the number of rows it covers; this is an expectation and **is not measured** (see above).

## 5. Architecture for 100×

**Volume at each scale.** At 100× the platform would hold about **25 million payments** for the 18 months in our data. On the seed data:
- one month of payments is about 14,000 rows (13,764 in June 2026);
- that is about 2 MB of heap, plus about 4.5 MB of indexes.

| Scale | Payments per month | Monthly heap + indexes |
|-------|-------------------:|-----------------------:|
| 20× | 275,280 (June 2026, from the R20 plan on the large data) | not measured |
| 100× | about 1.4 million | about 650 MB |

### 5.1 Partitioning

**What we chose: `transactions`, `PARTITION BY RANGE (initiated_at)`, one partition per month.** The full DDL is in `sql/08_partitioning.sql`; we tested it on the seed data and the raw output is in `benchmarks/results/partitioning/seed_output.txt`.

**Why this table, and why RANGE by month:**
- `transactions` is the only table that grows by millions of rows. Every other table stays at about 1 M rows or fewer even at 20× (vpas and bank_accounts: about 1.07 M).
- **10 of our 30 queries filter `transactions` on `initiated_at`** (R03–R07, R14, R15, R20, R23, R25): "today", "29 June", "June 2026", "last 7 days". With monthly partitions, the ones with a one-day or one-month window (R03, R05, R06, R15, R20) read **one partition**. The open-ended ones (R04, R07, R14, R23, R25) read only the months their range covers.
- Old months can be **detached and archived** instantly (`DETACH PARTITION … CONCURRENTLY`). No `DELETE`, no VACUUM afterwards.
- Autovacuum only works on the current month. Closed months never change.

**Why not the alternatives:**
- **HASH on `payer_vpa`:** it spreads users evenly, but no query could skip partitions by date, and archiving would still need `DELETE`.
- **LIST on `status`:** 93 % of the rows are SUCCESS, so the partitions would be badly unbalanced.

**Partition pruning, measured on the seed data** (`EXPLAIN (ANALYZE)` output from `seed_output.txt`):

| Query | Partitions read (of 22) | Evidence |
|-------|------------------------:|----------|
| R06 settlement for 29 June | **1** | `Index Scan using transactions_2026_06_initiated_at_idx on transactions_2026_06` (423 rows) |
| R20 rewritten, June 2026 | **1** | `Seq Scan on transactions_2026_06` (13,764 rows); the other 21 pruned |
| R07 "since 24 June" (no end date) | 1 with data + 4 empty | June by index; the empty Jul–Sep 2026 partitions and DEFAULT are opened and return 0 rows |
| R20 **original** (`initiated_at::date BETWEEN …`) | **all 22** | The cast hides the column, so nothing is pruned. Our Phase 4 sargable rewrite matters even more once the table is partitioned. |
| R24 by `upi_ref`, no date | **all 22** (index probe in each) | No partition key in the `WHERE` clause |
| R24 via the `upi_refs` registry | **1** | `Index Scan … on transactions_2025_09`; the registry gives the date first |

**The primary-key rule.** PostgreSQL only allows `PRIMARY KEY` / `UNIQUE` on a partitioned table if the constraint **contains the partition key**. So we had to change two constraints:

| Before | After |
|--------|-------|
| `PRIMARY KEY (txn_id)` | `PRIMARY KEY (txn_id, initiated_at)` |
| `UNIQUE (upi_ref)` | `UNIQUE (upi_ref, initiated_at)` |

This has three consequences, and here is how we handle each:

1. **`txn_id` alone is no longer enforced unique.** It comes from one sequence, so this is acceptable.
2. **`upi_ref` must stay globally unique**, because NPCI references identify a payment. We added a small **`upi_refs` registry** (`upi_ref PRIMARY KEY`, unpartitioned), written in the same transaction as the payment. It also turns R24 back into a single-partition lookup (see the table above).
3. **`rewards.txn_id` and `disputes.txn_id` can no longer have a FK to `transactions(txn_id)`.** A foreign key needs a unique target, and the only unique key is now `(txn_id, initiated_at)`. In production we would add `txn_initiated_at` to both tables and use a composite FK.

**Keeping partitions ahead of time.** We create 3 future months in advance (Jul–Sep 2026, after the 30 Jun 2026 snapshot), and a monthly job keeps it 3 ahead. The `DEFAULT` partition is a safety net that should stay empty; on the seed data `rows_in_default = 0`.

### 5.2 Sharding (beyond one server)

At 100× one well-indexed PostgreSQL server could still hold the data (about 650 MB per month, by the table in section 5). Sharding becomes necessary for **write throughput and availability**, not size.

**What we would shard on: `payer` user (`users.user_id` of the payer VPA), with hash sharding.**

Why the payer:
- **Most real-time queries are about one payer:**
  - R03 daily limit check;
  - W01 new payment;
  - R10 rewards, R12 bills, R22 accounts;
  - the "sent" half of R01;
  - R14 spend analysis.

  All of these touch one shard.
- A payment is created by its payer, so **the write path (W01, then W02 for the callback) stays on one shard**.

Why not the others:
- **By time:** every new payment would go to the newest shard. That makes one write hotspot, which is the opposite of what sharding is for.
- **By payee or merchant:** this suits merchant dashboards, but the payment path (R03, W01) would then be cross-shard.

**What becomes cross-shard, and how we would handle it:**

| Query | Why cross-shard | Handling |
|-------|-----------------|----------|
| R01 "received" half | The payee may live on another shard | Write each P2P payment to the **payee's shard too**, as an append-only "received" copy via an outbox / change-data-capture stream. R01 then reads both halves from the user's own shard. |
| R05, R06, R13, R15, R17, R19 (merchant views) | A merchant's payments come from payers on every shard | Keep a **merchant-keyed copy** (stream of P2M payments into a merchant-sharded table, or the analytics store). Settlement R06 runs there. |
| R08, R09 (fraud), R07, R20, R25 (platform health), R18 (compliance) | Need every payment | Run on an **analytics warehouse** fed by the same stream, not on the OLTP shards. These are reports and tolerate minutes of delay (assumption 5 in `01_problem_understanding.md`). |
| R24 by `upi_ref` | The reference does not say which shard | A global **`upi_ref → shard, initiated_at`** lookup service (the sharded version of our `upi_refs` registry). |

**A P2P payment between two users on different shards** is written once, on the payer's shard, which owns the money movement. The payee's copy is **eventually consistent**. A distributed transaction (2PC) on every payment would cost more than a few seconds of delay on the receiver's history.

### 5.3 Read replicas and caching

| Where | Queries | Why |
|-------|---------|-----|
| **Primary only** | W01–W05, R03, R04 | Writes, plus the reads that decide a write: R03 decides whether the payment is allowed under the daily limit, and R04 picks payments for reconciliation. A lagging replica could approve a payment over the limit. |
| **Primary, or replica with read-your-writes** | R01, R10, R12, R22 | The user expects to see the payment / scratch card they just made. Route them to the primary for a few seconds after that user's write, then to a replica. |
| **Read replica** | R05, R11, R13, R14, R16, R21, R23, R24 | Interactive tools that tolerate about a second of lag. |
| **Replica, or better a summary table** | R06, R07, R08, R09, R15, R17, R18, R19, R20, R25 | Heavy reports. They should never compete with the payment path on the primary. |
| **Cache (e.g. Redis), invalidated on change** | R02 VPA → name/active, R22 linked accounts, R21 merchant search | Read on every pay screen, change rarely. A 60 s cache plus delete-on-update removes most of this load from the database. |

### 5.4 Maintenance

**Autovacuum.**
- The default `autovacuum_vacuum_scale_factor = 0.2` waits until 20 % of a table is dead rows. On one big table that is millions of rows.
- With monthly partitions, only the **current month** gets updates (PENDING → SUCCESS, W02), so we tune just that partition:
  ```sql
  ALTER TABLE gpay_part.transactions_2026_06
    SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);
  ```
- These settings must be set **per partition**; PostgreSQL does not accept autovacuum settings on the partitioned parent.
- A closed month gets **one `VACUUM (FREEZE)`** after it closes, and then never needs vacuuming again.

**Statistics.** Our sargable rewrites rely on good row estimates for date ranges, so we run `ANALYZE` on the new month's partition daily. On a big table, the newest days are otherwise missing from the statistics until autovacuum's analyze catches up.

**Archiving.** Keep the online period required by the retention policy, for example 18–24 months. Older months are handled like this:
1. `DETACH PARTITION … CONCURRENTLY`;
2. dump the partition to cold storage;
3. `DROP` it.

This is instant, and needs no `DELETE` and no table bloat.

**Summary tables.** These are for the reports that do not need live data.

| Summary table | Replaces | Refreshed |
|---------------|----------|-----------|
| `daily_merchant_settlement (day, merchant_id, payments, amount)` | R06 and R15 | once after midnight IST for the previous day |
| `daily_platform_health (day, payments, success, failures by code, avg latency per bank)` | R07, R20 and R25 | hourly for today; final version after midnight |

Closed days never change, so each refresh only computes **one new day**: `INSERT … SELECT … WHERE initiated_at >= day AND < day + 1`.

**Index bloat.** The current-month partitions of I1/I2/I6 get the most churn. Check them monthly with `pgstattuple` and run `REINDEX CONCURRENTLY` on that partition if needed.

## 6. Conclusion

**Is the database ready for 20×? Yes, for the 30 queries we were given.** On `gpay_large` (5,009,360 transactions) all 30 queries meet their targets (section 1), with the same schema, the same indexes and no changes after the large run.

**What the measurements show:**
- **Real-time / payment path** (target < 5 ms): the slowest is R04 at 1.685 ms, then W01 at 1.643 ms and R01 at 0.857 ms. R04 has the least headroom (3.0×) because it reads all PENDING payments (2,400 rows on large, 120 on seed).
- **Interactive tools** (target < 250 ms): the slowest is R13 at 98.714 ms (2.5× headroom). It probes the transactions index once for each of the 60,000 merchants.
- **Reports** (target < 5,000 ms): the slowest are R09 at 1,291.230 ms (3.9× headroom) and R08 at 1,018.682 ms (4.9× headroom). Both read every SUCCESS payment, and both grew by about 20× (20.4× and 17.8×).
- **Batch jobs** (target < 1,000 ms): W05 averages 120.814 ms and W04 6.741 ms.

**Remaining risks:**
1. **The full-scan reports (R08, R09) grow linearly with the number of payments.** R09 has 3.9× headroom, so 5× more data on top of the large dataset would put it over its 5,000 ms target if the growth stays linear. At 100× they need the summary tables or the analytics store from sections 5.2 and 5.4. R17 (2.8 million rows read) and R18 (sorts spill to disk, section 3) are the next ones to watch.
2. **First-run (cold cache) cost.** W05 took 326.022 ms and R16 51.367 ms on their first run, against about 16–21 ms and about 2.5 ms on later runs (section 3). The averages in section 1 include these runs. After a restart or a cache flush, users would see the slow first run. All first runs are still within their targets.
3. **Memory settings.** The sorts of R18 and R20 spill to disk. We did not test a larger `work_mem`, so we cannot say how much it would help.
4. **Write cost.** The 7 `transactions` indexes make inserts about 2.2× slower (Phase 4 report). W01 averages 1.643 ms on large, inside its 5 ms target, but it is the first thing to revisit at 100×.
5. **Partitioning changes the key rules.** Unique `upi_ref` and FKs from `rewards` / `disputes` need the registry and composite keys described in 5.1. Partitioning was tested on the seed data only (`benchmarks/results/partitioning/seed_output.txt`); the committed results do not include a partitioned large-data run.
6. **Not measured:** the storage size of `gpay_large` (section 4), and whether `initiated_at` is unique in the large data (section 0).
