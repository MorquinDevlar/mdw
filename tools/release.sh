#!/usr/bin/env bash
#
# Cut an MDW release. Usage: tools/release.sh X.Y.Z
#
# One command for the whole sequence, so every release is made the same way:
# bump the two version strings, run the verification gate, build the package,
# promote the changelog, commit, tag, push, publish the GitHub release, and
# push the sibling wiki clone.
#
# The script expects the CHANGELOG "Unreleased" discipline: each change lands
# with its entry under "## Unreleased" as it is written, so at release time
# there are no notes to reconstruct from the git log. The promoted section
# becomes the GitHub release notes verbatim, and an empty Unreleased section
# is a hard stop rather than a release with no notes.
#
# The tag format vX.Y.Z and the asset name MDW.mpackage are a CONTRACT: game
# packages bootstrap MDW by pinning
#   https://github.com/MorquinDevlar/mdw/releases/download/vX.Y.Z/MDW.mpackage
# so changing either one breaks every consumer's install/update path.

set -euo pipefail

die() {
    printf 'release: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '==> %s\n' "$*"
}

# Everything from the bump onwards is undone on failure, so a botched run
# leaves the tree exactly as clean as it was found.
restore_and_die() {
    git checkout -- mfile src/scripts/MDW_Config.lua CHANGELOG.md
    die "$*"
}

[ $# -eq 1 ] || die "usage: tools/release.sh X.Y.Z"
version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z, got '$version'"
tag="v$version"

repo_root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
cd "$repo_root"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
notes_file="$tmpdir/notes.md"

step "Checking prerequisites"
for tool in git gh lua5.1 muddle; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not on PATH: $tool"
done
# luacheck is a luarocks install, whose bin dir is often not on PATH.
if command -v luacheck >/dev/null 2>&1; then
    luacheck=luacheck
else
    luacheck="$HOME/.luarocks/bin/luacheck"
fi
[ -x "$luacheck" ] || die "luacheck not found on PATH or at $luacheck"
# An unauthenticated gh would only fail at the very end, after the tag is
# already pushed - a half-made release. Fail here instead.
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run 'gh auth login' first"

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = main ] || die "releases are cut from main, but HEAD is on '$branch'"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean; commit or stash first"

step "Fetching origin"
git fetch origin
# Being ahead of origin is fine - the script pushes main itself, so unpushed
# commits (e.g. the one /commit just made) ride along. Being behind is the
# hazard: the push would be rejected after the release commit and tag exist.
git merge-base --is-ancestor origin/main main ||
    die "main is behind origin/main; pull first"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    die "tag $tag already exists locally"
fi
if [ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]; then
    die "tag $tag already exists on origin"
fi
if gh release view "$tag" >/dev/null 2>&1; then
    die "a GitHub release for $tag already exists"
fi

[ -f CHANGELOG.md ] || die "CHANGELOG.md is missing"
grep -q '^## Unreleased[[:space:]]*$' CHANGELOG.md || die "CHANGELOG.md has no '## Unreleased' heading"
if ! awk '/^## Unreleased[[:space:]]*$/ { inside = 1; next }
          inside && /^## / { exit }
          inside' CHANGELOG.md | grep -q '[^[:space:]]'; then
    die "the '## Unreleased' section is empty; write the release notes under '## Unreleased' first"
fi

# The smoke suite asserts mfile and mdw.version agree, so both must be bumped
# before the gate runs, not after it.
step "Bumping version to $version"
sed "s/\"version\": \"[^\"]*\"/\"version\": \"$version\"/" mfile >"$tmpdir/mfile"
mv "$tmpdir/mfile" mfile
sed "s/^mdw\.version = \".*\"/mdw.version = \"$version\"/" src/scripts/MDW_Config.lua >"$tmpdir/config.lua"
mv "$tmpdir/config.lua" src/scripts/MDW_Config.lua
grep -q "\"version\": \"$version\"" mfile || restore_and_die "failed to bump the version in mfile"
grep -q "^mdw\.version = \"$version\"$" src/scripts/MDW_Config.lua ||
    restore_and_die "failed to bump mdw.version in src/scripts/MDW_Config.lua"

step "Promoting the changelog"
today=$(date +%F)
heading="## $version - $today"
awk -v heading="$heading" '
    !promoted && /^## Unreleased[[:space:]]*$/ {
        print "## Unreleased"
        print ""
        print heading
        promoted = 1
        next
    }
    { print }
' CHANGELOG.md >"$tmpdir/CHANGELOG.md"
mv "$tmpdir/CHANGELOG.md" CHANGELOG.md
# The section body, minus leading and trailing blank lines, is the release note.
awk -v heading="$heading" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside
' CHANGELOG.md | awk '
    /[^[:space:]]/ { for (i = 0; i < blanks; i++) print ""; blanks = 0; started = 1; print; next }
    started { blanks++ }
' >"$notes_file"
[ -s "$notes_file" ] || restore_and_die "could not extract release notes for $version"

step "Running the smoke suite"
lua5.1 tests/smoke.lua || restore_and_die "smoke suite failed"
step "Running luacheck"
"$luacheck" src/ tests/ || restore_and_die "luacheck reported warnings"
step "Building the package"
muddle || restore_and_die "muddle build failed"
[ -s build/MDW.mpackage ] || restore_and_die "muddle produced no build/MDW.mpackage"

step "Committing"
git add mfile src/scripts/MDW_Config.lua CHANGELOG.md
git commit -m "Release $version"

step "Tagging $tag"
git tag -a "$tag" -m "MDW $version"

step "Pushing to origin"
git push origin main
git push origin "$tag"

# The asset keeps its basename, MDW.mpackage, which is the half of the
# download URL consumers pin.
step "Publishing the GitHub release"
release_url=$(gh release create "$tag" build/MDW.mpackage --title "$tag" --notes-file "$notes_file")
printf '    %s\n' "$release_url"

# Wiki pages document the behavior a release ships, so they go out with it -
# but a wiki that is behind must never abort a release that already published.
step "Checking the wiki clone"
wiki_dir="$(dirname "$repo_root")/mdw.wiki"
if [ -d "$wiki_dir/.git" ]; then
    if [ -n "$(git -C "$wiki_dir" status --porcelain)" ]; then
        printf 'release: warning: %s has uncommitted changes; they were NOT pushed (commit them by hand)\n' \
            "$wiki_dir" >&2
    fi
    # GitHub wikis are on master, not main.
    wiki_branch=$(git -C "$wiki_dir" rev-parse --abbrev-ref HEAD)
    if git -C "$wiki_dir" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1; then
        ahead=$(git -C "$wiki_dir" rev-list --count '@{upstream}..HEAD')
        if [ "$ahead" -gt 0 ]; then
            if git -C "$wiki_dir" push origin "$wiki_branch"; then
                wiki_status="pushed $ahead commit(s) from $wiki_branch"
            else
                wiki_status="PUSH FAILED, push $wiki_dir by hand"
            fi
        else
            wiki_status="already up to date"
        fi
    else
        wiki_status="branch $wiki_branch has no upstream, push by hand"
    fi
else
    wiki_status="no clone at $wiki_dir, skipped"
fi
printf '    %s\n' "$wiki_status"

printf '\nReleased MDW %s\n' "$version"
printf '  tag:     %s\n' "$tag"
printf '  release: %s\n' "$release_url"
printf '  wiki:    %s\n' "$wiki_status"
