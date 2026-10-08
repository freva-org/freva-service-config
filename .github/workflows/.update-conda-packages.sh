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

CHANNEL="conda-forge"
echo "🔍 Using $TOOL to check latest versions from $CHANNEL..."

# Iterate over each requirements.txt file
for req_file in */requirements.txt; do
  [ -f "$req_file" ] || continue

  service=$(dirname "$req_file")
  first_line=$(grep '=' $req_file | grep -v '#' | head -n 1)
  pkg=$(echo "$first_line" | cut -d= -f1)
  old_version=$(echo "$first_line" | cut -d= -f2)

  echo "📦 Checking latest version of $pkg for $service..."

  latest_version=$($TOOL search "$pkg" --channel "$CHANNEL" --json | \
    jq -r ".[\"result\"][\"pkgs\"]| map(.version) | max_by( split(\".\") | map(tonumber) )")

  if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
    echo "⚠️  Could not determine latest version for $pkg"
    continue
  fi

  if [[ "$latest_version" == "$old_version" ]]; then
    echo "✅ $pkg is up-to-date ($latest_version)"
    continue
  fi

  echo "🔄 $pkg: $old_version → $latest_version"

  BRANCH="bump-${pkg}-${old_version}-${latest_version}"
  PR_TITLE="⬆️ bump ${pkg}: ${old_version} → ${latest_version}"
  PR_BODY="This PR updates **${pkg}** from version \`${old_version}\` to \`${latest_version}\` in \`${req_file}\`."

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
    echo "ℹ️ PR already exists: $BRANCH — skipping"
    continue
  fi

  # Create temp branch and commit
  git switch -c "$BRANCH"
  tail -n +2 "$req_file" > tmp.txt
  echo "${pkg}=${latest_version}" > "$req_file"
  cat tmp.txt >> "$req_file"
  rm tmp.txt

  git config user.name "conda-bot"
  git config user.email "bot@conda-updater"
  git commit -am "$PR_TITLE"
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
