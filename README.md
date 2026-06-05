<div align="center">

# 📜 Provenance

### A drop-in audit trail for Rails — every user action and model change, captured.

[![CI](https://github.com/inikalaev/provenance/actions/workflows/ci.yml/badge.svg)](https://github.com/inikalaev/provenance/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/provenance.svg)](https://rubygems.org/gems/provenance)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-CC342D.svg)](.ruby-version)

</div>

---

Provenance watches your Rails app and records **who did what, to which record, when** — then ships
a structured event anywhere you want: a log pipeline, a data warehouse, an external SIEM, or just
`Rails.logger`. You wire it in once; it stays out of your controllers and models.

```ruby
# An audit event Provenance produces for a successful request
{
  "event_type": "create_users",
  "status": 201,
  "username": "admin@example.com",
  "remote_ip": "203.0.113.1",
  "message": {
    "count": 1,
    "changes": [
      { "model": "User", "model_id": 42, "action": "create",
        "changes": { "attributes": { "email": "user@example.com", "password": "[FILTERED]" } } }
    ]
  },
  "source": "myapp_production"
}
```

## ✨ Features

- 🧾 **Model change tracking** — `create` / `update` / `destroy` captured straight from ActiveRecord callbacks.
- 🌐 **Controller auditing** — one `around_action` records every change made during a request and emits a single event.
- 🧬 **Transaction-aware** — changes are grouped per transaction, flushed only after every transaction commits, and **discarded on rollback**.
- 💥 **Error reporting** — emit a dedicated audit event for failed requests with `audit_error`.
- 🗂️ **Bulk operations** — opt-in tracking for `update_all` / `delete_all`, which normally bypass callbacks.
- 🔗 **`has_and_belongs_to_many`** — join-table writes are tracked through SQL notifications.
- 🛡️ **Sensitive-data filtering** — recursive `[FILTERED]` redaction with global and per-model attribute lists.
- 🔌 **Pluggable providers & hooks** — decide how to resolve the actor and where events are delivered.
- 🪶 **Fail-safe** — auditing never breaks the underlying request or operation.

## 📦 Installation

Add it to your `Gemfile`:

```ruby
gem "provenance"
```

Then install:

```bash
bundle install
```

## 🚀 Quick start

### 1. Configure the initializer

```ruby
# config/initializers/provenance.rb
require "provenance"

Provenance.configure do |config|
  config.source_name = "myapp_#{Rails.env}"
  config.sensitive_attributes = %w[password password_confirmation token secret_key api_key]

  # Auditing is disabled in the test environment by default. Override if needed:
  # config.enabled = true
end

# How to resolve the actor and request metadata (each receives the controller):
Provenance.setup_username_provider(->(controller) { controller.current_user&.email })
Provenance.setup_roles_provider(->(controller) { controller.current_user&.roles || [] })
Provenance.setup_remote_ip_provider(->(controller) { controller.request.remote_ip })
Provenance.setup_origin_ip_provider(->(controller) { ENV["SERVER_IP"] || "127.0.0.1" })
Provenance.setup_session_id_provider(->(controller) { controller.request.headers["Authorization"]&.split(" ")&.last })

# Where audit events go (you can register more than one hook):
Provenance.config.add_audit_hook do |audit_data|
  Rails.logger.info("AUDIT: #{audit_data.to_json}")
end
```

### 2. Mix the concerns in

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  include Provenance::Auditable       # records changes per request
  include Provenance::ErrorReporting  # adds audit_error(error, status)
end
```

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  include Provenance::Trackable
end
```

That's it. Every write that happens inside a request now produces an audit event.

## 🧭 How it works

```
Request ─▶ Auditable (around_action)
              │  opens a Journal for this request
              ▼
        Trackable callbacks  ──▶  Journal  ◀──  BulkOperations / HABTM SQL
        (create/update/destroy)   (grouped by transaction)
              │
              ▼
        all transactions committed?
              │ yes                       │ rollback
              ▼                           ▼
        audit hooks receive          changes discarded
        one assembled event
```

The `Journal` lives in fiber-local storage for the duration of the request, so concurrent requests
never see each other's changes.

## 💥 Error logging

Call `audit_error` from your rescue handlers to record failures:

```ruby
def render_errors(errors, status: :unprocessable_entity)
  audit_error(errors, status)
  render json: { errors: Array(errors) }, status: status
end

rescue_from ActiveRecord::RecordNotFound do
  audit_error("Not found", :not_found)
  head :not_found
end
```

Symbolic statuses (`:not_found`, `:unauthorized`, `:forbidden`, `:unprocessable_entity`, `:conflict`)
are mapped to their numeric codes automatically; anything else defaults to `500`.

## 🛡️ Sensitive data filtering

Filtered values are replaced with `[FILTERED]` — in model attributes, request params, and nested
hashes/arrays alike.

```ruby
# Global (applies everywhere)
Provenance.configure do |config|
  config.sensitive_attributes = %w[password token api_key]
end

# Per-model (takes priority over the global list)
class Payment < ApplicationRecord
  sensitive_attributes :card_number, :cvv, :token
end
```

```ruby
# in                                  # out
{ user: {                            { user: {
    email: "user@example.com",           email: "user@example.com",
    password: "secret",                  password: "[FILTERED]",
    profile: { api_key: "abc123" }       profile: { api_key: "[FILTERED]" }
} }                                  } }
```

## 🗂️ Bulk operations

`update_all` and `delete_all` skip ActiveRecord callbacks, so they are tracked separately and must be
enabled explicitly:

```ruby
Provenance.configure do |config|
  config.track_bulk_operations = true   # default: false
  config.bulk_operations_max_ids = 1000 # cap ids per record; over the cap sets truncated: true
end
```

The affected ids are collected with a `pluck` **before** the statement runs, so factor in one extra
query on large result sets. Operations outside an HTTP request (migrations, rake tasks, background
jobs) are not tracked. A bulk change looks like:

```ruby
{
  model: "Comment",
  model_ids: ["101", "102"],
  action: "bulk_update",      # or "bulk_delete"
  count: 2,
  changes: { status: "deleted", deleted_at: "2026-06-05T12:00:00Z" }
}
```

## 🔗 has_and_belongs_to_many

Join-table inserts and deletes never trigger model callbacks, so Provenance observes them through
`sql.active_record` notifications and folds them into the owner's change as an `*_ids` update. No extra
setup is required beyond including `Provenance::Trackable` in the participating models.

> **Note:** the SQL reconstruction for HABTM is tuned for PostgreSQL bind placeholders (`$1`, `$2`).
> Insert tracking is portable; delete tracking depends on that placeholder style.

## ⚙️ Fine-tuning

### Skip auditing per action

```ruby
class UsersController < ApplicationController
  skip_audit_logging :index, :show       # no event at all
  skip_model_change_tracking :index      # event, but without model diffs
end
```

### Custom event types

```ruby
class SessionsController < ApplicationController
  custom_audit_event_type :create, "user_login"
  custom_audit_event_type :destroy, "user_logout"
end
```

### Automatic event-type generation

When you don't override it, Provenance derives the event type from the controller and action:

| Action            | Event type                | Example (`UsersController`)        |
| ----------------- | ------------------------- | ---------------------------------- |
| `index`           | `read_{controller}`       | `read_users`                       |
| `show`            | `show_{singular}`         | `show_user`                        |
| `create`          | `create_{controller}`     | `create_users`                     |
| `update`          | `update_{singular}`       | `update_user`                      |
| `destroy`         | `destroy_{singular}`      | `destroy_user`                     |
| _custom action_   | `{action}_{controller}`   | `archive_users`                    |

Namespaced controllers are flattened with `_`, e.g. `Admin::UsersController#index` → `read_admin_users`.

### Delivery hooks

```ruby
Provenance.config.add_audit_hook { |event| ExternalAuditService.deliver(event) }
Provenance.config.add_audit_hook { |event| Rails.logger.info("AUDIT: #{event.to_json}") }
Provenance.config.clear_audit_hooks  # remove all hooks
```

## 🔧 Configuration reference

| Option                      | Default              | Description                                              |
| --------------------------- | -------------------- | ------------------------------------------------------- |
| `source_name`               | `"app_#{Rails.env}"` | Identifies the emitting application in every event.     |
| `sensitive_attributes`      | `[]`                 | Global attribute names to redact.                       |
| `enabled`                   | `!Rails.env.test?`   | Master switch for the whole pipeline.                   |
| `track_bulk_operations`     | `false`              | Track `update_all` / `delete_all`.                      |
| `bulk_operations_max_ids`   | `1000`               | Max ids recorded per bulk change.                       |
| `audit_hooks`               | `[]`                 | Delivery callbacks (use `add_audit_hook`).              |

Providers: `username`, `roles`, `remote_ip`, `origin_ip`, `session_id` — each set via
`Provenance.setup_<name>_provider(callable)`.

## 📐 Event structure

**Successful request**

```json
{
  "timestamp": "2026-06-05T12:00:00.000Z",
  "event_type": "create_users",
  "status": 201,
  "message": {
    "count": 1,
    "changes": [
      {
        "model": "User",
        "model_id": 123,
        "action": "create",
        "changes": { "attributes": { "email": "user@example.com", "name": "John Doe" } },
        "timestamp": "2026-06-05T12:00:00.000Z"
      }
    ],
    "params": { "user": { "email": "user@example.com" } }
  },
  "username": "admin@example.com",
  "remote_ip": "203.0.113.1",
  "origin_ip": "192.168.1.100",
  "session_id": "token123",
  "roles": ["admin"],
  "request_id": "req-123",
  "source": "myapp_production"
}
```

**Failed request** (via `audit_error`)

```json
{
  "timestamp": "2026-06-05T12:00:00.000Z",
  "event_type": "create_users",
  "status": "422",
  "message": {
    "error_type": "ActiveRecord::RecordInvalid",
    "error_message": "Validation failed: Email has already been taken",
    "params": { "user": { "email": "invalid" } }
  },
  "username": "admin@example.com",
  "source": "myapp_production"
}
```

## 🧪 Development

```bash
bundle install
bundle exec rspec     # run the test suite
bundle exec rubocop   # lint
```

## 🤝 Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

Released under the [MIT License](LICENSE).
