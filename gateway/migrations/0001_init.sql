-- HomeGardenStudio gateway: initial schema.
-- All timestamps are integer milliseconds since the Unix epoch. All money is integer micro-USD.
-- Guards are enforced by the database (CHECK / UNIQUE) so a D1 batch aborts as a whole.

CREATE TABLE accounts (
  id TEXT PRIMARY KEY CHECK (length(id) = 36),
  secret_hash TEXT UNIQUE CHECK (secret_hash IS NULL OR length(secret_hash) = 64),
  created_at INTEGER NOT NULL,
  deleted_at INTEGER,
  monthly_cap_micros INTEGER CHECK (monthly_cap_micros IS NULL OR (monthly_cap_micros >= 0 AND monthly_cap_micros <= 500000000)),
  CHECK ((deleted_at IS NULL AND secret_hash IS NOT NULL) OR (deleted_at IS NOT NULL AND secret_hash IS NULL))
);

CREATE TABLE rate_limits (
  bucket TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket, window_start)
);

-- Provider keys: AES-256-GCM ciphertext only. There is no plaintext column and no read-back route.
CREATE TABLE provider_keys (
  account_id TEXT NOT NULL REFERENCES accounts(id),
  provider TEXT NOT NULL CHECK (provider IN ('openai', 'anthropic', 'custom')),
  ciphertext TEXT NOT NULL,
  iv TEXT NOT NULL,
  kek_version INTEGER NOT NULL CHECK (kek_version >= 1),
  label TEXT,
  fingerprint TEXT NOT NULL CHECK (length(fingerprint) = 12),
  endpoint TEXT,
  endpoint_host TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, provider),
  CHECK ((provider = 'custom') = (endpoint IS NOT NULL))
);
CREATE INDEX provider_keys_kek_version ON provider_keys (kek_version);

CREATE TABLE balances (
  account_id TEXT NOT NULL REFERENCES accounts(id),
  environment TEXT NOT NULL CHECK (environment IN ('production', 'sandbox')),
  micros INTEGER NOT NULL DEFAULT 0 CONSTRAINT balances_nonnegative CHECK (micros >= 0),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, environment)
);

-- Append-only record of every credit movement. amount_micros is signed.
-- source 'sponsor_window' rows never touch the customer balance.
CREATE TABLE ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id TEXT NOT NULL REFERENCES accounts(id),
  source TEXT NOT NULL DEFAULT 'balance' CHECK (source IN ('balance', 'sponsor_window')),
  environment TEXT CHECK (environment IS NULL OR environment IN ('production', 'sandbox')),
  kind TEXT NOT NULL CHECK (kind IN ('grant', 'debit', 'job_refund', 'clawback', 'clawback_reversal')),
  amount_micros INTEGER NOT NULL,
  idempotency_key TEXT NOT NULL CONSTRAINT ledger_idempotency UNIQUE,
  ref TEXT,
  created_at INTEGER NOT NULL,
  CHECK ((source = 'balance') = (environment IS NOT NULL)),
  CHECK (
    (kind IN ('grant', 'job_refund', 'clawback_reversal') AND amount_micros >= 0)
    OR (kind IN ('debit', 'clawback') AND amount_micros <= 0)
  )
);
CREATE INDEX ledger_account ON ledger (account_id, id);

-- Verified App Store transactions, keyed by transactionId.
CREATE TABLE transactions (
  transaction_id TEXT PRIMARY KEY,
  original_transaction_id TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id),
  product_id TEXT NOT NULL,
  store_environment TEXT NOT NULL CHECK (store_environment IN ('Production', 'Sandbox', 'Xcode')),
  balance_environment TEXT NOT NULL CHECK (balance_environment IN ('production', 'sandbox')),
  purchase_date INTEGER,
  status TEXT NOT NULL CHECK (status IN ('granted', 'pending_prerequisite', 'revoked')),
  credit_granted_micros INTEGER NOT NULL DEFAULT 0 CHECK (credit_granted_micros >= 0),
  clawed_back_micros INTEGER NOT NULL DEFAULT 0 CHECK (clawed_back_micros >= 0),
  shortfall_micros INTEGER NOT NULL DEFAULT 0 CHECK (shortfall_micros >= 0),
  revoked_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX transactions_account ON transactions (account_id, status);
CREATE INDEX transactions_original ON transactions (original_transaction_id);

-- Original transaction ownership is unique and requires a matching verified appAccountToken. No automatic transfer.
CREATE TABLE transaction_bindings (
  original_transaction_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id),
  created_at INTEGER NOT NULL
);

-- A refund/revoke notification can arrive before the app ever posts the transaction.
CREATE TABLE storekit_revocations (
  transaction_id TEXT PRIMARY KEY,
  original_transaction_id TEXT,
  notification_type TEXT NOT NULL,
  revoked_at INTEGER NOT NULL
);

CREATE TABLE quotes (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id),
  provider TEXT NOT NULL CHECK (provider IN ('managed', 'openai', 'custom')),
  model TEXT NOT NULL,
  size TEXT NOT NULL,
  quality TEXT NOT NULL,
  debit_micros INTEGER NOT NULL CHECK (debit_micros >= 0),
  funding TEXT NOT NULL CHECK (funding IN ('balance', 'sponsor_window', 'provider')),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_at INTEGER,
  CHECK (expires_at > created_at),
  CHECK ((provider = 'managed') = (funding IN ('balance', 'sponsor_window'))),
  CHECK (provider = 'managed' OR debit_micros = 0),
  CHECK (provider <> 'managed' OR debit_micros > 0)
);
CREATE INDEX quotes_account ON quotes (account_id, created_at);

