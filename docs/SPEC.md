# Provenance — functional specification

## 1. Positioning

Provenance answers **"who did what, through which entry point, with what outcome,
and which records changed"** — one *action-level* event per HTTP request, background
job, rake task or explicit block — and delivers it reliably to security and
observability tooling (SIEM, log pipelines, webhooks).

It is **not** a versioning/undo library. `paper_trail`, `audited` and `logidze` keep
per-record history inside the app database; Provenance emits tamper-evident,
standards-shaped events *out of* the app. The README must state this distinction.

Targets: Ruby >= 3.2, Rails >= 7.2 (uses `ActiveRecord.after_all_transactions_commit`
and per-transaction callbacks). MIT license.

## 2. Core concepts

- **Action** — a unit of user intent. Has a kind (`http`, `job`, `task`, `custom`),
  a name, an actor, request context, an outcome and the list of entity changes
  made while it was open. Exactly one event is emitted per action that is
  *auditable* (see 4.4).
- **Actor** — who performed the action: `id`, `type`, `display`, `roles` (array),
  optional `impersonator` (same shape) for "login as".
- **Entity change** — one record-level change: `entity` (class name), `entity_id`,
  `operation` (`create`/`update`/`destroy`/`link`/`unlink`/`bulk_update`/
  `bulk_delete`/`bulk_insert`), `diff` (`{attr => [before, after]}`; for create only
  `after`, for destroy only `before`), `association` (for link/unlink).
- **Event** — the immutable record emitted for an action (section 5).
- **Sink** — a destination for serialized events (section 6).

## 3. Public API

```ruby
Provenance.configure do |c|
  c.app_name = "billing"                       # default: Rails app module name, underscored
  c.enabled = !Rails.env.test?
  c.actor { |ctx| ... }                        # ctx exposes #controller, #job, #request, #env
  c.redact_attributes += %i[iban]              # merged with Rails filter_parameters
  c.format = :native                           # :native | :ocsf | :cloudevents
  c.sink :logger                               # repeatable; see section 6
  c.sink :http, url: ENV["AUDIT_URL"], headers: {...}
  c.outbox = true                              # section 6.2
  c.integrity.key = ENV["PROVENANCE_HMAC_KEY"]  # section 7; nil disables
  c.audit_reads = false                        # GET/HEAD actions without changes are skipped
  c.denied_exceptions = ["CanCan::AccessDenied", "Pundit::NotAuthorizedError"]
  c.bulk_ids_limit = 500
  c.on_error { |exception, event| ... }        # sink failures; default: Rails.logger.error
end

# Explicit action scope (console, scripts, custom flows); nestable — inner scopes
# attach their changes to the outermost action.
Provenance.action("users.import", actor: admin, metadata: { file: "x.csv" }) { ... }

# Attach data to the current action from anywhere.
Provenance.current&.annotate(reason: "GDPR request #42")
Provenance.current&.actor = some_user

# Opt-in per model
class Invoice < ApplicationRecord
  has_provenance only: %i[status amount], redact: %i[notes], associations: %i[tags]
  # or: except: [...]; `ignore_if: ->(record) { ... }`
end

Provenance.without { ... }   # suppress tracking inside the block
```

All public methods documented with YARD. No monkey-patching of core classes beyond
what section 4 requires, and every patch is opt-in per model.

## 4. Capture

### 4.1 HTTP
A Rack middleware (inserted automatically by a Railtie after `ActionDispatch::RequestId`)
opens the action and closes it after the response. Controller name/action, status,
request id, remote ip, user agent, HTTP method and path come from the request and the
`process_action.action_controller` instrumentation payload. Action name defaults to
`"#{controller_path}##{action_name}"`; overridable per controller with
`provenance_action_name ->(controller) { ... }` and skippable with `skip_provenance`.

### 4.2 Jobs and tasks
ActiveJob: an `around_perform` hook registered via `ActiveSupport.on_load(:active_job)`.
The enqueuing action's actor and action id are serialized into the job (as
`provenance` key in job metadata) so the job event carries `caused_by` = parent action id.
Rake: opt-in `Provenance::Rake.install!` wraps task invocation.

### 4.3 Model changes
`has_provenance` installs `after_create`/`after_update`/`after_destroy` hooks that read
`saved_changes` / `attributes` and append an entity change to the current action
(or to an implicit `custom` action named `"<Model>.<operation>"` if none is open).
Changes made inside a transaction are held per transaction using the Rails 7.2
transaction callback API; rolled-back transactions drop their changes.
`associations:` registers `after_add`/`after_remove` association callbacks producing
`link`/`unlink` changes. No SQL parsing anywhere.

Bulk: for opted-in models, `update_all`, `delete_all`, `insert_all`/`upsert_all`
on relations produce one `bulk_*` change with `count`, the `where` clause fingerprint
and up to `bulk_ids_limit` affected ids (`truncated: true` when exceeded). Ids are
fetched with a single `pluck` before the write, only when the relation is not already
loaded.

