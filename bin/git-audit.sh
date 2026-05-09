#!/usr/bin/env bash
# git-audit — scan local git repos under $HOME, write a markdown summary
# of dirty trees, untracked files, and unpushed commits to a per-machine
# file inside ~/Nextcloud. Each machine writes its own file so all three
# can be eyeballed together once Nextcloud syncs.
#
# Output: ~/Nextcloud/_machines/<hostname>/git-state.md
# Fallback (no Nextcloud yet): ~/Library/Logs/git-audit/git-state.md

set -u

SCAN_ROOT="${HOME}"
SCAN_DEPTH=4
HOSTNAME_SHORT="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"

if [ -d "${HOME}/Nextcloud" ]; then
  OUT_DIR="${HOME}/Nextcloud/_machines/${HOSTNAME_SHORT}"
else
  OUT_DIR="${HOME}/Library/Logs/git-audit"
fi
mkdir -p "${OUT_DIR}"
OUT_FILE="${OUT_DIR}/git-state.md"

# Find every .git directory (skip vendored ones).
# Use a temp file instead of `mapfile` so this works on stock macOS bash 3.2.
GIT_LIST="$(mktemp)"
find -L "${SCAN_ROOT}" -maxdepth "${SCAN_DEPTH}" -type d -name .git 2>/dev/null \
  | grep -v -E '/(node_modules|venv|\.venv|vendor|\.tox|build|dist)/' \
  | sort > "${GIT_LIST}"

NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"
TOTAL=0
NEEDS_ATTENTION=0
TMP="$(mktemp)"

while IFS= read -r git_dir; do
  repo_dir="$(dirname "${git_dir}")"
  TOTAL=$((TOTAL + 1))

  branch="$(git -C "${repo_dir}" rev-parse --abbrev-ref HEAD 2>/dev/null | head -1 | tr -d '\n')"
  [ -z "${branch}" ] && branch="(empty repo)"
  dirty_count="$(git -C "${repo_dir}" status --porcelain 2>/dev/null | grep -v '^??' | wc -l | tr -d ' ')"
  untracked_count="$(git -C "${repo_dir}" status --porcelain 2>/dev/null | grep -c '^??' || true)"

  upstream="$(git -C "${repo_dir}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo '')"
  if [ -n "${upstream}" ]; then
    ahead="$(git -C "${repo_dir}" rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)"
    behind="$(git -C "${repo_dir}" rev-list --count "HEAD..${upstream}" 2>/dev/null || echo 0)"
  else
    ahead="-"
    behind="-"
  fi

  last_commit="$(git -C "${repo_dir}" log -1 --format='%cr' 2>/dev/null || echo 'never')"

  flags=""
  needs=0
  [ "${dirty_count}" != "0" ] && { flags="${flags}DIRTY(${dirty_count}) "; needs=1; }
  [ "${untracked_count}" != "0" ] && { flags="${flags}UNTRACKED(${untracked_count}) "; needs=1; }
  [ "${ahead}" != "-" ] && [ "${ahead}" != "0" ] && { flags="${flags}AHEAD(${ahead}) "; needs=1; }
  [ "${ahead}" = "-" ] && { flags="${flags}NO-UPSTREAM "; needs=1; }
  [ -z "${flags}" ] && flags="clean"

  [ "${needs}" = "1" ] && NEEDS_ATTENTION=$((NEEDS_ATTENTION + 1))

  rel="${repo_dir#${HOME}/}"
  printf '| `%s` | %s | %s | %s | %s |\n' \
    "${rel}" "${branch}" "${flags}" "${last_commit}" "${ahead}/${behind}" >> "${TMP}"
done < "${GIT_LIST}"
rm -f "${GIT_LIST}"

{
  echo "# git-state — ${HOSTNAME_SHORT}"
  echo ""
  echo "_Last audit: ${NOW}_"
  echo ""
  echo "**${NEEDS_ATTENTION} of ${TOTAL} repos need attention.**"
  echo ""
  echo "| repo | branch | flags | last commit | ahead/behind |"
  echo "|------|--------|-------|-------------|--------------|"
  cat "${TMP}"
  echo ""
  echo "---"
  echo ""
  echo "## Legend"
  echo "- **DIRTY(n)** — n modified/staged files not yet committed"
  echo "- **UNTRACKED(n)** — n new files git doesn't know about (often the most dangerous — easy to forget)"
  echo "- **AHEAD(n)** — n commits committed locally but not pushed"
  echo "- **NO-UPSTREAM** — branch has no remote tracking ref (\`git push -u\` once)"
  echo ""
  echo "Open this file from another machine via Nextcloud to see what each one is sitting on."
} > "${OUT_FILE}"

rm -f "${TMP}"
