# Provenance

Provenance answers **who did what, through which entry point, with what outcome, and
which records changed**. It emits one *action-level* event per HTTP request,
background job, rake task or explicit block, and delivers it reliably to security and
observability tooling: SIEM, log pipelines, webhooks, Kafka.

Provenance is **not** a versioning or undo library. [paper_trail], [audited] and
[logidze] keep per-record history inside your application database so you can show or
restore previous versions. Provenance emits tamper-evident, standards-shaped events
*out of* the application, one per user intent, with the record changes attached.

Requirements: Ruby >= 3.2, Rails >= 7.2. MIT license.

## Quick start

```ruby
# Gemfile
gem "provenance", "~> 2.0"
```

```sh
bin/rails g provenance:install   # outbox migration + config/initializers/provenance.rb
bin/rails db:migrate
```

```ruby
# config/initializers/provenance.rb
Provenance.configure do |c|
  c.enabled = !Rails.env.test?
  c.actor { |ctx| ctx.controller.try(:current_user) }
  c.sink :logger
end

# app/models/invoice.rb
class Invoice < ApplicationRecord
  has_provenance only: %i[status amount], redact: %i[notes], associations: %i[tags]
end
```

A `PATCH /invoices/7` that changes the status now emits:

```json
{
  "schema": "provenance/event@2",
  "id": "0192f5c6-7b1e-7cc2-9a51-0d4f6a8e2b10",
  "occurred_at": "2026-10-05T12:00:00.123Z",
  "app": "billing",
  "action": { "kind": "http", "name": "invoices#update", "caused_by": null },
  "actor": { "id": "42", "type": "User", "display": "a@b.c", "roles": ["admin"], "impersonator": null },
  "request": { "id": "3f1c…", "method": "PATCH", "path": "/invoices/7", "status": 200, "ip": "10.0.0.1", "user_agent": "…" },
  "outcome": { "result": "success", "error": null },
  "changes": [
    { "entity": "Invoice", "entity_id": "7", "operation": "update", "diff": { "status": ["draft", "sent"] } }
  ],
  "metadata": {}
}
```

The JSON Schema ships in [`schema/event-2.json`](schema/event-2.json).

## Concepts

- **Action** — a unit of user intent with a kind (`http`, `job`, `task`, `custom`),
  a name, an actor, request context, an outcome and the entity changes made while it
  was open. At most one event is emitted per action.
- **Actor** — `id`, `type`, `display`, `roles` and an optional `impersonator` of the
  same shape for "login as".
- **Entity change** — `entity`, `entity_id`, `operation` (`create`, `update`,
  `destroy`, `link`, `unlink`, `bulk_update`, `bulk_delete`, `bulk_insert`) and `diff`
  (`{attr => [before, after]}` for updates, `{attr => after}` for creates,
  `{attr => before}` for destroys).

### What gets captured

| Entry point | How | Action name |
|---|---|---|
| HTTP | Rack middleware inserted after `ActionDispatch::RequestId` | `"#{controller_path}##{action_name}"` |
| ActiveJob | `around_perform` | job class name |
| Rake | `Provenance::Rake.install!` (opt-in, e.g. in `Rakefile`) | task name |
| Explicit | `Provenance.action("users.import") { ... }` | given name |
| Model change outside any action | implicit `custom` action | `"Invoice.update"` |

An action is emitted when it closes **and** every transaction it touched has
committed. It is emitted if it has changes, has a non-success outcome, is a non-read
HTTP request (anything but GET/HEAD), was opened explicitly, or `audit_reads` is on.

Outcomes: `success`; `failure` for an unhandled exception (`error.class` and
`error.message`, truncated to 500 characters) or a 5xx response; `denied` for an
exception listed in `denied_exceptions` or a 401/403 response. Exceptions are always
re-raised.

Jobs enqueued inside an action carry the action id and actor in the job payload under
the `provenance` key, so the job event has `action.caused_by` set to the parent id.