### 4.4 Emission
An action is emitted when it closes **and** all transactions it touched have committed
(`after_all_transactions_commit`). It is auditable if it has changes, or has a
non-success outcome, or is a non-read HTTP request, or `audit_reads` is on, or it was
opened explicitly. Outcome: `success`, `failure` (unhandled exception; `error.class`,
`error.message` truncated to 500 chars), `denied` (exception listed in
`denied_exceptions`). Exceptions are always re-raised.

## 5. Event

Native format, JSON Schema shipped in `schema/event-2.json` and validated in specs:

```json
{
  "schema": "provenance/event@2",
  "id": "0192f5c6-…",              // UUIDv7
  "occurred_at": "2026-10-05T12:00:00.123Z",
  "app": "billing",
  "action": { "kind": "http", "name": "invoices#update", "caused_by": null },
  "actor": { "id": "42", "type": "User", "display": "a@b.c", "roles": ["admin"], "impersonator": null },
  "request": { "id": "…", "method": "PATCH", "path": "/invoices/7", "status": 200, "ip": "…", "user_agent": "…" },
  "outcome": { "result": "success", "error": null },
  "changes": [ { "entity": "Invoice", "entity_id": "7", "operation": "update",
                 "diff": { "status": ["draft", "sent"] } } ],
  "metadata": {},
  "integrity": { "seq": 118, "prev": "…", "mac": "…" }   // only when enabled
}
```

Redacted values become `"[REDACTED]"`; diff values are JSON-safe (Time -> ISO8601,
BigDecimal -> string, binary -> `"[BINARY n bytes]"`).

Alternative serializers:
- `:ocsf` — OCSF 1.x *API Activity* (class_uid 6003) for HTTP/custom actions and
  *Entity Management* (3004) per change set; documented field mapping table in README.
- `:cloudevents` — CloudEvents 1.0 structured JSON, `type = "provenance.action.<kind>"`,
  `source = app`, `data` = native event.

## 6. Delivery

### 6.1 Sinks
Interface: `#deliver(batch)` where batch is an array of serialized events. Built-in:
`:logger` (one JSON line per event to Rails.logger or given logger), `:io` (any IO),
`:http` (Net::HTTP, JSON array POST, timeouts, retries with exponential backoff and
jitter, 2xx = success), `:proc`, `:memory` (tests). Kafka is an optional sink loaded
only if `rdkafka` is available (`require "provenance/sinks/kafka"`). A failing sink
never breaks the request: errors go to `on_error`.

### 6.2 Outbox (reliable mode)
With `outbox = true`, events are written to a `provenance_outbox` table instead of
being delivered inline (generator: `rails g provenance:install` creates migration +
initializer). `Provenance::RelayJob` drains pending rows in order (`FOR UPDATE SKIP
LOCKED` on PostgreSQL, plain ordering elsewhere), delivers to sinks, marks rows
delivered, retries failed rows with backoff, and prunes delivered rows older than
`outbox_retention` (default 7 days).

## 7. Integrity (tamper evidence)

When `integrity.key` is set, each event gets a monotonically increasing `seq` per app,
`prev` = mac of the previous event, `mac` = HMAC-SHA256(key, prev + canonical JSON of
the event without `integrity`). Canonical JSON: sorted keys, no whitespace. Sequence is
allocated from the outbox table (outbox required for integrity; config validation
raises otherwise). `Provenance::Integrity.verify(events, key:)` returns the first broken
seq or nil; `rake provenance:verify` checks the outbox.

## 8. Testing support

`require "provenance/rspec"` provides:
- `Provenance::Testing.capture { ... } # => [events]`
- matcher `expect { ... }.to emit_provenance_event(action: "invoices#update", outcome: "success").with_change(entity: "Invoice", operation: "update", diff: including(status: ["draft", "sent"]))`
- matcher `not_to emit_provenance_event`

## 9. Engineering requirements

- Layout: `lib/provenance.rb`, `lib/provenance/{configuration,action,actor,event,
  registry,middleware,railtie,model,serializers/*,sinks/*,outbox/*,integrity,testing}`.
  Choose names freely beyond these.
- Thread/fiber safety: action state lives in `ActiveSupport::IsolatedExecutionState`.
- Specs: RSpec with an internal dummy Rails app (sqlite in-memory) covering every
  section above; PostgreSQL job in CI for outbox locking.
- CI (GitHub Actions): matrix Ruby 3.2/3.3/3.4 × Rails 7.2/8.0, rubocop (standard
  style), YARD coverage check. Keep the tag-triggered RubyGems trusted-publishing
  release workflow.
- Docs: README (positioning, quick start, configuration, formats with OCSF mapping,
  outbox, integrity, testing, comparison with paper_trail/audited/logidze),
  CHANGELOG with a `2.0.0` entry, CONTRIBUTING,
  LICENSE (MIT, Ivan Nikolaev).
- Version `2.0.0`.
