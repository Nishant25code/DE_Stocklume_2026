-- Google Pay (UPI) Digital Payments Database: schema rebuilt from the seed data exports.
-- Phase 2 rule: only PK / FK / UNIQUE / NOT NULL / CHECK constraints. No performance indexes.
-- (PK and UNIQUE constraints create their own indexes automatically; one partial UNIQUE index
--  enforces "at most one primary bank account per user", which a CHECK cannot express.)

DROP SCHEMA IF EXISTS gpay CASCADE;
CREATE SCHEMA gpay;
SET search_path TO gpay;

-- ---------------------------------------------------------------- cities
CREATE TABLE cities (
    city_id    smallint     PRIMARY KEY,
    city_name  varchar(50)  NOT NULL UNIQUE,
    state      varchar(50)  NOT NULL
);

-- ---------------------------------------------------------------- users
CREATE TABLE users (
    user_id     integer      PRIMARY KEY,
    full_name   varchar(100) NOT NULL,
    phone       varchar(10)  NOT NULL UNIQUE
                CONSTRAINT chk_users_phone CHECK (phone ~ '^[6-9][0-9]{9}$'),
    email       varchar(100) UNIQUE                       -- optional at sign-up (UPI needs only a phone)
                CONSTRAINT chk_users_email CHECK (email ~ '^[^@\s]+@[^@\s]+\.[a-z]+$'),
    city_id     smallint     NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    kyc_status  varchar(10)  NOT NULL
                CONSTRAINT chk_users_kyc CHECK (kyc_status IN ('PENDING', 'VERIFIED', 'REJECTED')),
    is_blocked  boolean      NOT NULL DEFAULT false,
    created_at  timestamptz  NOT NULL
);

