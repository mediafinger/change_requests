# Agent Guidelines for ChangeRequests

Read the whole file and follow it's instructions.

## Ruby Environment & Execution Helpers

This installation manages Ruby versions via `chruby` and `.ruby-version`. To run Rake, RSpec, Rubocop, bundle or bin/ commands, you might have to prefix them with:

```bash
#!/usr/bin/env bash
source /opt/homebrew/share/chruby/chruby.sh
chruby $(cat .ruby-version 2>/dev/null)
```

every time. In any case: `bundle exec rake ci` will run the linter and the test suite.

---

## Code Quality & Verification Rules

1. The maximum permitted line-length is 125 chars. Only break lines when they're longer, don't shorten them prematurely.

2. **Regression tests are mandatory for every bug — no exceptions**:
   - Whenever a bug is reported to you, OR you discover one yourself while working,
     you MUST add a regression test that fails before your fix and passes after it.
   - Never fix a bug with only a code change. The test comes with the fix, in the
     same change set.
   - Write the failing test first, watch it fail for the right reason, then fix.
   - The regression test must target the specific broken behaviour (the exact
     nav entry, the exact route, the exact rendered element, …), so a future
     change that reintroduces the bug is caught.
   - This applies to bugs of any size, including "one-line" fixes and config /
     routing / view / JS-wiring bugs.

3. **RuboCop Auto-correction**:
   - After modifying any Ruby file and before running tests or CI, run safe auto-correct:
     ```bash
     `bundle exec rubocop -A <modified_files>
     ```

4. **Ruby Change Validation**:
   - Always run `bundle exec rake ci` to confirm all changes pass before concluding a task.
   - Follow strict TDD: plan first, write failing specs first, then implement changes.

5. **Gem Architecture**:
   `lib/change_requests/` contains the business logic that can run headless. No code in there, should access any code under `app/` (but code under `app/` is allowed to acce `lib/change_requests/**`).
