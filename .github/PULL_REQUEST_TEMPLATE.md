## Why

<!-- What problem does this PR solve, or what opportunity does it take? Link any related issues. -->

## What Changed

<!-- A concise description of the code changes. What was added, removed, or modified? -->

## Alternatives Considered

<!-- What other approaches did you weigh? Why was this approach chosen? -->

## ADRs & Architecture

<!-- Any new architectural decisions? Reference existing ADRs or note if a new one is needed. -->

## Testing

<!-- How was this tested? Describe the test tier (unit / host itest / ctest / controller itest) and
any manual steps used to verify the change. -->

---

**Checklist**

- [ ] `make test build drift itest` passes locally
- [ ] `make contracts` passes if `packages/agent-contracts` or `agentcore/crds` were touched
- [ ] `make regen` was run and output committed if D CRD structs were modified
- [ ] `CHANGELOG.md` updated under `## Unreleased` for any user-visible change
- [ ] No secrets, tokens, or credentials in the diff
- [ ] PR title follows conventional-commit style (`type(scope): description`)