-- ---------------------------------------------------------------- bank_accounts
CREATE TABLE bank_accounts (
    account_id     integer      PRIMARY KEY,
    user_id        integer      NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    bank_name      varchar(50)  NOT NULL,
    ifsc           varchar(11)  NOT NULL
                   CONSTRAINT chk_ba_ifsc CHECK (ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
    account_last4  varchar(4)   NOT NULL
                   CONSTRAINT chk_ba_last4 CHECK (account_last4 ~ '^[0-9]{4}$'),
    account_type   varchar(10)  NOT NULL
                   CONSTRAINT chk_ba_type CHECK (account_type IN ('SAVINGS', 'CURRENT')),
    is_primary     boolean      NOT NULL DEFAULT false,
    linked_at      timestamptz  NOT NULL,
    -- the first 4 letters of an IFSC identify the bank
    CONSTRAINT chk_ba_ifsc_bank CHECK (left(ifsc, 4) = CASE bank_name
        WHEN 'Axis Bank'            THEN 'UTIB'  WHEN 'Bank of Baroda'      THEN 'BARB'
        WHEN 'HDFC Bank'            THEN 'HDFC'  WHEN 'ICICI Bank'          THEN 'ICIC'
        WHEN 'Kotak Mahindra Bank'  THEN 'KKBK'  WHEN 'Punjab National Bank' THEN 'PUNB'
        WHEN 'State Bank of India'  THEN 'SBIN'  WHEN 'Yes Bank'            THEN 'YESB'
        ELSE left(ifsc, 4) END),
    -- target of the composite FK from vpas: a VPA's account must belong to the same user
    CONSTRAINT uq_ba_account_user UNIQUE (account_id, user_id)
);
-- at most one primary account per user
CREATE UNIQUE INDEX uq_ba_one_primary_per_user ON bank_accounts (user_id) WHERE is_primary;

-- ---------------------------------------------------------------- vpas
CREATE TABLE vpas (
    vpa         varchar(100) PRIMARY KEY                  -- natural key: the UPI ID is globally unique
                CONSTRAINT chk_vpas_format CHECK (vpa ~ '^[a-z0-9._-]+@[a-z]+$'),
    user_id     integer      NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    account_id  integer      NOT NULL,
    is_active   boolean      NOT NULL DEFAULT true,
    created_at  timestamptz  NOT NULL,
    CONSTRAINT fk_vpas_account_same_user FOREIGN KEY (account_id, user_id)
        REFERENCES bank_accounts(account_id, user_id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------- merchants
CREATE TABLE merchants (
    merchant_id    integer      PRIMARY KEY,
    merchant_name  varchar(100) NOT NULL,
    mcc            varchar(4)   NOT NULL
                   CONSTRAINT chk_merchants_mcc CHECK (mcc ~ '^[0-9]{4}$'),
    merchant_vpa   varchar(100) NOT NULL UNIQUE
                   CONSTRAINT chk_merchants_vpa CHECK (merchant_vpa ~ '^[a-z0-9._-]+@[a-z]+$'),
    city_id        smallint     NOT NULL REFERENCES cities(city_id) ON DELETE RESTRICT,
    is_verified    boolean      NOT NULL DEFAULT false,
    onboarded_on   date         NOT NULL,
    -- target of the composite FK from transactions: P2M payee must be the merchant's VPA
    CONSTRAINT uq_merchants_id_vpa UNIQUE (merchant_id, merchant_vpa)
);

-- ---------------------------------------------------------------- transactions
CREATE TABLE transactions (
    txn_id        bigint        PRIMARY KEY,
    upi_ref       varchar(12)   NOT NULL UNIQUE
                  CONSTRAINT chk_txn_upi_ref CHECK (upi_ref ~ '^[0-9]{12}$'),
    txn_type      varchar(3)    NOT NULL
                  CONSTRAINT chk_txn_type CHECK (txn_type IN ('P2P', 'P2M')),
    payer_vpa     varchar(100)  NOT NULL REFERENCES vpas(vpa) ON DELETE RESTRICT,
    -- no FK: P2P payees may be on another UPI app (@ybl, @paytm, @ibl, @axl); P2M payees are merchants
    payee_vpa     varchar(100)  NOT NULL
                  CONSTRAINT chk_txn_payee_format CHECK (payee_vpa ~ '^[a-z0-9._-]+@[a-z]+$'),
    merchant_id   integer,      -- NULL for P2P payments
    amount        numeric(10,2) NOT NULL
                  CONSTRAINT chk_txn_amount CHECK (amount > 0 AND amount <= 100000),  -- UPI cap ₹1,00,000
    note          varchar(100),
    initiated_at  timestamptz   NOT NULL,
    completed_at  timestamptz,  -- NULL while PENDING
    status        varchar(10)   NOT NULL
                  CONSTRAINT chk_txn_status CHECK (status IN ('PENDING', 'SUCCESS', 'FAILED', 'REVERSED', 'REFUNDED')),
    failure_code  varchar(3)    -- NPCI code, only for FAILED
                  CONSTRAINT chk_txn_failure_code CHECK (failure_code IN ('U16', 'U30', 'U69', 'XH', 'Z9', 'ZM')),
    CONSTRAINT chk_txn_p2m_merchant    CHECK ((txn_type = 'P2M') = (merchant_id IS NOT NULL)),
    CONSTRAINT chk_txn_failed_code     CHECK ((status = 'FAILED') = (failure_code IS NOT NULL)),
    CONSTRAINT chk_txn_pending_open    CHECK ((status = 'PENDING') = (completed_at IS NULL)),
    CONSTRAINT chk_txn_completed_after CHECK (completed_at >= initiated_at),
    CONSTRAINT chk_txn_refund_p2m      CHECK (status <> 'REFUNDED' OR txn_type = 'P2M'),
    CONSTRAINT chk_txn_not_self        CHECK (payer_vpa <> payee_vpa),
    -- MATCH SIMPLE: only checked when merchant_id is not NULL (P2M), then payee_vpa must equal merchant_vpa
    CONSTRAINT fk_txn_merchant FOREIGN KEY (merchant_id, payee_vpa)
        REFERENCES merchants(merchant_id, merchant_vpa) ON DELETE RESTRICT
);

-- ---------------------------------------------------------------- rewards
CREATE TABLE rewards (
    reward_id    integer      PRIMARY KEY,
    user_id      integer      NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    txn_id       bigint       NOT NULL UNIQUE REFERENCES transactions(txn_id) ON DELETE RESTRICT,
    reward_type  varchar(12)  NOT NULL
                 CONSTRAINT chk_rw_type CHECK (reward_type IN ('SCRATCH_CARD', 'CASHBACK', 'COUPON')),
    amount       numeric(8,2) NOT NULL
                 CONSTRAINT chk_rw_amount CHECK (amount >= 0),   -- 0.00 = "better luck next time"
    status       varchar(11)  NOT NULL
                 CONSTRAINT chk_rw_status CHECK (status IN ('UNSCRATCHED', 'CREDITED', 'EXPIRED')),
    issued_at    timestamptz  NOT NULL,
    expires_at   timestamptz  NOT NULL,
    credited_at  timestamptz,
    CONSTRAINT chk_rw_expiry   CHECK (expires_at > issued_at),
    CONSTRAINT chk_rw_credited CHECK ((status = 'CREDITED') = (credited_at IS NOT NULL)),
    CONSTRAINT chk_rw_credit_window CHECK (credited_at BETWEEN issued_at AND expires_at)
);

-- ---------------------------------------------------------------- bill_payments
CREATE TABLE bill_payments (
    bill_id          integer       PRIMARY KEY,
    user_id          integer       NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    biller_category  varchar(12)   NOT NULL
                     CONSTRAINT chk_bill_category CHECK (biller_category IN
                       ('MOBILE', 'ELECTRICITY', 'WATER', 'GAS', 'BROADBAND', 'DTH', 'FASTAG')),
    biller_name      varchar(50)   NOT NULL,
    consumer_number  varchar(20)   NOT NULL
                     CONSTRAINT chk_bill_consumer CHECK (consumer_number ~ '^[0-9]+$'),
    amount           numeric(10,2) NOT NULL
                     CONSTRAINT chk_bill_amount CHECK (amount > 0),
    due_date         date          NOT NULL,
    status           varchar(7)    NOT NULL
                     CONSTRAINT chk_bill_status CHECK (status IN ('DUE', 'PAID', 'OVERDUE')),
    paid_at          timestamptz,
    CONSTRAINT chk_bill_paid CHECK ((status = 'PAID') = (paid_at IS NOT NULL))
);

-- ---------------------------------------------------------------- disputes
CREATE TABLE disputes (
    dispute_id   integer      PRIMARY KEY,
    txn_id       bigint       NOT NULL REFERENCES transactions(txn_id) ON DELETE RESTRICT,
    raised_by    integer      NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    reason       varchar(30)  NOT NULL
                 CONSTRAINT chk_dsp_reason CHECK (reason IN ('MONEY_DEBITED_NOT_CREDITED', 'WRONG_PAYEE',
                   'DUPLICATE_PAYMENT', 'MERCHANT_NOT_DELIVERED', 'FRAUD')),
    raised_at    timestamptz  NOT NULL,
    status       varchar(8)   NOT NULL
                 CONSTRAINT chk_dsp_status CHECK (status IN ('OPEN', 'RESOLVED', 'REJECTED')),
    resolved_at  timestamptz,
    CONSTRAINT chk_dsp_resolved CHECK ((status = 'OPEN') = (resolved_at IS NULL)),
    CONSTRAINT chk_dsp_order    CHECK (resolved_at > raised_at)
);
