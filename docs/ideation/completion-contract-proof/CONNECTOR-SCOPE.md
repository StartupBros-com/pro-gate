# @GitHub connector — real grant scope (read-only audit, 2026-08-12)

No authorization was changed, revoked, or re-created. All findings are from `gh api` reads
against the operator's existing token.

## 1. App type: GitHub App (org-installed), not a per-repo OAuth grant

`gh api /apps/chatgpt-codex-connector` (public, unauthenticated-safe endpoint):

```
id: 1144995
slug: chatgpt-codex-connector
name: "ChatGPT Codex Connector"
owner: openai (org, id 14957082)
description: "Bring ChatGPT and Codex to your GitHub repositories."
html_url: https://github.com/apps/chatgpt-codex-connector
declared permissions: actions:write, checks:read, contents:write, emails:read,
                       issues:write, metadata:read, pull_requests:write,
                       statuses:read, workflows:write
```

The app's own description explicitly states it serves **both** ChatGPT (the connector pro-gate's
prompt invokes via `@GitHub`) and Codex — this is one unified GitHub App, not two separate
integrations with independently scoped grants.

`gh api /user/installations` (would list installations on the operator's *personal* account,
login `StartupBros`) returned 403: `"You must authenticate with an access token authorized to a
GitHub App in order to list installations."` This is a structural gh-CLI limitation, not a finding
about the connector — gh's OAuth token cannot enumerate personal-account app installations via
this endpoint regardless of what's installed. **The operator would need to check
`https://github.com/settings/installations` in a browser to see personal-account installations.**
Not checked here.

## 2. Installation found: org-wide, all 65 repos — this is the answer

`gh api /orgs/StartupBros-com/installations` (works: token has `admin:org` scope and the operator
is an org owner there) returned 6 app installations, including:

```json
{
  "id": 142432522,
  "app_id": 1144995,
  "app_slug": "chatgpt-codex-connector",
  "target_type": "Organization",
  "repository_selection": "all",
  "created_at": "2026-06-24T18:48:40-04:00",
  "updated_at": "2026-08-12T01:03:38-04:00",
  "permissions": {
    "actions": "write",
    "checks": "read",
    "contents": "write",
    "issues": "write",
    "metadata": "read",
    "pull_requests": "write",
    "statuses": "read",
    "workflows": "write"
  },
  "html_url": "https://github.com/organizations/StartupBros-com/settings/installations/142432522"
}
```

**`repository_selection: "all"` — org-wide, not scoped to `pro-gate` or any single repo.**
`StartupBros-com` (where `pro-gate` itself lives — confirmed via `gh repo view`:
`nameWithOwner: StartupBros-com/pro-gate`) currently has **65 repositories, 31 of them private**
(`gh repo list StartupBros-com --json isPrivate`). The `contents` permission is granted at
`write`, which in GitHub's App permission model implies full read of repository contents (code,
commits, branches, tags, releases) — read is a strict subset of write, there is no read-only
tier below it being used here.

`updated_at` matches the moment this audit ran (`2026-08-12T01:03:38`), which is just the API
serializing current-second install state on read, not evidence of a change — no write call was
made against this endpoint.

## 3. Org check for `makerkit` (the operator's other org)

`gh api /orgs/makerkit/installations` returned `404 Not Found`. The operator's role there is
`member` (`gh api /user/memberships/orgs/makerkit --jq .role`), not owner — this endpoint requires
org-owner-level access, so a 404 here is consistent with insufficient privilege rather than
"nothing installed." **Not resolved either way; pro-gate does not operate in that org so it is
out of scope for the practical-implication question, but flagging the gap.**

## 4. What the repo's own docs say

`docs/SETUP-NOTES.md:28-30` (pro-gate worktree):

> **Engine** `~/.pro-review-daemon/oracle-review.sh` — assembles `gh pr diff` + `--file` + the PR
> URL, prompt **leads with `@GitHub` to bind the connector** (Will confirmed pasting `@GitHub`
> tags it; oracle's CDP insertText carries it — connector fetches correctly, verified twice).
> ...
> **GitHub connector CONFIRMED** working in the automated session (fetched private
> StartupBros-com PR data exactly).

This documents that the connector was proven to work and specifically that it reached *private*
StartupBros-com data — consistent with (but not, on its own, proof of) org-wide scope. It does
not state or discuss `repository_selection` anywhere; that scope fact is undocumented in the repo
prior to this audit, exactly as the operator suspected. No other doc in `docs/`, `bin/`, `skills/`,
or `agents/` mentions installation scope, repository_selection, or the GitHub App by name.

## 5. Practical implication for pro-gate reviews

When pro-gate reviews a PR in `StartupBros-com/pro-gate` (or any other `StartupBros-com` repo),
the Pro model's `@GitHub` connector is authorized, at the GitHub-permission layer, to read **any
of the other 64 repos in the org, including the 31 private ones** — not just the repo under
review. Nothing in the connector grant itself confines a request to "the repo named in this
prompt." Whatever containment exists is prompt-level only (pro-gate's prompt names one specific
PR/repo and asks the model to fetch that), not an OAuth/App-permission boundary. A prompt
injection reachable through PR content (title, description, a file the model reads) that induces
the model to also fetch data from a different `StartupBros-com` repo is not blocked by anything
found in this audit — the App installation would permit that read.

Write permissions (`contents:write`, `pull_requests:write`, `issues:write`, `actions:write`,
`workflows:write`) are also granted at the *installation* level org-wide, though pro-gate's own
prompt only asks the model to review and does not exercise write actions, and pro-gate's local
engine (not the model) is what applies any resulting changes. This audit did not check whether
Codex (the separate OpenAI product sharing this same App) has independently exercised write scope
against any `StartupBros-com` repo — out of scope for this task, flagging as a related surface
worth a separate look given the shared App.

## Answer to the operator's core question

**Org-wide, not single-repo.** The `chatgpt-codex-connector` GitHub App is installed on
`StartupBros-com` with `repository_selection: "all"`, covering all 65 repos (31 private) in the
org that hosts `pro-gate` itself, with `contents:write` (implies full read) plus write on
issues/PRs/actions/workflows. Personal-account (`StartupBros` login) installations could not be
enumerated with the available `gh` token (403 — wrong token type for `/user/installations`); if
the operator also connected GitHub from their personal account rather than only the org, that
grant is unaudited and would need a browser check at `github.com/settings/installations`.
