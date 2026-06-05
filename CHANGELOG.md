# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-06-05

### Added

- Initial public release.
- Model change tracking (create / update / destroy) via ActiveRecord callbacks,
  grouped per request and per transaction.
- Controller-level auditing with automatic event-type generation.
- Error reporting through `audit_error(error, status)`.
- Bulk operation tracking for `update_all` / `delete_all` (opt-in).
- `has_and_belongs_to_many` join-table change tracking.
- Recursive sensitive-data filtering with global and per-model attribute lists.
- Pluggable value providers (username, roles, remote IP, origin IP, session id).
- Configurable delivery hooks for shipping audit events to any sink.
- Transaction-aware delivery: events are flushed only after every transaction
  has committed, and discarded on rollback.

[Unreleased]: https://github.com/inikalaev/provenance/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/inikalaev/provenance/releases/tag/v1.0.0
