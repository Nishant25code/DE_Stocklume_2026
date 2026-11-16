-- Load the seed data (run from the repository root: psql -d <db> -f sql/02_load_data.sql)
-- Parents before children so every foreign key is satisfied.
SET search_path TO gpay;
\copy cities        FROM 'seed_data/cities.csv'        WITH (FORMAT csv, HEADER true)
\copy users         FROM 'seed_data/users.csv'         WITH (FORMAT csv, HEADER true)
\copy bank_accounts FROM 'seed_data/bank_accounts.csv' WITH (FORMAT csv, HEADER true)
\copy vpas          FROM 'seed_data/vpas.csv'          WITH (FORMAT csv, HEADER true)
\copy merchants     FROM 'seed_data/merchants.csv'     WITH (FORMAT csv, HEADER true)
\copy transactions  FROM 'seed_data/transactions.csv'  WITH (FORMAT csv, HEADER true)
\copy rewards       FROM 'seed_data/rewards.csv'       WITH (FORMAT csv, HEADER true)
\copy bill_payments FROM 'seed_data/bill_payments.csv' WITH (FORMAT csv, HEADER true)
\copy disputes      FROM 'seed_data/disputes.csv'      WITH (FORMAT csv, HEADER true)
ANALYZE;

-- Row counts (expected: 10, 40000, 53333, 53333, 3000, 250468, 39799, 30000, 3569)
SELECT 'cities' AS tbl, count(*) FROM cities UNION ALL
SELECT 'users', count(*) FROM users UNION ALL
SELECT 'bank_accounts', count(*) FROM bank_accounts UNION ALL
SELECT 'vpas', count(*) FROM vpas UNION ALL
SELECT 'merchants', count(*) FROM merchants UNION ALL
SELECT 'transactions', count(*) FROM transactions UNION ALL
SELECT 'rewards', count(*) FROM rewards UNION ALL
SELECT 'bill_payments', count(*) FROM bill_payments UNION ALL
SELECT 'disputes', count(*) FROM disputes;
