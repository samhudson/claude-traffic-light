# Releasing

Releases follow [Semantic Versioning](https://semver.org) and are cut from `main` with one command. A tag starts the pipeline; nothing is published by hand.

```
commit to main ──▶ CI (tests on macOS)
                    │
script/release --rc ──▶ vX.Y.Z-rc.N ──▶ GitHub pre-release      try it
                    │
script/release --promote ──▶ vX.Y.Z ──▶ GitHub Release + Homebrew tap
```

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org). They decide the next version and write the changelog.

| Prefix | Example | Next version |
|---|---|---|
| `fix:` | `fix: keep one copy of the app running` | patch (1.2.3 → 1.2.4) |
| `feat:` | `feat: show usage credits` | minor (1.2.3 → 1.3.0) |
| `feat!:` or `BREAKING CHANGE:` | `feat!: drop the SwiftBar plugin` | major (1.2.3 → 2.0.0) |
| `docs:`, `test:`, `chore:`, `refactor:` | `docs: new screenshots` | listed under Other |

## Cut a release

```bash
script/release --dry-run          # see the next version and the changelog
script/release --rc               # tag a release candidate, e.g. v1.3.0-rc.1
brew install --HEAD …             # or test the pre-release however you like
script/release --promote          # same commit becomes v1.3.0
```

Or skip the candidate: `script/release` (or `patch`, `minor`, `major`, `1.4.0`).

`script/release` checks that you're on a clean, pushed `main`, runs the tests, sets the version in the CLI, adds the changelog section, commits `chore(release): vX.Y.Z`, tags and pushes.

## What the pipeline does

**CI** (`.github/workflows/ci.yml`) runs the tests and builds the app on every push and pull request. It's read-only and gets no secrets, so pull requests from forks are safe.

**Release** (`.github/workflows/release.yml`) runs on version tags:

1. Checks the tag is a version and matches the code.
2. Runs the tests and builds the app, exactly as `brew install` will.
3. Publishes a GitHub Release with the source tarball, its SHA-256 and the changelog section. Release candidates are marked pre-release.
4. For final releases, points the Homebrew formula at the new version (`script/update-tap`).

Run it by hand on any tag from the Actions tab (dry run by default) to check a release without publishing.

## One-time setup: the tap token

The Release workflow updates `samhudson/homebrew-tap` with a token that can do nothing else:

1. GitHub → Settings → Developer settings → Fine-grained tokens → Generate new token.
2. Repository access: **only `samhudson/homebrew-tap`**. Permissions: **Contents: read and write**.
3. Save it as a secret named `TAP_TOKEN` in this repo: `gh secret set TAP_TOKEN -R samhudson/trafficlight`.

Without it, releases still publish; the workflow warns and the tap can be updated by hand with `script/update-tap vX.Y.Z`.

## Where it's hosted

- **GitHub Releases**: every version's source tarball and checksum.
- **Homebrew tap** (`samhudson/homebrew-tap`): how people install. Public repos use the release tarball and SHA-256; private repos use the git tag.
- The tarball and checksum are plain files, so they can be mirrored anywhere (your own domain, a CDN) without changing the formula's checksum.
