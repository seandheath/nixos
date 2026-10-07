# Goal

Deliver the requested change with the least code a reader needs to understand it. Simple and correct beats flexible, clever, or defensive. When unsure, choose fewer lines, fewer files, fewer concepts.

## Scope

- Do what was asked. Nothing more.
- Do not add features, options, flags, config, or "improvements" that were not requested.
- Do not refactor, rename, reformat, or reorganize code outside the task.
- Every changed line must trace to the request. Revert lines that don't.
- Edit existing files. Create a file only when the change cannot live in an existing one.
- No backward-compatibility shims, wrappers, aliases, or re-exports unless asked. Update the callers.
- If the request is ambiguous or looks wrong, ask before coding. If running unattended, proceed and state the assumption.
- Report unrelated problems you notice. Do not fix them.

## Simplicity

- Write the direct solution. Add structure only when this task needs it.
- No abstraction for a single use: no one-implementation interface, no one-type factory, no helper called once, no wrapper that only forwards.
- Do not design for hypothetical future requirements.
- Search for an existing helper before writing one. Reuse it. Do not duplicate logic.
- Prefer the standard library and existing dependencies. Ask before adding a dependency.
- Prefer flat control flow and early returns over nesting.
- Use plain names. No clever one-liners that need a second read.
- If 200 lines could be 50, write 50.

## Errors: fail fast

A loud failure is cheaper than a hidden one. Let errors surface where they happen.

- Let errors propagate. Catch only where you can handle the error correctly.
- No try/catch-and-continue, no catch-log-ignore, no broad catches.
- No silent fallbacks, default values, or empty results that hide a failure.
- No checks for conditions that cannot happen. Trust internal code, types, and framework guarantees.
- Validate only at system boundaries (user input, external APIs, files, network). On invalid input, fail with a clear error. Do not coerce or guess.
- No retries, timeouts, or recovery paths unless asked.
- When you handle an error, add context and pass it on. Never swallow it.

## Deletion

- Removing code is a good outcome. Prefer the change with fewer lines.
- Remove code, imports, and files your change made unused.
- No commented-out code, dead branches, or TODOs for work you could finish now.
- Pre-existing dead code outside the task: report it, do not delete it.

## Comments and docs

- Code says what. Comments say why: a non-obvious constraint, workaround, or decision.
- No comments that restate code, no banner comments, no history comments ("added X", "fixed Y").
- Do not add docstrings, comments, or type annotations to code you did not change.
- Public interface docs: one or two sentences. Do not repeat what types already say.
- Do not create README, notes, summary, or plan files unless asked.
- When updating docs, keep them short and current. Delete outdated text instead of appending.
- No debug logging in final code. Log only what operators need.

## Tests and verification

- Run the project checks (below) after changing code. Fix failures you caused.
- Tests verify behavior; they do not define it. Never hard-code values or special-case test inputs to make tests pass.
- Do not weaken, skip, or delete tests to get green. If a test is wrong, say so.
- Add tests for changed behavior. Test through public interfaces. Mock only external systems.
- Do not test impossible cases.
- Fix root causes. Do not suppress errors, warnings, or lint rules.
- Keep diffs small. Split large changes into steps that each pass the checks.
- Delete temporary scripts and scratch files before finishing.

## Forgejo

- The private forge is https://git.luckyobserver.com; its API base is https://git.luckyobserver.com/api/v1.
- The API token is in `/run/secrets/remote-coding` on the host and in coding containers. Read it in shell commands for the `Authorization: token ...` header; never print it, commit it, or include it in messages.

## Report

End each task with:

- Changes: one line per file.
- Checks: commands run and results. State plainly what failed or was not run.
- Assumptions and open questions.
- Unrelated issues noticed, not fixed. No praise, no restating the request, no description of unchanged code.
