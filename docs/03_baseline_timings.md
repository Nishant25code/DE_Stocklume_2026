# 03 · Baseline Timings

**Team T0069** · PostgreSQL 17.12 (Homebrew) · MacBook Air M4 (Mac16,1), 16 GB RAM · database `gpay`, seed data (250,468 transactions)

**State measured:** the schema from `sql/01_schema.sql`, loaded by `sql/02_load_data.sql` (which ends with `ANALYZE`). Only the indexes created by PK / UNIQUE constraints exist; there is no tuning and the server settings are the defaults.

**Method:**
```bash
./benchmarks/run_benchmark.sh gpay baseline
```
- Each query runs **3 times** with `EXPLAIN (ANALYZE, BUFFERS)`. The `Execution Time` of each run is recorded and the average is reported.
- Writes (W01–W05) run inside `BEGIN … ROLLBACK`, so the data never changes.
- Raw plans of all 3 runs are in [`benchmarks/results/baseline/<id>.txt`](../benchmarks/results/baseline/). The summary is [`summary.csv`](../benchmarks/results/baseline/summary.csv).
- Every number below is copied from those files by a script, not by hand.

## Timing table

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Transaction history: everything user 15177 sent or received, newest first | READ | 268.304 | 38.197 | 29.716 | 112.072 |
| R02: "Pay to UPI ID": check that the entered VPA exists and is active | READ | 2.139 | 0.115 | 0.081 | 0.778 |
| R03: UPI limit check: total successfully sent by user 15177 on 30 June 2026 (limit ₹1,00,000/day) | READ | 28.692 | 17.692 | 16.519 | 20.968 |
| R04: Reconciliation: payments still PENDING more than 15 minutes after 23:59 on 30 Jun 2026 | READ | 12.136 | 10.058 | 10.232 | 10.809 |
| R05: Google Pay for Business: hourly collections of merchant 2 on 29 June 2026 | READ | 10.754 | 10.954 | 9.702 | 10.470 |
| R06: Settlement: amount to settle to every merchant for 29 June 2026 | READ | 15.310 | 9.795 | 9.352 | 11.486 |
| R07: Bank health: failure codes per payer bank in the last 7 days | READ | 27.198 | 10.530 | 10.134 | 15.954 |
| R08: Fraud: VPAs that received P2P money from 5+ different people on the same day | READ | 421.085 | 369.942 | 382.232 | 391.086 |
| R09: Fraud: repeated payments—same payer to the same payee within 10 minutes of the previous one | READ | 949.528 | 926.355 | 2,553.546 | 1,476.476 |
| R10: Rewards tab: user 15177's unscratched cards that have not expired | READ | 29.363 | 2.458 | 2.268 | 11.363 |
| R11: Notification job: unscratched rewards that expire in the first 3 days of July | READ | 2.220 | 2.177 | 2.042 | 2.146 |
| R12: Bill reminders: user 1072's unpaid bills due in the next 7 days | READ | 60.665 | 6.013 | 4.820 | 23.833 |
| R13: Merchant success team: merchants who have never received a payment (to call and help them) | READ | 47.168 | 31.265 | 29.810 | 36.081 |
| R14: Spend analysis: user 15177's 2026 spending per merchant category code (MCC) | READ | 42.106 | 27.263 | 22.812 | 30.727 |
| R15: Business insights: top 10 merchants by June 2026 GMV in each city | READ | 11.675 | 12.546 | 11.147 | 11.789 |
| R16: Disputes desk: disputes open for more than 7 days (SLA breached) | READ | 5.775 | 0.366 | 0.310 | 2.150 |
| R17: Merchant risk: refund rate per merchant (at least 30 payments) | READ | 16.036 | 14.836 | 13.901 | 14.924 |
| R18: Compliance: users without verified KYC who have successfully sent ₹10,000+ in total | READ | 54.355 | 26.751 | 25.262 | 35.456 |
| R19: Merchant report: last payment time and successful payment count of every verified Bengaluru merchant | READ | 5,454.642 | 5,004.497 | 5,350.839 | 5,269.993 |
| R20: Platform health: daily success rate in June 2026 | READ | 12.039 | 10.088 | 10.197 | 10.775 |
| R21: "Search businesses": merchants with "chai" in their name | READ | 0.923 | 1.074 | 0.805 | 0.934 |
| R22: Payment screen: user 15177's primary bank account and all their UPI IDs | READ | 15.885 | 3.774 | 3.962 | 7.874 |
| R23: Operations console: all transactions, newest first, page 8,001 (25 per page) | READ | 116.482 | 91.586 | 93.012 | 100.360 |
| R24: Customer support: find a payment by its UPI reference number | READ | 0.435 | 0.042 | 0.049 | 0.175 |
| R25: Bank health: average seconds from initiation to completion per payer bank (June 2026) | READ | 42.950 | 21.823 | 20.447 | 28.407 |
| W01: Pay: user 15177 starts a ₹250 payment to merchant 2 (PENDING until the bank confirms) | WRITE | 2.781 | 0.631 | 0.585 | 1.332 |
| W02: Bank callback: mark the oldest PENDING payment as successful | WRITE | 70.514 | 28.930 | 25.446 | 41.630 |
| W03: Scratch card: user 15177 scratches their oldest unscratched card | WRITE | 2.427 | 1.743 | 1.868 | 2.013 |
| W04: Nightly job (run at 00:00 on 4 Jul 2026): expire every reward whose time is up | WRITE | 3.980 | 2.433 | 2.540 | 2.984 |
| W05: Nightly job: bills past their due date and still unpaid become OVERDUE | WRITE | 14.358 | 3.429 | 2.430 | 6.739 |
| **Total (sum of all 30)** | | **7,741.925** | **6,687.363** | **8,646.066** | **7,691.784** |