## API

```ruby
Provenance.action("users.import", actor: admin, metadata: { file: "x.csv" }) do
  # nested Provenance.action blocks attach to the outermost action
end

Provenance.current&.annotate(reason: "GDPR request #42")
Provenance.current&.actor = some_user

Provenance.without { Invoice.update_all(viewed: true) }   # suppress tracking

class Admin::ReportsController < ApplicationController
  provenance_action_name ->(controller) { "admin.reports.#{controller.action_name}" }
  skip_provenance only: :preview
end

class CleanupJob < ApplicationJob
  skip_provenance
end
```

### Models

```ruby
class Invoice < ApplicationRecord
  has_many :tags
  has_provenance only: %i[status amount],        # or except: [...]
    redact: %i[notes],                            # recorded as "[REDACTED]"
    associations: %i[tags],                       # link/unlink changes
    ignore_if: ->(invoice) { invoice.draft? }
end
```

`has_provenance` must come after the association declarations it references. Changes
are held per transaction and dropped if it rolls back. Bulk operations on tracked
models — `update_all`, `delete_all`, `insert_all`, `upsert_all` (and the methods built
on them) — produce one `bulk_*` change with `count`, a `where` fingerprint (SHA-256 of
the WHERE clause with bind values replaced by placeholders) and up to `bulk_ids_limit`
affected `ids` (`truncated: true` when cut). Ids come from a single `pluck` before the
write, or from the records when the relation is already loaded. `created_at` and
`updated_at` are ignored by default (`c.ignored_attributes`), as are primary keys.

### Actor resolution

`c.actor { |ctx| ... }` receives a context with `#controller`, `#job`, `#request` and
`#env` and returns a user-like object, a Hash or a `Provenance::Actor`. Objects are
read through `provenance_actor` (returning a Hash) if defined, otherwise `id`,
`provenance_display`/`email`/`name` and `provenance_roles`. Resolver errors are
reported to `on_error`; the event is emitted without an actor.

## Configuration

```ruby
Provenance.configure do |c|
  c.app_name = "billing"                       # default: Rails app module name, underscored
  c.enabled = !Rails.env.test?                 # default: true
  c.actor { |ctx| ctx.controller.try(:current_user) }
  c.redact_attributes += %i[iban]              # merged with Rails filter_parameters
  c.ignored_attributes = %w[created_at updated_at]
  c.format = :native                           # :native | :ocsf | :cloudevents
  c.sink :logger                               # repeatable
  c.sink :http, url: ENV["AUDIT_URL"], headers: { "Authorization" => "Bearer …" }
  c.outbox = true
  c.outbox_retention = 7.days
  c.outbox_batch_size = 100
  c.outbox_enqueue_relay = true                # enqueue RelayJob after each write
  c.integrity.key = ENV["PROVENANCE_HMAC_KEY"]  # nil disables
  c.audit_reads = false                        # GET/HEAD actions without changes are skipped
  c.denied_exceptions = ["CanCan::AccessDenied", "Pundit::NotAuthorizedError"]
  c.bulk_ids_limit = 500
  c.on_error { |exception, event| Rails.error.report(exception) }  # default: Rails.logger.error
end
```

Redaction uses `ActiveSupport::ParameterFilter`, so `filter_parameters` entries such
as `:passw` match partially. Redacted values become `"[REDACTED]"`; a `nil` side of an
update stays `nil`. Encrypted attributes are always redacted. Event metadata is
filtered the same way. Diff values are JSON-safe: times become ISO 8601, `BigDecimal`
a string, binary strings `"[BINARY n bytes]"`.

## Delivery

### Sinks

A sink is any object with `#deliver(batch)`, where `batch` is an Array of serialized
events (Hashes). A failing sink never breaks the request: errors go to `on_error`
and the other sinks still receive the batch.

