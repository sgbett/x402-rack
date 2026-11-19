# Release x402-rack

Guided release workflow for the x402-rack gem, in two runs: the first opens the release PR, the second, once that PR is merged, tags and publishes. The default branch takes changes only by PR (2026-11-18, sgbett/dotfiles-claude#30), so the version bump lands by PR and the tag alone is pushed direct.

---

## Step 1: Pre-flight Checks

Run all four checks. Abort on any failure. Both parts start from a clean, current `master`.

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

## Step 2: Which Part

Read the current version:
```bash
grep "VERSION = " lib/x402/version.rb
```
Store as `CURRENT_VERSION`.

The tag for the version on master says where the release stands:
```bash
git tag | grep "^v${CURRENT_VERSION}$"
```

- **Tag exists:** `$CURRENT_VERSION` is released. Continue with **Part 1** to prepare the next release.
- **Tag absent:** master carries an unreleased version, the merged release PR. Continue with **Part 2** to tag and publish it.

If the tag is absent and no release PR for `v${CURRENT_VERSION}` was ever merged (the gem has never been released), continue with Part 1 instead.

---

# Part 1: Prepare the Release PR

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

**Already-released checks on `$NEW_VERSION`.**

**Check 1 — Tag does not already exist:**
```bash
git tag | grep "^v${NEW_VERSION}$"
```
Abort if tag exists:
> Already-released check failed: tag `v${NEW_VERSION}` already exists.
> Choose another version, then re-run `/release`.

**Check 2 — Version not already on RubyGems** (soft check):
```bash
gem search --remote --exact "x402-rack" 2>&1
```
If output contains `$NEW_VERSION`, abort:
> Already-released check failed: `x402-rack $NEW_VERSION` is already published on RubyGems.
> Choose another version.

If the command times out or fails, warn and continue.

Display: "Already-released checks passed. `$NEW_VERSION` is not yet released."

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

## Step 6: Create the Release Branch

The bump is a change like any other, so it goes on its own branch and lands by PR.

```bash
git switch -c "release/v${NEW_VERSION}"
```

---

## Step 7: Bump Version File

Show what will change:
```
Will update lib/x402/version.rb:
  Before: VERSION = '$CURRENT_VERSION'
  After:  VERSION = '$NEW_VERSION'

Confirm? [y/N]
```

On confirmation, edit the version file using the Edit tool.

---

## Step 8: Update CHANGELOG.md

Read `CHANGELOG.md`. Insert `$CHANGELOG_ENTRY` after the top header and before the first existing `## x.y.z` entry.

Show the insertion and prompt for confirmation. On confirmation, update the file.

---

## Step 9: Commit

```bash
git add lib/x402/version.rb CHANGELOG.md
git commit -m "chore(release): v$NEW_VERSION"
```

Recovery:
> Commit failed. To roll back: `git checkout -- lib/x402/version.rb CHANGELOG.md && git switch master && git branch -D release/v${NEW_VERSION}`

---

## Step 10: Push the Branch and Open the PR

```
Ready to push release/v${NEW_VERSION} and open the release PR. This will:

  git push -u origin release/v${NEW_VERSION}
  gh pr create --title "chore(release): v${NEW_VERSION}"

Confirm? [y/N]
```

On confirmation, with the branch name written out in full (the push-guard hook asks about any push whose refspec holds an unexpanded `$`):
```bash
git push -u origin "release/v${NEW_VERSION}"
gh pr create --base master --head "release/v${NEW_VERSION}" \
  --title "chore(release): v${NEW_VERSION}" \
  --body "$CHANGELOG_ENTRY"
```

Display the PR URL.

Recovery:
> To push and open manually: `git push -u origin release/v${NEW_VERSION} && gh pr create --base master --head release/v${NEW_VERSION} --title "chore(release): v${NEW_VERSION}"`
> To roll back locally: `git switch master && git branch -D release/v${NEW_VERSION}`

---

## Step 11: Stop Until the PR Is Merged

Display:
```
Release PR opened: <url>

The release continues once the PR is merged. Merging is your call, and the ruleset requires the PR.
After the merge, run `/release` again from master: it tags the merge commit, builds the gem and publishes.
```

Stop here. Nothing in Part 2 runs in this invocation.

---

# Part 2: Tag and Publish

Run after the release PR is merged. `$CURRENT_VERSION` is now the version to release.

## Step 12: Confirm the Merge

Find the merge commit of the release PR, the first-parent commit on master that last changed the version file:
```bash
git log --first-parent --format='%H %s' -1 -- lib/x402/version.rb
```

Store the hash as `MERGE_SHA`. Display it and confirm it is the merge of `release/v${CURRENT_VERSION}`:
```
Release PR merged as:

  <sha> Merge pull request #N from sgbett/release/v${CURRENT_VERSION}

Tag this commit as v${CURRENT_VERSION}? [y/N]
```

Read the `## $CURRENT_VERSION` block at the top of `CHANGELOG.md` and store it as `CHANGELOG_ENTRY`; it is the release notes.

**Version not already on RubyGems** (soft check):
```bash
gem search --remote --exact "x402-rack" 2>&1
```
If output contains `$CURRENT_VERSION`, abort:
> Already-released check failed: `x402-rack $CURRENT_VERSION` is already published on RubyGems.
> Bump the version in `lib/x402/version.rb` to release a new version.

If the command times out or fails, warn and continue.

---

## Step 13: Create Tag

```
Will create tag: v${CURRENT_VERSION} at $MERGE_SHA

Confirm? [y/N]
```

On confirmation:
```bash
git tag "v${CURRENT_VERSION}" "$MERGE_SHA"
```

Recovery:
> Tag failed. To tag manually: `git tag v${CURRENT_VERSION} $MERGE_SHA`

---

## Step 14: Push the Tag

**Requires explicit user approval.** A pushed tag is public, and the gem release follows from it.

```
Ready to push the tag to origin. This will:

  git push origin v${CURRENT_VERSION}

Type YES to push, or anything else to stop here.
```

Only proceed if the user types `YES` (case-sensitive).

On confirmation, with the tag written out in full (the push-guard hook asks about any push whose refspec holds an unexpanded `$`):
```bash
git push origin "v${CURRENT_VERSION}"
```

Recovery:
> To push manually: `git push origin v${CURRENT_VERSION}`
> To drop it locally: `git tag -d v${CURRENT_VERSION}`

---

## Step 15: Build the Gem

Build from the tagged commit. If `HEAD` is not `$MERGE_SHA`, master has moved on since the release merge: `git checkout v${CURRENT_VERSION}` first and `git checkout master` after the build.

```bash
gem build x402-rack.gemspec
```

**Sanity check** — inspect the `.gem` contents:
```bash
tar -tzf x402-rack-${CURRENT_VERSION}.gem
```

Verify:
- `lib/` directory is present
- `CHANGELOG.md` is present
- `LICENSE` is present
- No unexpected files (e.g. `.env`, `spec/`, `tmp/`)

If anything looks wrong, warn and ask whether to continue.

---

## Step 16: Prompt User to Push to RubyGems

Display:
```
The gem has been built at:

  x402-rack-${CURRENT_VERSION}.gem

To publish to RubyGems, run this command yourself:

  gem push x402-rack-${CURRENT_VERSION}.gem

Confirm once pushed (or type 'skip' to continue to GitHub release):
```

Wait for user confirmation.

---

## Step 17: Create GitHub Release

```bash
gh release create "v${CURRENT_VERSION}" \
  --title "x402-rack ${CURRENT_VERSION}" \
  --notes "$CHANGELOG_ENTRY" \
  --target master

gh release upload "v${CURRENT_VERSION}" \
  "x402-rack-${CURRENT_VERSION}.gem"
```

Recovery:
> GitHub release failed. Create manually:
>   `gh release create v${CURRENT_VERSION} --title "x402-rack ${CURRENT_VERSION}" --notes "..."`

---

## Step 18: Summary

```
Release complete!

  Gem:             x402-rack
  Version:         $CURRENT_VERSION
  Tag:             v${CURRENT_VERSION}
  Commit:          $MERGE_SHA
  RubyGems:        https://rubygems.org/gems/x402-rack/versions/${CURRENT_VERSION}
  GitHub release:  https://github.com/sgbett/x402-rack/releases/tag/v${CURRENT_VERSION}
```

---

## Abort Recovery Quick Reference

| Step failed | State | Recovery |
|-------------|-------|----------|
| Pre-flight | Nothing changed | Fix issue, run `/release` again |
| Already-released | Nothing changed | Choose another version, run `/release` again |
| Version bump / changelog | Files modified on the release branch, not committed | `git checkout -- lib/x402/version.rb CHANGELOG.md && git switch master && git branch -D release/v${NEW_VERSION}` |
| Commit | Committed on the release branch, PR not open | `git push -u origin release/v${NEW_VERSION} && gh pr create ...` manually |
| Merge | PR open | Merge it, then run `/release` again from master |
| Tag | Merged, not tagged | `git tag v${CURRENT_VERSION} $MERGE_SHA` |
| Tag push | Tagged locally only | `git push origin v${CURRENT_VERSION}` |
| Build | Tagged, pushed | `gem build x402-rack.gemspec` |
| RubyGems | Built, not on RubyGems | `gem push x402-rack-${CURRENT_VERSION}.gem` |
| GitHub release | On RubyGems, no GH release | `gh release create ...` manually |