**Observations**
- Most queries are much slower in **Run 1** (e.g. R01 268 ms vs ~34 ms; R12 61 ms vs ~5 ms). Run 1 reads pages that are not yet in PostgreSQL's shared buffers and plans the query cold; runs 2 and 3 are warm. We report the average of all three, as the brief requires, so the cold-cache cost is included.
- **R09 run 3 (2,554 ms)** is an outlier against runs 1–2 (~940 ms). The plan is identical (same row counts and buffers). The extra time is in the sort that spills to disk (`external merge Disk: 18712kB`), which is sensitive to disk and OS activity on the laptop at that moment. We kept the measured value.
- **R19 is the "several seconds" query**: about 5.3 s on average, and **68.5%** of the total time of all 30 queries.
- Only R02, R24 and W02 reach their main table through an index, and only through the automatic PK/UNIQUE indexes. Other index scans (R06, R07, R16, R22, W03) are on joined or secondary tables. Every other main-table access is a Seq Scan.

## Scan type and reason, per query

| Query | Scan type(s) in the plan | Why it is slow / fast |
|---|---|---|
| R01 | Parallel **Seq Scan** on transactions, Seq Scan on vpas | No index on `payer_vpa`/`payee_vpa`. The `OR` of two `IN (subquery)` forces a full scan of all 250k rows (83k removed per worker) and then a sort, just to return 14 rows. |
| R02 | **Index Scan** vpas_pkey, Index Scan users_pkey | Lookup by the PK `vpa`, then by `user_id`. Fast (~0.1 ms warm). |
| R03 | Parallel **Seq Scan** on transactions, Seq Scan on vpas | `DATE(initiated_at) = …` is not sargable, and `payer_vpa` has no index, so the whole table is filtered for 0 matching rows. There is also no index on `vpas.user_id`. |
| R04 | **Seq Scan** on transactions | No index on `status`. 125 PENDING rows are found by reading all 250k. |
| R05 | **Seq Scan** on transactions | No index on `(merchant_id, initiated_at)`. A full scan for one merchant-day. |
| R06 | **Seq Scan** on transactions, Index Scan merchants_pkey | No index on `initiated_at`. The full table is read to keep one day of rows. |
| R07 | **Seq Scan** on transactions, Index Scan vpas_pkey, Index Scan uq_ba_account_user | No index on `(status, initiated_at)`. The full scan finds the last 7 days of FAILED rows; the joins use PKs. |
| R08 | **Seq Scan** on transactions | Reads all ~103k P2P SUCCESS rows. The `count(DISTINCT)` needs a sort, which spills to disk (6.9 MB external merge), and then 102k groups are thrown away by `HAVING`. Reads most of the table by design. |
| R09 | **Seq Scan** on transactions | The `lag()` window needs every SUCCESS row (233k) sorted by `(payer_vpa, payee_vpa, initiated_at)`. The sort spills to disk (18.7 MB). The second-slowest query. |
| R10 | **Seq Scan** on rewards | No index on `rewards(user_id, status)`. Reads all 39,799 rewards for one user. |
| R11 | **Seq Scan** on rewards | No index on `status`. The table is small (40k rows), so it takes ~2 ms. |
| R12 | **Seq Scan** on bill_payments | No index on `(user_id, status, due_date)`. Reads all 30k bills for one user. |
| R13 | **Seq Scan** on merchants and transactions | Hashed `NOT IN` over all 250k `merchant_id` values. **Returns 0 rows** because the subquery contains NULLs (P2P rows), so the answer is wrong as well as slow. |
| R14 | Parallel **Seq Scan** on transactions, Seq Scan on vpas, Index Scan merchants_pkey | `EXTRACT(YEAR …) >= 2025` is not sargable and matches every row anyway. With no `payer_vpa` index, 233k SUCCESS rows are scanned to find 11. |
| R15 | **Seq Scan** on transactions and merchants | No index on `initiated_at`. The full scan keeps June 2026 SUCCESS rows, then groups and ranks them. |
| R16 | **Seq Scan** on disputes, Index Scan transactions_pkey | disputes is tiny (3.6k rows). The join to transactions uses the PK. Fast. |
| R17 | **Seq Scan** on transactions | Aggregates every P2M row (140k) per merchant. Must read most of the table. |
| R18 | Parallel **Seq Scan** on transactions, vpas and users | Three hash joins over all SUCCESS payments, summed per user. Must read most of the table. |
| R19 | **Seq Scan** on merchants; **2 correlated SubPlans, each a Seq Scan on transactions** | For each of the 239 verified Bengaluru merchants, two subqueries each scan all 250k transactions (no index on `merchant_id`): 478 full scans and 2.2 M buffer hits. **The slowest query: ~5.3 s.** |
| R20 | Parallel **Seq Scan** on transactions | `initiated_at::date BETWEEN …` is not sargable. Full scan to keep June (~13.8k rows). |
| R21 | **Seq Scan** on merchants | `ILIKE '%chai%'` with a leading wildcard can't use a B-tree. The table is only 3,000 rows, so it takes <1 ms. |
| R22 | **Seq Scan** on vpas, Index Scan uq_ba_account_user | Finds bank_accounts by scanning the *whole* `(account_id, user_id)` index, because `user_id` is its second column. vpas is scanned fully because there is no index on `vpas.account_id`. |
| R23 | **Seq Scan** on transactions | `ORDER BY initiated_at DESC OFFSET 200000` sorts all 250k rows (14 MB on disk) and throws 200k away. |
| R24 | **Index Scan** transactions_upi_ref_key | `upi_ref` is UNIQUE, so the lookup uses its automatic index. The fastest query (~0.05 ms warm). |
| R25 | Parallel **Seq Scan** on transactions, vpas and bank_accounts | No index on `initiated_at`. Full scan plus two hash joins over June rows. |
| W01 | (no scan): Insert | A single-row insert. Checks the PK, the UNIQUE `upi_ref`, the FKs (vpas, merchants) and the CHECK constraints. Fast. |
| W02 | **Index Scan** transactions_pkey (both the subquery and the update) | `min(txn_id) WHERE status='PENDING'` walks the PK index from the smallest id and filters 249,875 rows before it finds the first PENDING one. No index on `status`. |
| W03 | **Seq Scan** on rewards, Index Scan rewards_pkey | The subquery scans all rewards for the user; the update uses the PK. |
| W04 | **Seq Scan** on rewards | No index on `(status, expires_at)`. Full scan to update the expiring UNSCRATCHED cards. |
| W05 | **Seq Scan** on bill_payments | No index on `(status, due_date)`. Full scan of 30k bills. |

## Takeaways for Phase 4
- **Biggest wins available:**
  - R19: rewrite the correlated subqueries as one grouped join, plus an index on `transactions(merchant_id)`.
  - R09 and R08: the sorts spill to disk, so these need sort-friendly indexes or less data.
  - R01, R03, R14: add `payer_vpa`/`payee_vpa` indexes and make the predicates sargable.
  - R23: switch to keyset pagination.
- **Non-sargable predicates to rewrite:** R03 `DATE()`, R14 `EXTRACT(YEAR)`, R20 `::date`.
- **Wrong result:** R13 (`NOT IN` with NULLs). Fix with `NOT EXISTS`.
- **Must read most of the table anyway:** R08, R09, R17 and R18. Expect smaller gains on these.