| Sink | Options |
|---|---|
| `:logger` | `logger:` (default `Rails.logger`), `level:` (default `:info`); one JSON line per event |
| `:io` | any IO, e.g. `c.sink :io, $stdout`; one JSON line per event |
| `:http` | `url:`, `headers:`, `open_timeout:`, `read_timeout:`, `retries:`, `backoff:`, `max_backoff:`; POSTs a JSON array, 2xx is success, exponential backoff with jitter |
| `:proc` | a callable or block: `c.sink(:proc) { |batch| ... }` |
| `:memory` | keeps events in memory, for tests |
| `:kafka` | `require "provenance/sinks/kafka"` (needs `rdkafka`); `topic:`, `config:` or `producer:`; one message per event keyed by event id |
| custom | `c.sink MySink.new` |

### Outbox

Inline delivery runs in the request thread after commit. For reliable delivery set
`c.outbox = true`: events are written to the `provenance_outbox` table and
`Provenance::RelayJob` delivers them.

The relay drains pending rows in id order (`FOR UPDATE SKIP LOCKED` on PostgreSQL,
plain ordering elsewhere), delivers each batch to every sink, marks rows delivered and
retries failed batches with exponential backoff (capped at one hour), stopping at the
first row that is not due so delivery order is kept. Delivered rows older than
`outbox_retention` are pruned; the newest row per app is kept as the anchor of the
integrity chain. Delivery is at-least-once: a batch that fails on one sink is retried
on all of them.

`RelayJob` is enqueued after each write by default. You can also schedule it (for
example with Solid Queue recurring tasks) and turn `outbox_enqueue_relay` off, or run
`bin/rails provenance:relay`.

## Formats

The format applies at delivery time; the outbox always stores native events.

### Native

`provenance/event@2`, described above and in `schema/event-2.json`.

### CloudEvents

CloudEvents 1.0 structured JSON:

| CloudEvents | Value |
|---|---|
| `specversion` | `"1.0"` |
| `id` | event `id` |
| `source` | `app` |
| `type` | `"provenance.action.<kind>"` |
| `subject` | action name |
| `time` | `occurred_at` |
| `datacontenttype` | `"application/json"` |
| `dataschema` | `"urn:provenance:event:2"` |
| `data` | the native event |

### OCSF

OCSF 1.3: every action becomes one **API Activity** event (`class_uid` 6003,
`category_uid` 6) and every entity change one **Entity Management** event
(`class_uid` 3004, `category_uid` 3), so a single native event may produce several
OCSF events. All of them share `metadata.correlation_uid` = native event id.

Common fields:

| OCSF | Source |
|---|---|
| `time` | `occurred_at` as epoch milliseconds |
| `metadata.version` | `"1.3.0"` |
| `metadata.uid` | event id (API Activity), `"<event id>/<change index>"` (Entity Management) |
| `metadata.correlation_uid` | event id |
| `metadata.log_name` | `app` |
| `metadata.product` | `{name: "Provenance", vendor_name: "Provenance", version}` |
| `actor.app_name` | `app` |
| `actor.user.uid` / `.name` / `.type` | `actor.id` / `actor.display` / `actor.type` |
| `actor.user.groups[].name` | `actor.roles` |
| `status_id` / `status` | `success` → 1 Success; `failure`, `denied` → 2 Failure |
| `status_detail` | `outcome.result` |
| `severity_id` | `success` 1 Informational, `failure` 2 Low, `denied` 3 Medium |
| `type_uid` | `class_uid * 100 + activity_id` |
| `unmapped.action` | native `action` |
| `unmapped.metadata` | native `metadata` |
| `unmapped.impersonator` | `actor.impersonator` |
| `unmapped.integrity` | native `integrity` |

API Activity (6003):

