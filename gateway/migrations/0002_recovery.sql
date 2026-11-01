-- Signed state survives notification-before-registration and is ordered by Apple's signedDate.
CREATE TABLE storekit_states (
  transaction_id TEXT PRIMARY KEY,
  signed_date INTEGER NOT NULL,
  revoked_at INTEGER,
  original_transaction_id TEXT NOT NULL,
  product_id TEXT NOT NULL,
  store_environment TEXT NOT NULL,
  account_token TEXT NOT NULL
);
CREATE TABLE storekit_events (notification_id TEXT PRIMARY KEY, transaction_id TEXT NOT NULL, signed_date INTEGER NOT NULL);
ALTER TABLE quotes ADD COLUMN input_digest TEXT NOT NULL DEFAULT '';
ALTER TABLE quotes ADD COLUMN destination_digest TEXT NOT NULL DEFAULT '';
ALTER TABLE quotes ADD COLUMN window_id TEXT;
ALTER TABLE quotes ADD COLUMN balance_environment TEXT;
ALTER TABLE jobs ADD COLUMN request_digest TEXT NOT NULL DEFAULT '';
ALTER TABLE jobs ADD COLUMN recovery_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE jobs ADD COLUMN result_expires_at INTEGER;
ALTER TABLE jobs ADD COLUMN acknowledged_at INTEGER;
CREATE TABLE job_results (
  job_id TEXT NOT NULL REFERENCES jobs(id),
  part INTEGER NOT NULL,
  ciphertext TEXT NOT NULL,
  iv TEXT NOT NULL,
  kek_version INTEGER NOT NULL,
  PRIMARY KEY(job_id, part)
);
-- Deletes and concurrent account mutations cannot resurrect custody or start paid work.
CREATE TRIGGER key_active_insert BEFORE INSERT ON provider_keys BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM accounts WHERE id=NEW.account_id AND deleted_at IS NULL) THEN RAISE(ABORT,'inactive account') END;
END;
CREATE TRIGGER key_active_update BEFORE UPDATE ON provider_keys BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM accounts WHERE id=NEW.account_id AND deleted_at IS NULL) THEN RAISE(ABORT,'inactive account') END;
END;
CREATE TRIGGER quote_active BEFORE INSERT ON quotes BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM accounts WHERE id=NEW.account_id AND deleted_at IS NULL) THEN RAISE(ABORT,'inactive account') END;
END;
CREATE TRIGGER job_active BEFORE INSERT ON jobs BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM accounts WHERE id=NEW.account_id AND deleted_at IS NULL) THEN RAISE(ABORT,'inactive account') END;
END;
-- A conservative operator ceiling includes failures/uncertain upstream acceptance; refunds do not release it.
CREATE TABLE operator_spend (
  day_key TEXT PRIMARY KEY,
  spent_micros INTEGER NOT NULL CHECK(spent_micros>=0),
  cap_micros INTEGER NOT NULL CHECK(cap_micros>0),
  CHECK(spent_micros<=cap_micros)
);
