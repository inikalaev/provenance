# Changelog

## 2.0.0 — complete rewrite, incompatible with 1.x

- One action-level event per HTTP request, ActiveJob job, rake task or explicit
  `Provenance.action` block, with actor, request context, outcome and entity changes.
- Opt-in model tracking with `has_provenance` (`only`, `except`, `redact`,
  `associations`, `ignore_if`), link/unlink changes and bulk `update_all`,
  `delete_all`, `insert_all`/`upsert_all` changes.
- Emission after all touched transactions commit; rolled-back changes are dropped.
- Native event format with a shipped JSON Schema (`schema/event-2.json`), plus OCSF
  1.x and CloudEvents 1.0 serializers.
- Sinks: logger, IO, HTTP (retries with backoff and jitter), proc, memory and
  optional Kafka.
- Outbox table with `Provenance::RelayJob`, `FOR UPDATE SKIP LOCKED` on PostgreSQL,
  retries and retention pruning; `rails g provenance:install`.
- HMAC-SHA256 integrity chain with `Provenance::Integrity.verify` and
  `rake provenance:verify`.
- RSpec support: `Provenance::Testing.capture` and the `emit_provenance_event` matcher.
