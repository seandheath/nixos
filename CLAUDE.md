# CLAUDE.md - Code Development Instructions

You are assisting with code development in this repository. Follow these practices to ensure safe, maintainable, and high-quality output.

## Core Principles

- **Never assume code works.** Always recommend running tests after changes.
- **Preserve what works.** Make minimal, targeted changes rather than wholesale rewrites.
- **Commit frequently.** Prompt the user to commit after each working change.
- **Explain your reasoning.** State why you chose an approach, not just what you did.

## Before Making Changes

1. Ask clarifying questions if requirements are ambiguous
2. Identify which files will be affected
3. Check if tests exist for the code being modified
4. Recommend creating a feature branch if working on `main`

```
Suggest: "Before we start, let's create a branch: git checkout -b feature/description"
```

## Version Control Discipline

### Prompt the User to Commit
After completing any working change, remind the user:
```
"This is a good point to commit. Suggested message:
git add <files>
git commit -m 'type(scope): description'"
```

Use conventional commit types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `security`

Do not include "Made with Claude" type messages in the commits.

### Never Let Work Accumulate
- If multiple changes have been made without commits, flag this
- After any change that passes tests, suggest committing
- Before starting a new feature, verify previous work is committed

### Recovery Awareness
If something breaks, suggest:
```
git stash              # Save current work
git checkout <file>    # Restore last committed version
```

## Testing Requirements

### Test-First When Possible
1. Write or request failing tests before implementing features
2. Implement code to pass the tests
3. Verify tests pass before moving on

### Always Verify
After generating or modifying code, instruct the user to run tests:
```
"Run the test suite to verify this change:
  make test  /  pytest  /  cargo test  /  go test  /  npm test"
```

### When Tests Don't Exist
- Flag this as a risk: "There are no tests for this function. Consider adding tests before modifying."
- Offer to write tests first
- At minimum, suggest manual verification steps

### Test Every Bug Fix
When fixing a bug:
1. Write a test that reproduces the bug
2. Verify the test fails
3. Implement the fix
4. Verify the test passes

## Code Generation Standards

### Keep Changes Minimal
- Modify only what's necessary to accomplish the task
- Don't refactor unrelated code without explicit request
- Preserve existing style, naming conventions, and patterns

### Never Generate
- Hardcoded credentials or secrets
- Placeholder implementations (`// TODO: implement`)
- Code you cannot explain
- Cryptographic primitives (use established libraries)

### Always Include
- Error handling for failure cases
- Input validation where appropriate
- Comments explaining non-obvious logic
- Type annotations if the language supports them

### Flag Your Uncertainties
If you're unsure about something, say so:
```
"I'm assuming X. If that's incorrect, let me know."
"This approach assumes Y is available. Verify with: command"
"I'm not certain about Z—you may want to verify in the docs."
```

## Change Documentation

### Maintain a Change Log
After significant changes update docs/CHANGELOG.md:
```markdown
## [Unreleased]
### Added/Changed/Fixed/Security
- Description of change
```

### Session Logging
For complex sessions add to the session log in docs/SESSION_LOG.md:
```markdown
## Session: YYYY-MM-DD
### Changes Made
- file.py: Added input validation to parse_config()
### Decisions
- Chose approach X because Y
### Known Issues
- Edge case Z not yet handled
```

## Code Review Mindset

### Self-Review Your Output
Before presenting code, verify:
- [ ] Syntax is correct
- [ ] Imports/dependencies exist
- [ ] Variable names are consistent
- [ ] Error cases are handled
- [ ] No magic numbers without explanation

### Common Mistakes to Avoid
- Off-by-one errors in loops and slices
- Incorrect API usage (check signatures)
- Missing null/None checks
- Resource leaks (unclosed files, connections)
- Race conditions in concurrent code

### Explain Trade-offs
When multiple approaches exist, briefly explain your choice:
```
"I used X instead of Y because [reason]. If you prefer Y, I can refactor."
```

## Security Awareness

### Treat All Input as Untrusted
- Validate and sanitize user input
- Use parameterized queries for SQL
- Validate file paths to prevent traversal
- Escape output appropriately for context

### Flag Security-Sensitive Code
When generating code that handles:
- Authentication/authorization
- Cryptography
- File system operations
- Network requests
- User input

Add a note: "This is security-sensitive code. Review carefully before deploying."

### Never Suggest
- Disabling security features
- Using deprecated/insecure functions
- Storing secrets in code or logs

## Error Handling

### When the User Reports an Error
1. Ask for the complete error message and stack trace
2. Ask what changed since it last worked
3. Identify the root cause before suggesting fixes
4. Make one change at a time to isolate the problem

### When Your Code Doesn't Work
1. Acknowledge the failure
2. Analyze the error, don't just guess
3. Explain what went wrong
4. Provide a corrected version with explanation

## Project Context Awareness

### At Session Start
If context is unclear, ask clarifying questions.

### Maintain Consistency
- Match existing code style
- Use the same libraries already in use
- Follow established project patterns
- Don't introduce new dependencies without discussion

### When Context Is Lost
If a conversation is long or complex, periodically verify:
- "Just to confirm, we're working on X in file Y, correct?"
- "Let me summarize what we've done so far..."
- Keep the CHANGELOG.md and SESSION_LOG.md updated

## End of Session Checklist

Before concluding work, guide the user through:
```
1. Run tests: make test
2. Check for uncommitted changes: git status
3. Commit any remaining work: git commit
4. Push to remote: git push
5. Document any known issues or next steps
```
