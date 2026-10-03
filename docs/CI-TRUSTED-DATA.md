# Trusted data validation: stage one of #249

`scripts/check-trusted-data.py` is an interface for a future trusted-base CI
lane. It does **not** enable that lane in this PR. CI still runs candidate
provisioning, validators and runtime tests from its ordinary checkout; the new
test only exercises the interface using independent temporary Git repositories.
The first-party/fork split and required `trusted check` name are unchanged.

After this helper lands on main, a separate CI change can invoke it as:

```sh
python3 -I -S trusted/scripts/check-trusted-data.py \
  --candidate-root candidate \
  --trusted-sha "$EVENT_BASE_SHA" \
  --candidate-sha "$EVENT_MERGE_SHA"
```

Both roots must be clean Git checkout top levels, distinct and non-nested.
The trusted root is derived from the executed helper, never a candidate argument.
Full lowercase SHA-1 identities must match both HEADs. Untracked and ignored files
are rejected too. Candidate symlinks and special files are rejected before parsers
read them. This intentionally requires ordinary source files for this static lane.

The helper runs trusted source and release-note validators, with shellcheck rc
loading disabled and Python isolated from repository imports. It always validates
the candidate VERSION's release notes, without a tag-based skip. The v1 contract,
corpus and plugin identity must equal trusted-base bytes: changing expectations
alongside an implementation cannot redefine success. Intentional changes to this
frozen metadata will need a separately reviewed migration; there is no bypass flag.
Candidate shell scripts, libraries, resolvers and tests are treated only as data.
This does not prove runtime conformance or replace the existing adapter suite.

## Follow-up after bootstrap

1. Obtain the exact PR event base SHA and the exact synthetic merge SHA; check them
   out in separate directories with credentials not persisted. Do not substitute
   a moving main tip or the PR head for the event identities. Define the push path
   explicitly and preserve the public fork job's data-only behavior.
2. Verify checkout identities, provision pinned tools using trusted-base code, then
   run this helper **before any candidate execution**. Use no candidate local
   actions, config, provisioning or fallback helper. A base lacking this interface
   must fail explicitly; stage one is what makes the next PR's base usable.
3. Keep first-party runtime tests as a separate, intentional candidate-execution
   phase. The existing ci-assurance and adapter suites locate their own fixtures,
   source the library, and execute the resolver; invoking them from base neither
   validates all candidate behavior nor establishes a data-only boundary.
4. Test the event wiring, wrong event identities, missing trusted helper, tampered
   candidate validators and changed expectations on the final CI integration.

This interface assumes the caller, interpreter, PATH, Git metadata and provisioned
tools are trusted, and that no concurrent process mutates checkouts during checks.
It checks supplied identity, not authority or GitHub event provenance. A PR can
still edit its `pull_request` workflow. Tamper-resistant enforcement requires a
separately controlled required gate and an explicit future security-policy decision;
this work makes no ruleset changes and does not migrate to `pull_request_target`.
