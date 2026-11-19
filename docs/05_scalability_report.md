# 05 · Scalability Report

**Team T0069 · Section D** · Google Pay (UPI) database · PostgreSQL 17.12 · MacBook Air M4, 16 GB, the same laptop as Phases 3 and 4

> **Status (19 Nov 2026).** Faculty have not released `large_data.zip` yet.
>
> - **Done:** the design part (sections 5–6) and the partitioning work (`sql/08_partitioning.sql`, tested on the seed data).
> - **Pending:** the large-data measurements (sections 1–4). They will be filled in as soon as the file is available, using the steps in section 0.
> - Every number that is filled in below comes from our own raw outputs in `benchmarks/results/`.

## 0. How the large-data round will be run

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

## 1. Results: optimized queries, seed vs large data

| Query | Target | Optimized on seed (ms) | Optimized on large (ms) | Growth (large ÷ seed) | Meets target? | If not, what we changed |
|-------|-------:|-----------------------:|------------------------:|----------------------:|:-------------:|-------------------------|
| R01 | < 5 ms | 0.457 | _pending_ | _pending_ | _pending_ | |
| R02 | < 5 ms | 0.154 | _pending_ | _pending_ | _pending_ | |
| R03 | < 5 ms | 0.114 | _pending_ | _pending_ | _pending_ | |
| R04 | < 5 ms | 0.086 | _pending_ | _pending_ | _pending_ | |
| R05 | < 250 ms | 0.221 | _pending_ | _pending_ | _pending_ | |
| R06 | < 5,000 ms | 1.858 | _pending_ | _pending_ | _pending_ | |
| R07 | < 5,000 ms | 3.759 | _pending_ | _pending_ | _pending_ | |
| R08 | < 5,000 ms | 57.276 | _pending_ | _pending_ | _pending_ | |
| R09 | < 5,000 ms | 63.285 | _pending_ | _pending_ | _pending_ | |
| R10 | < 5 ms | 0.027 | _pending_ | _pending_ | _pending_ | |
| R11 | < 250 ms | 0.041 | _pending_ | _pending_ | _pending_ | |
| R12 | < 5 ms | 0.038 | _pending_ | _pending_ | _pending_ | |
| R13 | < 250 ms | 6.268 | _pending_ | _pending_ | _pending_ | |
| R14 | < 250 ms | 0.230 | _pending_ | _pending_ | _pending_ | |
| R15 | < 5,000 ms | 8.874 | _pending_ | _pending_ | _pending_ | |
| R16 | < 250 ms | 0.441 | _pending_ | _pending_ | _pending_ | |
| R17 | < 5,000 ms | 16.988 | _pending_ | _pending_ | _pending_ | |
| R18 | < 5,000 ms | 38.099 | _pending_ | _pending_ | _pending_ | |
| R19 | < 5,000 ms | 1.570 | _pending_ | _pending_ | _pending_ | |
| R20 | < 5,000 ms | 3.491 | _pending_ | _pending_ | _pending_ | |
| R21 | < 250 ms | 0.635 | _pending_ | _pending_ | _pending_ | |
| R22 | < 5 ms | 0.142 | _pending_ | _pending_ | _pending_ | |
| R23 | < 250 ms | 0.128 | _pending_ | _pending_ | _pending_ | |
| R24 | < 5 ms | 0.141 | _pending_ | _pending_ | _pending_ | |
| R25 | < 5,000 ms | 25.903 | _pending_ | _pending_ | _pending_ | |
| W01 | < 5 ms | 0.929 | _pending_ | _pending_ | _pending_ | |
| W02 | < 5 ms | 0.659 | _pending_ | _pending_ | _pending_ | |
| W03 | < 5 ms | 0.670 | _pending_ | _pending_ | _pending_ | |
| W04 | < 1,000 ms | 1.266 | _pending_ | _pending_ | _pending_ | |
| W05 | < 1,000 ms | 3.981 | _pending_ | _pending_ | _pending_ | |

## 2. Growth analysis

*To be filled in from the measured "Growth" column.*

What we expect, from the shape of each plan on the seed data. These are predictions, not measurements:

| Expected growth | Queries | Why |
|-----------------|---------|-----|
| **About the same** (index lookup, depth grows with log n) | R02, R04, R10, R11, R12, R16, R22, R23, R24, W01–W05 | They fetch a fixed small number of rows through an index (one VPA, one UPI reference, the 125 PENDING rows, 25 rows of a page). A B-tree gets at most one level deeper at 20×. |
| **Roughly 20×** (they read a fixed *share* of the table) | R06, R07, R08, R09, R15, R17, R18, R20, R25 | Each reads "all June payments", "all SUCCESS payments" or "all P2M payments". At 20× there are 20× as many such rows. |
| **Depends on how the data grew** | R01, R03, R05, R14, R19, R13, R21 | A per-user or per-merchant query stays flat if there are 20× more users, but grows if each user makes 20× more payments. |

## 3. What broke at scale and how we fixed it

*To be filled in: any query that misses its target on the large data, with before/after plans.*

The queries we will watch first:

- **R09:** reads every SUCCESS payment. 63 ms on seed, so about 1.3 s if it grows 20×; still inside 5 s.
- **R08:** reads every successful P2P payment. 57 ms on seed.
- **R18:** we could not speed it up in Phase 4 (38 ms on seed).
- **R13:** the anti join probes I3 once per merchant, so it grows with the merchant count.

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

**Large data:** *to be filled in with the same query on `gpay_large`.*

**Index-to-table ratio.** On the seed data, indexes are **1.8× the size of the tables** (97.8 MB vs 55.1 MB). Most of that is the 7 `transactions` indexes, 80.4 MB against a 35.6 MB heap (the Phase 4 report has the per-index sizes). We expect the same ratio at 20×, because each index grows with the number of rows it covers.

## 5. Architecture for 100×

**Volume at each scale.** At 100× the platform would hold about **25 million payments** for the 18 months in our data. On the seed data:
- one month of payments is about 14,000 rows (13,764 in June 2026);
- that is about 2 MB of heap, plus about 4.5 MB of indexes.

| Scale | Payments per month | Monthly heap + indexes |
|-------|-------------------:|-----------------------:|
| 20× | about 275,000 | — |
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

*To be completed after the large-data run.* Based on the seed results and the design above:

**Ready for 20×:**
- The real-time queries are all index lookups, under 1 ms on the seed data, and should stay far below 5 ms.
- The reports have more than 50× headroom under their 5 s target, even if they grow 20× (largest today: R09, 63 ms).

**Remaining risks:**
1. **The full-scan reports (R08, R09, R17, R18) grow linearly.** At 100× they need summary tables or the analytics store.
2. **Write cost.** The 7 `transactions` indexes make inserts about 2.2× slower (Phase 4). That is fine at today's rate, but it is the first thing to revisit at 100×.
3. **Partitioning changes the key rules.** Unique `upi_ref` and FKs from `rewards` / `disputes` need the registry and composite keys described in 5.1.
