# 01 · Problem Understanding

**Team T0069 · Section D** — Google Pay (UPI) digital payments database

Google Pay India stores every UPI payment, the users and bank accounts behind each UPI ID (VPA), merchants, rewards, bills and disputes. The database was built in a hurry, has no documented schema, and product teams report slow or wrong queries. Our job: rebuild a well-constrained schema, measure the 30 key queries, make them fast without changing results, and show the design survives 20× growth.

## Problems, needs and stakeholders

| # | What the business needs (our words) | Stakeholders affected | Queries | Class |
|---|-------------------------------------|-----------------------|---------|-------|
| P1 | A user's recent payments (sent **and** received) and the pay screen (does this VPA exist, which accounts are linked) must load instantly on every app open. | Payer, payee | R01, R02, R22 | **Customer-facing / real-time** |
| P2 | Before every payment we sum what the user already sent today to enforce the ₹1,00,000/day UPI limit, and then insert the payment. This sits in the payment path, so every ms adds to checkout time. | Payer, payments core, bank partner | R03, W01 | **Customer-facing / real-time** |
| P3 | Ops must find payments stuck in PENDING and apply bank callbacks quickly, so money is not left in limbo. | Reconciliation / ops, payer, bank partner | R04, W02 | **Real-time** (callback) / ops tool |
| P4 | Merchants want live hourly collections and an accurate daily settlement amount. The success team's "merchants who never received a payment" list comes back **empty**, which is a wrong answer, not just a slow one. | Merchant, merchant success team, finance | R05, R06, R13 | R05/R13 interactive tools · R06 **reporting** |
| P5 | Detect mule accounts (many payers → one VPA in a day), duplicate payments within 10 min, and merchants with high refund rates, close to real time. | Fraud & risk, payer, merchant | R08, R09, R17 | **Reporting / analytics** (risk batch) |
| P6 | Rewards tab shows a user's live scratch cards; nightly jobs notify and expire rewards and mark unpaid bills OVERDUE; bill reminders need upcoming dues. | Rewards team, payer, billers | R10, R11, R12, W03, W04, W05 | R10, R12, W03 **real-time** · R11 interactive · W04, W05 **batch** |
| P7 | Compliance needs reports of non-KYC users moving large sums (RBI/KYC); support must find a payment by its 12-digit UPI reference instantly and work an SLA-breached dispute queue. | Compliance (RBI/KYC), customer support, payer | R16, R18, R23, R24 | R24 **real-time** · R16, R23 interactive · R18 **reporting** |
| P8 | Bank-health dashboards (failure codes, latency, success rate) and business insights (per-merchant/city GMV, spend by category) time out today, and volume will grow 20×. | Bank partnerships, analytics, merchant | R07, R14, R15, R19, R20, R21, R25 | R14, R21 interactive · rest **reporting / analytics** |

## Classification → performance target (from the brief, on the 20× data)

| Group | Queries | Target |
|-------|---------|-------:|
| Real-time / payment path | R01, R02, R03, R04, R10, R12, R22, R24, W01, W02, W03 | < 5 ms |
| Interactive merchant & ops tools | R05, R11, R13, R14, R16, R21, R23 | < 250 ms |
| Reports, risk & analytics | R06, R07, R08, R09, R15, R17, R18, R19, R20, R25 | < 5 s |
| Batch jobs | W04, W05 | < 1 s |

## Assumptions

1. The data is a snapshot taken at **2026-06-30 23:59 IST**; "today", "last 7 days" and "next 7 days" in the queries are relative to that moment (W04 runs at 00:00 on 4 Jul 2026).
2. All timestamps are IST (`+05:30`) and stored as `timestamptz`; amounts are in rupees with 2 decimals.
3. A P2P payee may be on another UPI app (`@ybl`, `@paytm`, `@ibl`, `@axl`), so not every payee VPA exists in our `vpas` table. Every **payer** is a Google Pay user.
4. One UPI payment is capped at ₹1,00,000; the daily limit is checked against `SUCCESS` + `PENDING` payments (as R03 does).
5. Reports (P5, P8) can tolerate data a few minutes old; the payment path (P1, P2, P3) cannot.
6. Queries in `workload_30.sql` are the real production queries and must return the same rows after optimization, except where a query is provably wrong (R13).
