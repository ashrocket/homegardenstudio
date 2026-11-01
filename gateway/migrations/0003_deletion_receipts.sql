-- Allow a lost DELETE response to be retried without restoring account access.
-- Only a hash of the already-authenticated bearer is retained, for at most 30 days
-- after cleanup completes. Pending cleanup may be resumed with that same bearer.
CREATE TABLE account_deletion_receipts (
  secret_hash TEXT PRIMARY KEY CHECK (length(secret_hash) = 64),
  account_id TEXT NOT NULL REFERENCES accounts(id),
  created_at INTEGER NOT NULL,
  completed_at INTEGER
);
CREATE INDEX deletion_receipts_expiry ON account_deletion_receipts(completed_at);