CREATE TABLE jobs (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id),
  idempotency_key TEXT NOT NULL,
  quote_id TEXT NOT NULL REFERENCES quotes(id) CONSTRAINT jobs_quote_once UNIQUE,
  provider TEXT NOT NULL CHECK (provider IN ('managed', 'openai', 'custom')),
  model TEXT NOT NULL,
  size TEXT NOT NULL,
  quality TEXT NOT NULL,
  debit_micros INTEGER NOT NULL CHECK (debit_micros >= 0),
  funding TEXT NOT NULL CHECK (funding IN ('balance', 'sponsor_window', 'provider')),
  balance_environment TEXT CHECK (balance_environment IS NULL OR balance_environment IN ('production', 'sandbox')),
  window_id TEXT,
  month_key TEXT,
  status TEXT NOT NULL CHECK (status IN ('pending', 'succeeded', 'failed')),
  error_code TEXT,
  created_at INTEGER NOT NULL,
  completed_at INTEGER,
  CONSTRAINT jobs_idempotency UNIQUE (account_id, idempotency_key)
);
CREATE INDEX jobs_pending ON jobs (status, created_at);

-- Spend counted against the optional monthly cap. cap_micros is refreshed from accounts on every debit.
CREATE TABLE month_spend (
  account_id TEXT NOT NULL REFERENCES accounts(id),
  month_key TEXT NOT NULL CHECK (month_key GLOB '[0-9][0-9][0-9][0-9]-[01][0-9]'),
  spent_micros INTEGER NOT NULL DEFAULT 0 CONSTRAINT month_spend_nonnegative CHECK (spent_micros >= 0),
  cap_micros INTEGER,
  PRIMARY KEY (account_id, month_key),
  CONSTRAINT month_spend_cap CHECK (cap_micros IS NULL OR spent_micros <= cap_micros)
);

-- Sponsorship: approved inventory only. The owner inserts rows by hand (see SPONSORS.md).
-- A sponsor stays 'paused' until the owner sets 'active'.
CREATE TABLE sponsors (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  category TEXT NOT NULL CONSTRAINT sponsors_category CHECK (category IN ('democratic_candidate', 'democratic_issue')),
  paid_for_by TEXT NOT NULL CHECK (length(trim(paid_for_by)) > 0),
  approved_by TEXT NOT NULL CHECK (length(trim(approved_by)) > 0),
  approved_at INTEGER NOT NULL CHECK (approved_at > 0),
  status TEXT NOT NULL DEFAULT 'paused' CHECK (status IN ('active', 'paused', 'ended')),
  budget_total_micros INTEGER NOT NULL CHECK (budget_total_micros > 0),
  budget_remaining_micros INTEGER NOT NULL CONSTRAINT sponsors_budget_nonnegative CHECK (budget_remaining_micros >= 0),
  created_at INTEGER NOT NULL,
  CHECK (budget_remaining_micros <= budget_total_micros)
);

CREATE TABLE sponsor_offers (
  id TEXT PRIMARY KEY,
  sponsor_id TEXT NOT NULL REFERENCES sponsors(id),
  disclosure TEXT NOT NULL CHECK (length(trim(disclosure)) > 0),
  report_url TEXT NOT NULL CHECK (report_url LIKE 'https://%'),
  status TEXT NOT NULL DEFAULT 'paused' CHECK (status IN ('active', 'paused', 'ended')),
  starts_at INTEGER,
  ends_at INTEGER,
  created_at INTEGER NOT NULL,
  CHECK (starts_at IS NULL OR ends_at IS NULL OR ends_at > starts_at)
);

CREATE TABLE sponsor_offer_windows (
  offer_id TEXT NOT NULL REFERENCES sponsor_offers(id),
  minutes INTEGER NOT NULL CHECK (minutes IN (30, 120, 240, 480, 720, 1440)),
  credit_cap_micros INTEGER NOT NULL CHECK (credit_cap_micros > 0),
  PRIMARY KEY (offer_id, minutes)
);

-- One funded window: a finite credit cap AND a finite expiry. Kept apart from customer balances.
CREATE TABLE sponsor_windows (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id),
  offer_id TEXT NOT NULL REFERENCES sponsor_offers(id),
  sponsor_id TEXT NOT NULL REFERENCES sponsors(id),
  minutes INTEGER NOT NULL CHECK (minutes IN (30, 120, 240, 480, 720, 1440)),
  credit_cap_micros INTEGER NOT NULL CHECK (credit_cap_micros > 0),
  remaining_micros INTEGER NOT NULL,
  starts_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  settled_at INTEGER,
  returned_micros INTEGER NOT NULL DEFAULT 0 CHECK (returned_micros >= 0),
  CONSTRAINT sponsor_windows_remaining CHECK (remaining_micros >= 0 AND remaining_micros <= credit_cap_micros),
  CHECK (expires_at - starts_at = minutes * 60000)
);
-- At most one window per account that has not been settled back to the sponsor.
CREATE UNIQUE INDEX sponsor_windows_one_active ON sponsor_windows (account_id) WHERE settled_at IS NULL;
CREATE INDEX sponsor_windows_sponsor ON sponsor_windows (sponsor_id);

CREATE TABLE sponsor_reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  offer_id TEXT NOT NULL REFERENCES sponsor_offers(id),
  account_id TEXT REFERENCES accounts(id),
  reason TEXT NOT NULL CHECK (length(reason) BETWEEN 1 AND 1000),
  created_at INTEGER NOT NULL
);

CREATE TABLE sponsor_dismissals (
  account_id TEXT NOT NULL REFERENCES accounts(id),
  offer_id TEXT NOT NULL REFERENCES sponsor_offers(id),
  until_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, offer_id)
);
