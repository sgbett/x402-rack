# Release x402-rack

Guided release workflow for the x402-rack gem.

---

## Step 1: Pre-flight Checks

Run all four checks. Abort on any failure.

**Check 1 — gh CLI authenticated:**
```bash
gh auth status
```
Abort if not authenticated:
> Pre-flight failed: `gh` CLI is not authenticated. Run `gh auth login` and retry.

**Check 2 — Clean working tree:**
```bash
git status --porcelain
```
Abort if any output:
> Pre-flight failed: working tree is dirty. Commit or stash your changes before releasing.

**Check 3 — On master branch:**
```bash
git branch --show-current
```
Abort if not `master`:
> Pre-flight failed: you are on branch `<branch>`, not `master`. Switch to master before releasing.

**Check 4 — Local master up to date with origin:**
```bash
git fetch origin master
git status -uno
```
Abort if behind:
> Pre-flight failed: local master is behind origin/master. Run `git pull` before releasing.

Display: "Pre-flight checks passed."

---

## Step 2: Already-Released Checks

Read the current version:
```bash
grep "VERSION = " lib/x402/version.rb
```
Store as `CURRENT_VERSION`.

**Check 1 — Tag does not already exist:**
```bash
git tag | grep "^v${CURRENT_VERSION}$"
```
Abort if tag exists:
> Already-released check failed: tag `v${CURRENT_VERSION}` already exists.
> Bump the version first, then re-run `/release`.

**Check 2 — Version not already on RubyGems** (soft check):
```bash
gem search --remote --exact "x402-rack" 2>&1
```
If output contains `$CURRENT_VERSION`, abort:
> Already-released check failed: `x402-rack $CURRENT_VERSION` is already published on RubyGems.
> Bump the version in `lib/x402/version.rb` to release a new version.

If the command times out or fails, warn and continue.

Display: "Already-released checks passed. Current version `$CURRENT_VERSION` is not yet released."

---

## Step 3: Determine Last Tag

Find the most recent tag:
```bash
git tag | grep "^v" | sort -V | tail -1
```

If no tag found, fall back to the earliest commit:
```bash
git log --oneline --reverse | head -1
```

Store as `LAST_TAG`.

---

## Step 4: Suggest Version Bump

Gather conventional commits since the last tag:
```bash
git log ${LAST_TAG}..HEAD --oneline
```

Apply bump rules (first match wins):
- Any commit matching `feat!:` or `fix!:` or `!:` → **MAJOR**
- Any commit matching `feat:` → **MINOR**
- Otherwise → **PATCH**

Show suggested bump with reasoning and list of commits. Wait for user to confirm or provide a custom version. Store as `NEW_VERSION`.

---

## Step 5: Generate Changelog Draft

Group commits by conventional commit type into Keep a Changelog sections:
- `feat:` / `feat!:` → **Added** (breaking: also **Breaking Changes**)
- `fix:` → **Fixed**
- `refactor:` / `perf:` → **Changed**
- `build:` → **Changed** (only if it affects users, e.g. dependency bumps)
- `docs:` / `test:` / `chore:` / `ci:` → omit unless user-facing

Format as:
```markdown
## $NEW_VERSION — YYYY-MM-DD

### Added
- Description

### Fixed
- Description
```

Display the draft and prompt for confirmation or edits. Store as `CHANGELOG_ENTRY`.

---

## Step 6: Bump Version File

Show what will change:
```
Will update lib/x402/version.rb:
  Before: VERSION = '$CURRENT_VERSION'
  After:  VERSION = '$NEW_VERSION'

Confirm? [y/N]
```

On confirmation, edit the version file using the Edit tool.

---

## Step 7: Update CHANGELOG.md

Read `CHANGELOG.md`. Insert `$CHANGELOG_ENTRY` after the top header and before the first existing `## x.y.z` entry.

Show the insertion and prompt for confirmation. On confirmation, update the file.

---

## Step 8: Commit

```bash
git add lib/x402/version.rb CHANGELOG.md
git commit -m "chore: release v$NEW_VERSION"
```

Recovery:
> Commit failed. To roll back: `git checkout -- lib/x402/version.rb CHANGELOG.md`

---

## Step 9: Create Tag

```
Will create tag: v${NEW_VERSION}

Confirm? [y/N]
```

On confirmation:
```bash
git tag "v${NEW_VERSION}"
```

Recovery:
> Tag failed. To tag manually: `git tag v${NEW_VERSION}`
> To roll back: `git reset HEAD~1`

---

## Step 10: Push to Origin

**Requires explicit user approval.** Pushing is irreversible without force-push.

```
Ready to push to origin/master. This will:

  git push origin master
  git push origin v${NEW_VERSION}

Type YES to push, or anything else to stop here.
```

Only proceed if the user types `YES` (case-sensitive).

Recovery:
> To push manually: `git push origin master && git push origin v${NEW_VERSION}`
> To roll back: `git tag -d v${NEW_VERSION} && git reset HEAD~1`

---

## Step 11: Build the Gem

```bash
gem build x402-rack.gemspec
```

**Sanity check** — inspect the `.gem` contents:
```bash
tar -tzf x402-rack-${NEW_VERSION}.gem
```

Verify:
- `lib/` directory is present
- `CHANGELOG.md` is present
- `LICENSE` is present
- No unexpected files (e.g. `.env`, `spec/`, `tmp/`)

If anything looks wrong, warn and ask whether to continue.

---

## Step 12: Prompt User to Push to RubyGems

Display:
```
The gem has been built at:

  x402-rack-${NEW_VERSION}.gem

To publish to RubyGems, run this command yourself:

  gem push x402-rack-${NEW_VERSION}.gem

Confirm once pushed (or type 'skip' to continue to GitHub release):
```

Wait for user confirmation.

---

## Step 13: Create GitHub Release

```bash
gh release create "v${NEW_VERSION}" \
  --title "x402-rack ${NEW_VERSION}" \
  --notes "$CHANGELOG_ENTRY" \
  --target master

gh release upload "v${NEW_VERSION}" \
  "x402-rack-${NEW_VERSION}.gem"
```

Recovery:
> GitHub release failed. Create manually:
>   `gh release create v${NEW_VERSION} --title "x402-rack ${NEW_VERSION}" --notes "..."`

---

## Step 14: Summary

```
Release complete!

  Gem:             x402-rack
  Version:         $NEW_VERSION
  Tag:             v${NEW_VERSION}
  Commit:          <sha>
  RubyGems:        https://rubygems.org/gems/x402-rack/versions/${NEW_VERSION}
  GitHub release:  https://github.com/sgbett/x402-rack/releases/tag/v${NEW_VERSION}
```

---

## Abort Recovery Quick Reference

| Step failed | State | Recovery |
|-------------|-------|----------|
| Pre-flight | Nothing changed | Fix issue, run `/release` again |
| Already-released | Nothing changed | Bump version, run `/release` again |
| Version bump / changelog | Files modified, not committed | `git checkout -- lib/x402/version.rb CHANGELOG.md` |
| Commit | Committed, not tagged | `git reset HEAD~1` |
| Tag | Tagged, not pushed | `git tag -d v${NEW_VERSION} && git reset HEAD~1` |
| Push | Pushed, not built | `gem build x402-rack.gemspec` |
| RubyGems | Built, not on RubyGems | `gem push x402-rack-${NEW_VERSION}.gem` |
| GitHub release | On RubyGems, no GH release | `gh release create ...` manually |
