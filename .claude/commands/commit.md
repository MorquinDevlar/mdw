---
description: Commit work with verification first, a CHANGELOG entry under Unreleased, a docs check, and an optional release at the end.
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git status:*), Bash(git add:*), Bash(git commit:*), Bash(git pull:*), Bash(git rev-parse:*), Bash(git -C:*), Bash(lua5.1:*), Bash(luacheck:*), Bash(~/.luarocks/bin/luacheck:*), Bash(muddle), Bash(tools/release.sh:*), Read, Edit, AskUserQuestion
---

CRITICAL: Read and follow EVERY instruction in this file exactly. Do not fall back on default behaviors.

- Use the AskUserQuestion tool for ALL user questions (changelog, docs, release)
- The CHANGELOG is user-facing ONLY: development tooling, tests, CI, and
  Claude Code commands never get an entry - anyone interested reads the code
- NEVER bump the version here. `mfile` and `mdw.version` move only in
  `tools/release.sh`: game packages pin tagged releases, so an unreleased
  version string would advertise a release that does not exist
- Follow the execution order step by step

### Execution Order

Follow these steps in sequence - do not skip ahead to committing:

1. **Pull**: `git pull --ff-only`. If it fails (diverged history), stop and ask the user.
2. **Analyze**: `git status`, `git diff` (staged and unstaged), `git log -5 --oneline`. Read the whole diff and review it against the CLAUDE.md invariants: slot state only through `captureSlot`/`applySlot`/`clearSlot`; stacks are plain tables branched on `isStack`; live drags skip reflow and the release handler repaints; the set-semantics `mdw.*` function exists before any menu wiring; Geyser elements through `trackElement`/`deleteElement` and handlers through `registerHandler`; nothing in `src/` downloads or installs packages. Raise anything off BEFORE committing - that review is the point of this step.
3. **Verify**: run `lua5.1 tests/smoke.lua` and `luacheck src/ tests/` (fall back to `~/.luarocks/bin/luacheck` when `luacheck` is not on PATH). If `src/` or `mfile` changed, also run `muddle`. On any failure: stop, show the output, do not commit.
4. **Changelog**: classify; internal-only changes get NO entry (say so and move on); otherwise ask, draft, get approval, write (see Changelog Entry Process).
5. **Docs**: when the change touches the consumer contract or a documented behaviour, ask whether README and the wiki clone were updated (see Docs Process).
6. **Stage**: the relevant files, including `CHANGELOG.md` if it changed. Never `git add -A` blindly; say what is staged.
7. **Commit**: use the message format below.
8. **Release**: ask whether to cut a release now (see Release Process).

### Before Committing Checklist

Verify these are complete before running `git commit`:

- [ ] Pull: ran `git pull --ff-only`
- [ ] Verify: smoke suite and luacheck passed (and muddle, when `src/` or `mfile` changed)
- [ ] Changelog: internal-only -> no entry; consumer-facing -> asked, entry approved and written if wanted
- [ ] Docs: asked when the contract or a documented behaviour changed
- [ ] Version: NOT bumped
- [ ] Staging: `CHANGELOG.md` included if it was modified

---

### Changelog Entry Process

Two rules. First: entries land under `## Unreleased` in `CHANGELOG.md` in the same commit as the change, and `tools/release.sh` later turns that section into the GitHub release notes verbatim - whatever is written there is published. Second: the changelog is user-facing ONLY. Two readers: game-package authors (the `mdw.*` API and the seed-table contract) and players (what they see in the sidebars, header menus, and prompt bar). Development tooling, tests, CI, and Claude Code commands never get an entry; anyone interested reads the code.

**Consumer-facing paths (entry expected):**

- `src/scripts/`, `src/triggers/`, `src/resources/`
- `mfile` (the package description players read in the package manager)

**Internal paths (NO entry, do not ask):**

- `tests/`, `tools/`, `.claude/`, `CLAUDE.md`, `.luacheckrc`, `.gitignore`
- `README.md` and wiki-only changes, UNLESS they document a new consumer-facing pattern - then a one-line entry is right

**Process:**

1. Classify the changed files with the paths above plus your judgment.
2. Internal-only change: state that no changelog entry is added (the changelog is user-facing only) and continue with the next step. Otherwise use **AskUserQuestion**: "Add a CHANGELOG entry under Unreleased?" with options Yes/No, stating what looks consumer-facing.
3. If yes, draft the entry (do NOT write it yet):
   - One bullet per change under `### Added`, `### Changed`, `### Fixed`, or `### Removed` inside `## Unreleased`; create a subsection if missing and keep that order
   - Never add dates or version numbers - the release script does that
   - Name the `mdw.*` function, config key, or menu in backticks; describe behaviour, not implementation
   - A breaking change to the consumer API gets a **Breaking:** prefix
