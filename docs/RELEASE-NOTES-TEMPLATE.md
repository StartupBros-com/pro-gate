# Release notes: how to write them

Every pro-gate release is announced to House of Vibe customers. The release train POSTs to
the members site (`/api/internal/ops/tool-releases`), which renders the branded tool-drop
card and posts it to the Discord tool-drops channel — **pro-gate itself sends no Discord
message; do not add one.** The card's "What's new" section is the `notesSummary` field,
which is derived from a `## Highlights` section in the GitHub release body.

**If you don't write one, customers get GitHub's auto-generated PR titles.** That is how
v0.31.0 and v0.31.1 shipped cards whose What's New read `governor-rounds` and
`memo-crossbind`. CI now blocks that.

**Get it right at publish time.** `scripts/publish-runtime-release.sh` uses
`docs/release-notes/v<version>.md` as the release body when that file exists and passes the
check, falling back to GitHub auto-notes (branch names) otherwise. So the reliable workflow
is: write the notes file in the version-bump PR, and the published release carries real copy
from the start.

Editing a body afterwards is only a partial fix. The release train re-runs on `edited` and
the members-site handler updates the existing Discord card in place (no double-post) — **but
only for the LATEST stable release**. `release-train.sh` no-ops when the edited release is
not the latest, so once a newer version ships, an older release's card can no longer be
corrected through this path.

## The rule

Write for a customer who uses pro-gate and has never read our code. They want to know:
**what changed for me, and do I need to do anything?**

Not: which function changed, which internal issue it closed, or what the race condition was.

## Template

```markdown
## Highlights

- <What a user can now do, or what stopped going wrong — one sentence, plain language>
- <Second one, if there is one>
- <Third at most. Three bullets is the cap the announcement feed shows.>

## Upgrade

<"Nothing to do — the next review picks it up automatically." Or the exact command.>

## Details

<Optional. Anything technical goes HERE, below the fold, not in Highlights.>
```

## Voice

Each bullet is one sentence, under ~180 characters, and leads with the user-visible effect.

| Instead of | Write |
|---|---|
| "Trajectory-aware round governor with churn brake" | "Reviews that are making progress now get extra rounds automatically, and ones going in circles stop early instead of burning your quota." |
| "Cross-bound conversation memo eviction" | "Fixed a rare case where a stuck review could block a pull request from being reviewed again." |
| "pg_reservation_note_miss now rewrites all 7 fields" | *(omit — internal, no user-visible effect)* |
| "Fixes #67" | *(omit — link it in Details if useful)* |

Rules of thumb:

- **No internal identifiers in Highlights.** No function names, env vars, file paths, issue
  numbers, or branch names. If a bullet only makes sense to someone with the repo open, it
  belongs in Details.
- **Name the symptom, not the mechanism.** Users recognize "reviews sometimes got stuck and
  wouldn't restart"; they do not recognize "the URL memo was cross-bound".
- **Say when nothing is required.** Most releases need no action, and saying so plainly is
  more valuable than a changelog.
- **Skip pure-internal releases.** If a release genuinely has no user-visible change, say
  that in one bullet ("Internal reliability work; no change to how reviews run.") rather
  than inventing detail.

## Checks

`scripts/check-release-notes.sh` flags a body with no `## Highlights` section, an empty one,
or bullets that look like un-edited PR titles (a conventional-commit prefix, a bare branch
name, a `#123` reference, or a `by @user in <url>` tail).

It runs in two places, deliberately with different severity:

- **On the release train: warn only.** The same job promotes the runtime to
  `hov-marketplace`, so a hard failure over prose would leave a tagged release customers
  cannot install. Bad copy degrades the announcement, never shipping. The warning appears as
  a job annotation, and editing the release body re-runs the train and updates the existing
  Discord card in place.
- **On the PR / locally: fail.** That is where a human can still fix it cheaply.

Run it on a draft before publishing:

```bash
scripts/check-release-notes.sh path/to/notes.md
```
