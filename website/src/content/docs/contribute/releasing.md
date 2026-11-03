---
title: Releasing the client libraries
description: How a v* tag publishes every contract package, and the one-time registry setup it needs.
---

Every client library is released from one `v*` tag. The `publish-contracts.yml` workflow runs the
drift and version checks, then publishes each package at the tag's version:

| Library | Package | Published to |
| --- | --- | --- |
| TypeScript | `@re-cinq/agent-contracts` | npm |
| Go | `packages/agent-contracts-go` | Go module tag on this repo |
| Java | `com.re-cinq:agent-contracts` | GitHub Packages (Maven) |
| Python | `re-cinq-agent-contracts` | PyPI |
| C# | `ReCinq.AgentContracts` | GitHub Packages (NuGet) |
| Rust | `agent-contracts` | Not published; consumers depend on the git tag |

No registry secret is stored in the repository. npm and PyPI use trusted publishing over OIDC, and
GitHub Packages uses the workflow's `GITHUB_TOKEN`.

## One-time setup

1. **npm.** The first publish of `@re-cinq/agent-contracts` is done once with a token. Then add a
   trusted publisher on npmjs.com for this repository and `publish-contracts.yml`.
2. **PyPI.** On pypi.org, under Account → Publishing, add a pending GitHub publisher:

   | Field | Value |
   | --- | --- |
   | PyPI project name | `re-cinq-agent-contracts` |
   | Owner | `re-cinq` |
   | Repository name | `ai-agent-subsystem` |
   | Workflow name | `publish-contracts.yml` |
   | Environment name | empty |

   The first tag creates the project and the pending publisher becomes a normal one.
3. **GitHub Packages.** After the first release, set the Maven and NuGet packages to public in the
   organisation's package settings and link them to this repository. Consumers still need a GitHub
   token with `read:packages` to download them.

## Cutting a release

1. Set every package to the new version in a release PR, and move the `Unreleased` CHANGELOG
   entries under that version:

   ```sh
   scripts/bump-contracts-version.sh 0.16.0
   ```

2. Merge the PR once CI is green, then tag `main`:

   ```sh
   git tag v0.16.0
   git push origin v0.16.0
   ```

3. Watch the **Publish agent-contracts** run. `scripts/check-contracts-version.sh` fails the run
   when a manifest does not match the tag, so a missed bump never republishes an old version.

A failure in the npm or PyPI job almost always means the registry's trusted-publisher setting is
wrong, not the workflow.