4. **Get the draft approved.** Show the complete draft in your response text, then use **AskUserQuestion**: "Use this changelog entry?" with options:
   - **Yes**: proceed
   - **Revise**: the user says what to change - rework the draft and ask again
5. Only after approval: edit `CHANGELOG.md` and stage it with the other changes.

**Example lines:**

- Good: "`mdw.setDockWidth` clamps to the window width instead of returning `err` for oversize values."
- Good: "Overflowing group tab bars shrink their labels instead of spilling past the bar."
- Bad: "Refactored reorganizeDock" (implementation, not behaviour)
- Bad: "Various fixes" (too vague)
- Bad: "Added a /commit command" or "Added a release script" (development tooling - never in the changelog)

---

### Docs Process

`README.md` and the wiki (`../mdw.wiki`, a sibling clone) both document the consumer contract; a behaviour change to it must update both. Wiki changes are pushed only alongside the release that ships the behaviour - `tools/release.sh` does that push and warns about uncommitted wiki changes. This command never commits in the wiki clone.

1. If the diff changes an `mdw.*` function, a config key, a seed-table behaviour, or a documented user-visible behaviour, use **AskUserQuestion**: "README and wiki updated for this change?" with options:
   - **Yes, both**: continue
   - **Not needed**: continue
   - **Do it now**: make the README edit and the matching wiki page edit, then continue
2. If the wiki has changes (`git -C ../mdw.wiki status --porcelain`), remind the user to commit them there so the next release can push them.

---

### Commit Message Style and Guidelines

When writing commit messages, follow this format:

1. **Title**: Brief, factual description of changes (50-72 characters maximum, no adjectives like "better", "improved", etc.)
2. **Body**: Bullet points listing specific changes:
   - Use past tense ("Fixed", "Added", "Removed", not "Fix", "Add", "Remove")
   - Be specific and technical
   - No subjective assessments (avoid "simpler", "better", "faster", "cleaner")
   - No hyperbole
   - Just state what changed, not why it is good
   - Group related changes together in this order: Added, Fixed, Changed, Removed
3. **Breaking changes**: List any breaking changes separately at the end

Example:

Clamp the dock width setters to the window

Added:

- Window-width clamp in mdw.setDockWidth and the dock splitter drag
- Smoke check for oversize setDockWidth values

Fixed:

- Negative dock geometry when a saved layout loads into a tiny window

Changed:

- setDockWidth returns the applied width instead of err on clamp

Keep it neutral, factual, and technical.

---

### Release Process

Releases are cut by `tools/release.sh X.Y.Z` and only by it. The script bumps `mfile` and `mdw.version`, promotes `## Unreleased` to `## X.Y.Z - <date>`, runs smoke/luacheck/muddle, commits "Release X.Y.Z", tags `vX.Y.Z`, pushes main (unpushed commits from this session ride along), publishes the GitHub release with `build/MDW.mpackage`, and pushes `../mdw.wiki` if it is ahead. The tag format and the asset name are a contract: game packages pin `https://github.com/MorquinDevlar/mdw/releases/download/vX.Y.Z/MDW.mpackage`.

1. Read the current version from `mfile` (`"version": "X.Y.Z"`).
2. Use **AskUserQuestion**: "Cut a release now?" with options (compute the concrete numbers into the labels):
   - **No** (Recommended): commit only; the Unreleased section keeps accumulating
   - **Patch** (X.Y.Z -> X.Y.Z+1): fixes, no new API
   - **Minor** (X.Y.Z -> X.Y+1.0): new capabilities - and, while MDW is 0.x, breaking changes to the consumer API
   - **Major** (X.Y.Z -> X+1.0.0): reserved for 1.0 and later breaking changes
3. If a bump was chosen: show the exact command (`tools/release.sh X.Y.Z`) and the full `## Unreleased` body (these become the release notes), state that it pushes main and the wiki, then use **AskUserQuestion**: "Run tools/release.sh X.Y.Z now?" with options Yes/No.
4. On Yes: run `tools/release.sh X.Y.Z` and relay its summary (tag, release URL, wiki status). On failure the script restores the tree to the committed state; report the failing step verbatim. Its preconditions: clean tree (the commit just made satisfies it), main not behind origin, `gh auth status` OK, a non-empty `## Unreleased`.
