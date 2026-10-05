# Contributing

Thanks for helping with Provenance.

## Setup

```sh
bundle install
bundle exec rspec          # SQLite in-memory dummy app
bundle exec rubocop        # Standard style
bundle exec rake yard:coverage
```

Run against a specific Rails version with `RAILS_VERSION=7.2 bundle update && bundle exec rspec`.

PostgreSQL-only specs (outbox locking and sequence allocation) run when
`DATABASE_URL` points at PostgreSQL:

```sh
docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=provenance_test postgres:16
DATABASE_URL=postgres://postgres:postgres@localhost:5432/provenance_test bundle exec rspec
```

## Guidelines

- `docs/SPEC.md` is the functional specification; behaviour changes start there.
- Every public method needs YARD documentation; CI fails below 100% coverage.
- Add specs for every change; the dummy app lives in `spec/dummy`.
- Keep commits focused and messages in plain English.
- Releases are published by the tag-triggered GitHub workflow using RubyGems
  trusted publishing.
