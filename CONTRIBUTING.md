# Contributing

Thanks for taking the time to contribute to Provenance! 🎉

## Getting started

```bash
git clone https://github.com/inikalaev/provenance.git
cd provenance
bundle install
bundle exec rspec
```

## Development workflow

1. Fork the repository and create a topic branch from `main`.
2. Write a failing test that captures the bug or the new behavior.
3. Make it pass with the smallest reasonable change.
4. Keep the suite green and the linter happy:
   ```bash
   bundle exec rspec
   bundle exec rubocop
   ```
5. Update `CHANGELOG.md` under the `Unreleased` section.
6. Open a pull request describing the change and the motivation.

## Guidelines

- Match the existing code style; `rubocop` is the source of truth.
- Auditing must never break the host application — anything that can fail in a
  hook or tracker should fail safe.
- Public behavior changes need test coverage and a changelog entry.

## Reporting issues

Please include the Ruby and Rails versions, a minimal reproduction, and the
expected vs. actual behavior.
