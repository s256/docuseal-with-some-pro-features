# Upstream Sync Process

Repeatable process for incorporating new upstream DocuSeal releases into this fork.

## Overview

| Property | Value |
|---|---|
| Upstream | `https://github.com/docusealco/docuseal.git` (remote: `upstream`) |
| Fork | `git@github.com:s256/docuseal-with-some-pro-features.git` (remote: `origin`) |
| Strategy | **Merge** upstream tags into fork master (preserves history, no force-push). The sync PR must be merged with **"Create a merge commit"**, never squash/rebase |
| Cadence | Upstream releases weekly (Saturdays). Sync as needed. |
| Tag format | Upstream: `X.Y.Z` (no `v` prefix). Fork releases: `X.Y.Z-fork.N` (triggers `docker-publish.yml`) |
| Last synced | `3.3.3` (merge commit `9c089fd8`, PR #18, fork release `3.3.3-fork.1`, 2026-10-21) |

## Fork-Specific Features (Must Survive Every Sync)

These are non-negotiable. If upstream touches the same area, verify they still work:

1. **Teams & Editor Role** — `Team` model, `team_id` on resources, `lib/ability.rb` authorization, team CRUD UI
2. **Automated Email Reminders** — `ProcessSubmitterRemindersJob`, `SendSubmitterReminderEmailJob`, reminder settings UI
3. **Company Logo / White-Label** — `AccountLogoController`, logo upload, display in forms/emails
4. **Professional Email Templates** — Redesigned mailer layouts in `app/views/submitter_mailer/`
5. **Template Creation API** — `Api::TemplatesPdfController`, `Api::TemplatesDocumentsController`
6. **Navigation Customization** — Removed Discord, upstream branding, GitHub references (commit `f70c6eba`)
7. **Translation Keys** — Additional i18n keys for fork features
8. **Paperless-ngx / Twenty CRM** — upload jobs enqueued from `ProcessSubmitterCompletionJob#enqueue_integration_uploads`

### Known sync hot spots (from 3.3.3)

- **Viewer parties** (`Submitter#viewer?`, `template_submitters[].is_viewer`): any fork code that targets "pending signers" (reminders, reminder queue, next-reminder indicator) must skip viewers. Viewer status lives in JSON, so filter in Ruby, not SQL.
- **Team scoping of new creation paths**: every new place upstream builds a `Submission`, `Submitter` or `Template` needs `team_id` (template's team, or `current_user.team_id`), or editors will not see the record.
- **`_settings_nav.html.erb`**: take upstream wholesale, then re-apply the fork edits (Account/Users/Teams guards, no Plans/Console/Discord/ChatGPT/support mail, disabled SSO, fork release badge).
- **Rubocop metrics**: fork additions inside upstream methods can push them over `Metrics/*` limits after a merge; extract the fork lines into a private helper instead of disabling cops. Run rubocop with `DATABASE_URL` unset, otherwise `Rails/BulkChangeTable` flags old migrations.

## Decision Framework: When to Ask the User

### Auto-resolve (NO user input needed)

- Upstream adds new files (controllers, models, migrations, views) → **accept all**
- Upstream changes files the fork hasn't touched → **accept all**
- Upstream changes files the fork also changed, but git auto-merges cleanly → **accept merge**
- Upstream updates `README.md` → **keep fork's README, discard upstream changes**
- Upstream updates `_github.html.erb` (star counter) → **keep fork version**
- Upstream bumps gem versions in `Gemfile`/`Gemfile.lock` → **regenerate via `bundle install`**
- Upstream adds new migrations → **accept as-is** (verify timestamp ordering)

### Ask the user (HARD contradictions only)

- Upstream **removes** a file/method/feature that the fork extends or depends on
- Upstream **modifies the same lines** of code that fork's features rely on (semantic conflict)
- Upstream introduces **telemetry, paywalls, or feature gating** (enshittification)
- Upstream **renames/restructures** a module that fork's code imports or calls
- Upstream adds a **new model** that should be team-scoped but isn't (fork pattern: most resources get `team_id`)
- Upstream changes **authorization logic** in a way that conflicts with fork's `lib/ability.rb`

### Guiding principle: **Always add, never subtract**

When in doubt, combine both. Fork features stay. Upstream features get added. Only escalate genuine incompatibilities.

## Step-by-Step Process

### Phase 0: Preparation

```bash
# 1. Ensure clean working tree
git status  # must be clean

# 2. Fetch upstream tags
git fetch upstream --tags

# 3. Verify the target tag exists
git tag -l "X.Y.Z"  # replace with target version

# 4. Verify current sync point
git merge-base --is-ancestor <LAST_SYNCED_TAG> master
# Must output nothing (exit 0) — confirms lineage is intact
```

### Phase 1: Pre-Merge Analysis

Before touching any code, analyze what's coming:

```bash
# 1. List all changed files in upstream release
git diff --stat <LAST_SYNCED_TAG>..<TARGET_TAG>

# 2. Find files modified by BOTH fork and upstream (conflict candidates)
git diff --name-only <LAST_SYNCED_TAG>..<TARGET_TAG> | sort > /tmp/upstream_changes.txt
git diff --name-only <LAST_SYNCED_TAG>..master | sort > /tmp/fork_changes.txt
comm -12 /tmp/upstream_changes.txt /tmp/fork_changes.txt

# 3. Dry-run merge to identify conflicts
git merge-tree --write-tree master <TARGET_TAG>
# Lines with "CONFLICT" = manual resolution needed

# 4. Check for removed files (enshittification detector)
git diff --diff-filter=D --name-only <LAST_SYNCED_TAG>..<TARGET_TAG>
# If any files are listed, check if fork depends on them

# 5. List new migrations
git diff --name-only <LAST_SYNCED_TAG>..<TARGET_TAG> -- db/migrate/
# Order relative to fork migrations does not matter: Rails runs every pending
# migration. Only an identical timestamp is a problem (see Troubleshooting).
# Check data migrations / backfills (boot time on large DBs) and whether they
# touch tables the fork altered (team_id columns and indexes).

# 6. Review upstream release notes
# Visit https://github.com/docusealco/docuseal/releases/tag/<TARGET_TAG>
```

**Classification output**: After analysis, classify each conflict/overlap as:
- ✅ **AUTO** — git auto-merge handles it, or fork version wins (README, branding files)
- ⚠️ **REVIEW** — semantically overlapping changes, needs manual three-way merge
- 🛑 **ASK** — hard contradiction, requires user decision

### Phase 2: Merge

```bash
# 1. Create a sync branch (safety net)
git checkout -b sync/upstream-<TARGET_TAG>

# 2. Merge the upstream tag
git merge <TARGET_TAG> --no-commit --no-ff

# 3. Handle conflicts based on Phase 1 classification:

# For README.md (always keep fork version):
git checkout --ours README.md
git add README.md

# For _github.html.erb (always keep fork version):
git checkout --ours app/views/shared/_github.html.erb
git add app/views/shared/_github.html.erb

# For other conflicts: resolve manually based on "always add" principle

# 4. Verify no merge artifacts remain
git grep -E "<<<<<<|>>>>>>|======" app/ lib/ config/ db/
# Must return zero results

# 5. Commit the merge
git commit -m "Merge upstream release <TARGET_TAG>

Upstream changes:
- [list key features/fixes from release notes]

Fork features preserved:
- Teams & Editor Role
- Email reminders
- Company logo / white-label
- Custom email templates
- Template creation API
- Navigation customization"
```

### Phase 3: Post-Merge Fixup

```bash
# 1. Regenerate Gemfile.lock
bundle install

# 2. Check for migration timestamp collisions (identical versions only)
ls db/migrate/ | cut -d_ -f1 | sort | uniq -d   # must be empty

# 3. Never renumber a migration that has shipped in a fork release: production
# databases already recorded its version and would run it again.

# 4. Regenerate schema
# (Only needed if migrations from upstream need to run)
# In development: bin/rails db:migrate
# Or with Docker: docker compose exec web bin/rails db:migrate

# 5. Check for new upstream models that need team-scoping
git diff --name-only <LAST_SYNCED_TAG>..<TARGET_TAG> -- app/models/
# For each new model, decide if it needs team_id (ask user if unclear)

# 6. Verify autoloading
# bin/rails zeitwerk:check (or via Docker)
```

### Phase 4: Verification

All of these must pass before the sync is considered complete:

| Check | Command | Expected |
|---|---|---|
| No merge artifacts | `git grep -E "<<<<<<\|>>>>>>\|======" app/ lib/ config/ db/` | Zero results |
| Bundle valid | `bundle check` | Exit 0 |
| No migration collisions | `ls db/migrate/ \| cut -d_ -f1 \| sort \| uniq -d` | Zero results |
| Upgrade path | Boot the previous fork release image on a fresh DB, then the new image on the same DB | Migrations apply, `/up` 200 |
| Tests pass | `bundle exec rspec` (or `docker compose exec web bundle exec rspec`) | Exit 0, no failures |
| Build works | `docker compose build` (if using Docker) | Exit 0 |
| App boots | `docker compose up -d && curl -s http://localhost:3000/up` | 200 OK |
| Fork features intact | See Fork Feature Smoke Tests below | All pass |
| Integrations (live) | `docker compose -f docker-compose.e2e.yml run --rm rspec` (latest Paperless-ngx + Twenty; pin with `TWENTY_VERSION`/`PAPERLESS_VERSION`) | 0 failures, 0 pending |

### Fork Feature Smoke Tests

After every sync, verify these features haven't regressed:

```bash
# Teams
grep -r "class Team" app/models/  # Model exists
grep -r "team_id" db/schema.rb    # Column exists
grep -r "TeamController\|teams_controller" app/controllers/  # Controller exists

# Reminders
grep -r "ProcessSubmitterRemindersJob" app/jobs/  # Job exists
grep -r "reminder" config/routes.rb               # Routes exist

# Logo
grep -r "AccountLogoController\|account_logo" app/controllers/  # Controller exists
grep -r "logo" app/models/account.rb                            # Association exists

# Email templates (custom layout)
grep -r "email_button\|mailer_attribution" app/views/shared/   # Partials exist

# Template API
grep -r "TemplatesPdf\|TemplatesDocuments" app/controllers/api/ # Controllers exist

# Navigation (upstream refs removed)
! grep -r "discord\|docuseal.com/console\|docuseal.com/plans" app/views/shared/_navbar.html.erb
# Must return exit 1 (not found = good)
```

### Phase 5: Finalize

Update this document **on the sync branch, before merging**: "Last synced" in the
Overview table (with the merge commit hash) and a History row.

```bash
# 1. Push the sync branch and open a PR to master
#    (the pre-push hook runs the full CI suite in Docker; it takes several minutes)
git push -u origin sync/upstream-<TARGET_TAG>
gh pr create --base master --head sync/upstream-<TARGET_TAG>

# 2. Merge the PR with "Create a merge commit" -- NOT squash or rebase.
#    Squashing drops the upstream parent, so <TARGET_TAG> stops being an
#    ancestor of master and the next sync re-merges everything since the
#    previous sync point.
gh pr merge <PR> --merge

# 3. Verify lineage, then tag the fork release (the upstream tag name is taken)
git checkout master && git pull
git merge-base --is-ancestor <TARGET_TAG> master && echo ok
git tag <TARGET_TAG>-fork.1
git push origin <TARGET_TAG>-fork.1   # triggers docker-publish.yml

# 4. Clean up
git branch -d sync/upstream-<TARGET_TAG>
```

## Troubleshooting

### Migration timestamp collision

Only relevant if upstream adds a migration with exactly the same version as a fork
migration. Newer upstream timestamps sorting after fork migrations are fine (since
3.3.3, upstream `202606*`+ sort after fork `20260508*`). If a collision happens and
the fork migration has **not** shipped in a release yet:

```bash
# Renumber the unreleased fork migration
# Example: 20260508100000_create_teams.rb → 20260510100000_create_teams.rb
git mv db/migrate/OLD_NAME.rb db/migrate/NEW_NAME.rb

# Update the class name inside if it includes a timestamp
# Update any spec files that reference the migration filename
# Regenerate schema: bin/rails db:migrate
```

### Upstream removes a file the fork uses

1. Check if the functionality moved elsewhere (grep for the class/method name in the new upstream code)
2. If moved: update fork's imports/requires to point to new location
3. If deleted entirely: keep the file in the fork, document the divergence here

### Semantic conflict in shared file

When both fork and upstream changed the same method differently:

1. Read the upstream change intent (from commit message / release notes)
2. Read the fork change intent (from PR description)
3. Combine both: the goal is for both behaviors to coexist
4. If they can't coexist → ASK the user

### New upstream model needs team-scoping

After sync, if upstream added a new model (e.g., `TemplateVersion`):

1. Check if it's accessed through an account-scoped parent (e.g., `template.versions`) → likely fine
2. Check if it has direct access without scoping → may need `team_id` column
3. If unclear → ASK the user

## History

| Date | Release | Conflicts | Notes |
|---|---|---|---|
| 2026-05-04 | 2.5.2 | — | Initial fork sync point |
| 2026-05-11 | 2.5.3 | README.md only | Template revisions, HMAC webhooks, pdfium rotation |
| 2026-05-20 | 3.0.0 | None | Complete button, percent format, validation messages, PDF image optimization |
| 2026-10-21 | 3.3.3 | 20 (README, CI, Gemfile.lock, i18n, mailer, nav/settings views, submissions/show, schema) | Direct jump from 3.0.0 (508 commits). Viewer parties, OTP challenges, document editor, DOCX upload, Turbo 8 (`turbo_prefetch`), Ruby 4.0.5. Fork patches: viewers skipped by reminders, start-form/MCP submissions & templates get `team_id`, viewer email uses `shared/email_button`. Upstream migrations (`202606*`+) now sort after fork migrations (`20260508*`) — left as-is, never renumber. Twenty upload switched to direct upload (Twenty v2.39 removed `uploadFilesFieldFile`). Verified: rspec 321/0, e2e 6/6 on Twenty v2.50/v2.38/v2.17 × paperless-ngx 3.3.3/3.0/2.20, upgrade from `3.0.0-fork.4` DB. Merge commit `9c089fd8`, PR #18. |
