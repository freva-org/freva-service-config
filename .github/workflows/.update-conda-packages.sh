#!/usr/bin/env bash
set -euo pipefail

# Detect if we are running inside GitHub Actions
if [[ -z "${GITHUB_ACTIONS:-}" ]]; then
  echo "💡 Running outside CI: dry run mode enabled."
  DRY_RUN=1
else
  DRY_RUN=0
fi

# Detect conda-compatible tool
TOOL=""
for cmd in micromamba mamba conda; do
  if command -v "$cmd" &>/dev/null; then
    TOOL="$cmd"
    break
  fi
done

if [[ -z "$TOOL" ]]; then
  echo "❌ No conda-compatible tool (micromamba, mamba, conda) found in PATH."
  exit 1
fi

HERE=$(dirname "$0")
echo "🔍 Using $TOOL for conda-forge and PyPI for pip packages..."
failed=0

# One pull request per service, for every pinned package that has a newer
# version, by the rules in .find-updates.py (a "# update: ..." comment per
# line; without one only the first line of requirements.txt is updated).
for req_file in */requirements.txt; do
  [ -f "$req_file" ] || continue
  service=$(dirname "$req_file")

  echo "📦 Checking $service..."
  # Each line: file, package, old version, new version (tab separated).
  # Outside a dry run the files are rewritten right away; the changes
  # either go onto the bump branch or are dropped again below.
  apply=()
  [[ "$DRY_RUN" -eq 0 ]] && apply=(--apply)
  if ! bumps=$(python3 "$HERE/.find-updates.py" --tool "$TOOL" "${apply[@]}" "$service"); then
    echo "::error::Could not check $service, see above"
    git checkout -- "$service"
    failed=1
    continue
  fi
  [[ -z "$bumps" ]] && continue

  mapfile -t lines <<< "$bumps"
  if [[ ${#lines[@]} -eq 1 ]]; then
    IFS=$'\t' read -r file pkg old_version latest_version <<< "${lines[0]}"
    # The branch name of a single bump is the one the updater always used,
    # so an open PR from before is still recognised.
    BRANCH="bump-${pkg}-${old_version}-${latest_version}"
    PR_TITLE="⬆️ bump ${pkg}: ${old_version} → ${latest_version}"
  else
    BRANCH="bump-${service}-$(printf '%s' "$bumps" | sha1sum | cut -c1-8)"
    PR_TITLE="⬆️ bump ${service}: $(printf '%s\n' "${lines[@]}" | awk -F'\t' '{printf "%s%s %s → %s", (NR>1 ? ", " : ""), $2, $3, $4}')"
  fi
  PR_BODY="This PR updates **${service}**:"$'\n\n'"| Package | File | From | To |"$'\n'"| --- | --- | --- | --- |"
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r file pkg old_version latest_version <<< "$line"
    echo "🔄 $pkg: $old_version → $latest_version ($file)"
    PR_BODY+=$'\n'"| ${pkg} | \`${file}\` | \`${old_version}\` | \`${latest_version}\` |"
  done

  # Opt-in per service: a <service>/.automerge file on main lets the bot
  # approve the PR; CI merges it once all checks have passed.
  AUTOMERGE=0
  if [[ -f "${service}/.automerge" ]]; then
    AUTOMERGE=1
    PR_BODY+=$'\n\n'"🤖 \`${service}/.automerge\` exists: this PR is approved by the bot and merged automatically once CI passes."
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "💡 [Dry run] Would create PR: $PR_TITLE (auto-merge: $AUTOMERGE)"
    continue
  fi

  # Check if PR already exists
  if gh pr list --state open --head "$BRANCH" | grep -q "$BRANCH"; then
    echo "ℹ️ PR already exists: $BRANCH, skipping"
    git checkout -- "$service"
    continue
  fi

  # Create the branch; it takes the rewritten files along.
  git switch -c "$BRANCH"

  git config user.name "conda-bot"
  git config user.email "bot@conda-updater"
  git commit -qam "$PR_TITLE"
  git push origin "$BRANCH"

  # Create pull request (as github-actions[bot], see update-conda.yml)
  pr_url=$(gh pr create \
    --title "$PR_TITLE" \
    --body "$PR_BODY" \
    --head "$BRANCH" \
    --base main)
  echo "📬 Created $pr_url"

  if [[ "$AUTOMERGE" -eq 1 ]]; then
    if [[ -z "${BOT_TOKEN:-}" ]]; then
      echo "⚠️  ${service}/.automerge exists but BOT_TOKEN is not set, leaving $pr_url for review"
    else
      # Approve as the freva bot (not the PR author) and mark the PR with
      # the "automerge" label. The merge itself is done by the "automerge"
      # job in docker-build.yml, after "CI result" has passed for exactly
      # the head commit. Merging here with `gh pr merge --auto` would merge
      # at once whenever branch protection requires no status check.
      # A failure here must not stop the remaining services from being
      # updated; the PR then simply stays open for review.
      GH_TOKEN="$BOT_TOKEN" gh label create automerge --force \
        --color 0E8A16 --description "Merged by CI once all checks pass" \
        >/dev/null 2>&1 || true
      GH_TOKEN="$BOT_TOKEN" gh pr review "$pr_url" --approve \
        --body "Automatic version bump for \`${service}\`, approved because \`${service}/.automerge\` exists. It is merged once CI passes." \
        || echo "⚠️  Could not approve $pr_url"
      GH_TOKEN="$BOT_TOKEN" gh pr edit "$pr_url" --add-label automerge \
        || echo "⚠️  Could not label $pr_url for auto-merge"
    fi
  fi

  # Switch back to main and clean up
  git switch main
  git branch -D "$BRANCH"
done

exit "$failed"