| OCSF | Source |
|---|---|
| `activity_id` | POST 1 Create, GET/HEAD 2 Read, PUT/PATCH 3 Update, DELETE 4 Delete; non-HTTP actions use the change operations when they agree, else 99 Other |
| `api.operation` | action name |
| `api.request.uid` | request id (event id for non-HTTP actions) |
| `api.response.code` | HTTP status |
| `api.response.error` / `.error_message` | `outcome.error.class` / `.message` |
| `src_endpoint.ip` | `request.ip` |
| `http_request.http_method` / `.url.path` / `.user_agent` / `.uid` | `request.method` / `.path` / `.user_agent` / `.id` |
| `http_response.code` | `request.status` |
| `resources[]` | `{type: entity, uid: entity_id}` per change |

Entity Management (3004):

| OCSF | Source |
|---|---|
| `activity_id` | `create`, `bulk_insert` 1 Create; `update`, `bulk_update` 3 Update; `destroy`, `bulk_delete` 4 Delete; `link`, `unlink` 99 Other (`activity_name` "Link"/"Unlink") |
| `entity.name`, `entity.type` | `entity` |
| `entity.uid` | `entity_id` |
| `entity.data` | `diff` |
| `unmapped.change` | `operation`, `association`, `target`, `count`, `where`, `ids`, `truncated` |

## Integrity

With `c.integrity.key` set (requires the outbox; configuration raises otherwise), each
event gets

```json
"integrity": { "seq": 118, "prev": "<mac of seq 117>", "mac": "<hex>" }
```

where `seq` increases monotonically per app, and
`mac = HMAC-SHA256(key, prev + canonical_json(event without "integrity"))`. Canonical
JSON has sorted object keys and no whitespace; `prev` is `null` for the first event and
counts as an empty string in the MAC input. Sequence numbers are allocated from the outbox table (an advisory transaction
lock on PostgreSQL, a unique index plus retry elsewhere).

```ruby
Provenance::Integrity.verify(events, key: ENV["PROVENANCE_HMAC_KEY"])  # => nil or first broken seq
```

`bin/rails provenance:verify` checks the chain stored in the outbox and exits non-zero
on a broken chain. Forward events to an append-only store to keep evidence beyond the
outbox retention window.

## Testing

```ruby
# spec/rails_helper.rb
require "provenance/rspec"
```

```ruby
events = Provenance::Testing.capture { post "/invoices", params: { ... } }

expect { patch invoice_path(invoice), params: { invoice: { status: "sent" } } }
  .to emit_provenance_event(action: "invoices#update", outcome: "success")
  .with_change(entity: "Invoice", operation: "update", diff: including(status: ["draft", "sent"]))

expect { get invoices_path }.not_to emit_provenance_event
```

While capturing, tracking is enabled even if `c.enabled` is false, and events go to the
capture instead of the outbox or sinks. The matcher accepts `action`, `kind`,
`caused_by`, `outcome`, `error`, `actor`, `actor_id`, `request`, `status`, `metadata`
and `app`, any RSpec composable matcher as a value, `.with_change(...)` (repeatable)
and `.exactly(n)` / `.once`.

## Comparison

| | Provenance | paper_trail | audited | logidze |
|---|---|---|---|---|
| Unit of record | one event per action (request, job, task, block) | one version per record change | one audit per record change | record history in a JSONB column |
| Stored in | external sinks (via outbox) | app database | app database | app database (triggers) |
| Undo / reify | no | yes | yes (revisions) | yes |
| Request context and outcome (failure/denied) | yes | via whodunnit/metadata | via request uuid/comment | via meta |
| Bulk operations | summarized per call | no | no | yes (triggers) |
| Tamper evidence | HMAC chain | no | no | no |
| Wire formats | native, OCSF, CloudEvents | — | — | — |

Use paper_trail, audited or logidze when the application itself needs record history.
Use Provenance when security or compliance tooling needs to know who did what. They
can be combined.

## License

MIT, see [LICENSE](LICENSE).

[paper_trail]: https://github.com/paper-trail-gem/paper_trail
[audited]: https://github.com/collectiveidea/audited
[logidze]: https://github.com/palkan/logidze
