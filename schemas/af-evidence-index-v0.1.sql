PRAGMA foreign_keys = ON;
PRAGMA journal_mode = DELETE;
PRAGMA user_version = 1;

CREATE TABLE index_metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE batches (
  batch_id TEXT PRIMARY KEY,
  manifest_schema_version TEXT NOT NULL,
  manifest_sha256 TEXT NOT NULL CHECK(length(manifest_sha256) = 64),
  bundle_filename TEXT NOT NULL,
  bundle_format TEXT NOT NULL,
  bundle_profile_version TEXT NOT NULL,
  bundle_byte_size INTEGER NOT NULL CHECK(bundle_byte_size > 0),
  bundle_sha256 TEXT NOT NULL CHECK(length(bundle_sha256) = 64),
  member_count INTEGER NOT NULL CHECK(member_count > 0)
) WITHOUT ROWID;

CREATE TABLE members (
  batch_id TEXT NOT NULL,
  member_path TEXT NOT NULL,
  byte_size INTEGER NOT NULL CHECK(byte_size >= 0),
  sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
  job_key TEXT,
  run_id TEXT,
  PRIMARY KEY (batch_id, member_path),
  FOREIGN KEY (batch_id) REFERENCES batches(batch_id) ON DELETE CASCADE
) WITHOUT ROWID;

CREATE TABLE jobs (
  batch_id TEXT NOT NULL,
  job_key TEXT NOT NULL,
  job_id TEXT NOT NULL,
  adventure_id TEXT NOT NULL,
  dimension TEXT NOT NULL,
  model_alias TEXT,
  model TEXT,
  status TEXT NOT NULL,
  replicate INTEGER,
  worker TEXT,
  started_at TEXT,
  completed_at TEXT,
  elapsed_seconds REAL,
  exit_status INTEGER,
  estimated_cost_usd REAL,
  metadata_member_path TEXT NOT NULL,
  PRIMARY KEY (batch_id, job_key),
  FOREIGN KEY (batch_id) REFERENCES batches(batch_id) ON DELETE CASCADE,
  FOREIGN KEY (batch_id, metadata_member_path)
    REFERENCES members(batch_id, member_path)
) WITHOUT ROWID;

CREATE TABLE runs (
  batch_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  job_key TEXT NOT NULL,
  job_id TEXT NOT NULL,
  adventure_id TEXT NOT NULL,
  dimension TEXT NOT NULL,
  provider TEXT,
  model TEXT,
  prompt_profile TEXT,
  afao_version TEXT,
  assessment_spec_version TEXT,
  reasoning_effort TEXT,
  source_scope TEXT,
  experimental INTEGER CHECK(experimental IN (0, 1) OR experimental IS NULL),
  run_metadata_member_path TEXT NOT NULL,
  PRIMARY KEY (batch_id, run_id),
  FOREIGN KEY (batch_id) REFERENCES batches(batch_id) ON DELETE CASCADE,
  FOREIGN KEY (batch_id, job_key) REFERENCES jobs(batch_id, job_key),
  FOREIGN KEY (batch_id, run_metadata_member_path)
    REFERENCES members(batch_id, member_path)
) WITHOUT ROWID;

CREATE INDEX members_by_job
  ON members(batch_id, job_key, member_path);
CREATE INDEX members_by_run
  ON members(batch_id, run_id, member_path);
CREATE INDEX jobs_by_job_id
  ON jobs(job_id, batch_id, job_key);
CREATE INDEX jobs_by_adventure_dimension
  ON jobs(adventure_id, dimension, batch_id, job_key);
CREATE INDEX jobs_by_model
  ON jobs(model, model_alias, batch_id, job_key);
CREATE INDEX jobs_by_status
  ON jobs(status, batch_id, job_key);
CREATE INDEX runs_by_adventure_dimension
  ON runs(adventure_id, dimension, batch_id, run_id);
CREATE INDEX runs_by_model
  ON runs(model, batch_id, run_id);
