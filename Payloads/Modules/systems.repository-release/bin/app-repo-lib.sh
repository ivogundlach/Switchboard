#!/usr/bin/env bash
# app-repo-lib.sh — shared definitions for app-repo-bootstrap and app-repo-sync.
#
# One private GitHub repo per app, with real per-change history. The
# configured daily-snapshot archive keeps running underneath as an
# independent backstop; the two never touch (its snapshot script excludes
# .git/, so per-app history is invisible to it).

HOME_DIR="${HOME:-$(cd && pwd -P)}"
PROJECTS="${APP_REPO_PROJECTS:-${HOME_DIR}/Projects}"
STATE="${APP_REPO_STATE:-$HOME/.local/state/app-repo-sync}"
GH_OWNER="${APP_REPO_OWNER:-}"
ARCHIVE_REMOTE="${APP_REPO_ARCHIVE_REMOTE:-}"

ensure_repo_identity() {
  local baseline_remote=""
  if [ -z "$GH_OWNER" ] && command -v gh >/dev/null 2>&1; then
    GH_OWNER="$(gh api user --jq .login 2>/dev/null || true)"
  fi
  [ -n "$GH_OWNER" ] || { echo "GitHub owner is unavailable; set APP_REPO_OWNER." >&2; return 1; }
  if [ -z "$ARCHIVE_REMOTE" ] && [ -f "$HOME/.local/state/personal-repo-sync/baseline.tsv" ] &&
     [ ! -L "$HOME/.local/state/personal-repo-sync/baseline.tsv" ]; then
    baseline_remote="$(awk -F '\t' '$1 == "remote" { value=$2 } END { print value }' \
      "$HOME/.local/state/personal-repo-sync/baseline.tsv")"
    if [[ "$baseline_remote" =~ ^https://github\.com/${GH_OWNER}/[^/]+\.git$ ]]; then
      ARCHIVE_REMOTE="$baseline_remote"
    fi
  fi
  ARCHIVE_REMOTE="${ARCHIVE_REMOTE:-https://github.com/${GH_OWNER}/private-source-archive.git}"
}

# Every configured app with local work is backed up to a private repository.
#
# AmethystFork and knockoff are forks of upstream projects, previously excluded
# on that basis. knockoff's ~3.7k lines of local work had no backup at all;
# AmethystFork had only a patch export in the archive's third-party-local/,
# which needs upstream present to reconstruct and is not browsable history. Both
# are in as of 2026-08-07 — a private mirror of a fork is a backup, not a
# republication. Their upstream remote is named "upstream"; origin points at his
# own private repo. Both were shallow clones and had to be unshallowed before
# the first push would succeed.
#
# CLI-Anything is a third-party tool rather than something he built, but it
# carries real local work — an XDG state/cache module wired through four of its
# modules — that lived nowhere else, so it is mirrored on the same terms.
#
# Still excluded: claude-video, which has no local changes at all. CodexBar was
# deleted 2026-08-07 along with its one local patch — an unfinished, untested
# change the maintainer abandoned in favour of waiting for an upstream release. Only the
# installed /Applications/CodexBar.app remains; do not resurrect the fork.
#
# AutoInstallDMG joined 2026-08-09. It had no source project at all until then --
# the droplet was edited in Script Editor and saved straight over the installed
# app -- so ~/Projects/AutoInstallDMG holds the only copy of that AppleScript and
# its installer worker.
#
# Additional locally maintained apps can be added to this list as needed.
APPS=(
  AmethystFork AutoInstallDMG CanIAffordThis CLI-Anything CopyPathFinder
  ElectionSimulator ForceCopyPaste Kinetics knockoff MacroSimulator Market
  NewTabLinks NutrientTracker ReleaseRadar School SchoolDashboard Switchboard
  ToolStatusDashboard UsageQueue Vitals WarmCorners YouTubeFirstContentTab
  YouTubeHomeReload mac-apps t3code
)

# Commit grouping. Each app-relative path is matched top to bottom; the first
# hit names the commit's scope, so one night's work lands as several focused
# commits rather than one blob. Order matters — most specific first.
#
# Format: <glob>|<scope>
SCOPES=(
  "Sources/*|sources"
  "Source/*|sources"
  "*.swift|sources"
  "scripts/*|build"
  "build.sh|build"
  "Info.plist|build"
  "*.entitlements|build"
  "Resources/*|resources"
  "Assets.xcassets/*|resources"
  "*.icns|resources"
  "*.png|resources"
  "README.md|docs"
  "docs/*|docs"
  "*.md|docs"
  ".gitignore|chore"
)

scope_for_path() {
  local path="$1" entry glob scope
  for entry in "${SCOPES[@]}"; do
    glob="${entry%%|*}"
    scope="${entry##*|}"
    # shellcheck disable=SC2254
    case "$path" in
      $glob) printf '%s\n' "$scope"; return 0 ;;
    esac
  done
  printf 'misc\n'
}

log() {
  printf '%s %s: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "${NAME:-app-repo}" "$*" >>"${LOG:-/dev/stderr}"
}

# Refuse to stage anything that looks like a credential or private key. Mirrors
# personal-repo-sync's check so both paths fail closed the same way.
check_sensitive_paths() {
  local repo="$1" path
  while IFS= read -r -d '' path; do
    case "$path" in
      *.env.example|*.env.*.example) ;;
      *.env|*/.env|*/.env.*|*.pem|*.key|*.p12|*.mobileprovision|.memory/*|*/.memory/*)
        log "BLOCKED: sensitive path staged: $path"
        return 1
        ;;
    esac
  done < <(git -C "$repo" diff --cached --name-only -z)
  return 0
}

# Deletion circuit breaker: a bug that wipes a source tree must not be committed
# and pushed unattended.
MAX_DELETIONS=25
MAX_DELETION_PERCENT=20

deletions_sane() {
  local repo="$1" deleted tracked percent=0
  deleted="$(git -C "$repo" diff --cached --name-status | awk '$1 ~ /^D/ {n++} END {print n+0}')"
  tracked="$(git -C "$repo" ls-tree -r --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')"
  [ -z "$tracked" ] && tracked=0
  if [ "$tracked" -gt 0 ]; then percent=$((deleted * 100 / tracked)); fi
  if [ "$deleted" -gt "$MAX_DELETIONS" ] || [ "$percent" -gt "$MAX_DELETION_PERCENT" ]; then
    log "BLOCKED: deletion circuit breaker in $repo — $deleted deletion(s), ${percent}%"
    return 1
  fi
  return 0
}

gitleaks_clean() {
  local repo="$1"
  command -v gitleaks >/dev/null 2>&1 || { log "BLOCKED: gitleaks not installed"; return 1; }
  gitleaks git --staged --redact --no-banner "$repo" >>"${LOG:-/dev/null}" 2>&1
}

# Runtime state that lives inside a project tree but is not source. Some of it
# carries live credentials — browser profiles hold cookies and Chrome's
# encrypted-key blobs, and Playwright storage_state.json is a logged-in session —
# which is why these are excluded by name rather than left to the secret scanner
# to catch commit by commit.
app_extra_ignores() {
  case "$1" in
    Market)
      # state/ is 1.5 GB of databases, snapshots, signing material and a browser
      # profile; out/ and inbox/ are pipeline artefacts.
      printf '%s\n' 'state/' 'out/' 'inbox/'
      ;;
    School)
      # sync/ holds real source (school_sync.py, uahsync/, tests/) alongside
      # runtime, so exclude the runtime paths individually rather than the dir.
      printf '%s\n' 'sync/browser_profile/' 'sync/logs/' 'sync/storage_state.json' \
                    'sync/state.json' 'sync/SchoolSync.app/'
      ;;
  esac
}

write_gitignore() {
  local extra
  cat >"$1/.gitignore" <<'IGNORE'
.DS_Store
**/.DS_Store
.memory/
**/.memory/
.build/
**/.build/
build/
**/build/
build-clt/
**/dist/
**/node_modules/
**/venv/
**/.venv/
**/env/
**/site-packages/
**/__pycache__/
**/.pytest_cache/
**/.playwright-cli/
**/xcuserdata/
**/*.xcuserstate
**/*.log
**/.env
**/.env.*
!**/.env.example
!**/.env.*.example
**/*.pem
**/*.key
**/*.p12
**/*.mobileprovision

# Runtime state and credential caches
**/browser_profile/
**/*_profile/
**/storage_state.json
**/*.sqlite
**/*.sqlite-shm
**/*.sqlite-wal
**/*.db
IGNORE

  extra="$(app_extra_ignores "${2:-}")"
  if [ -n "$extra" ]; then
    printf '\n# %s runtime paths\n%s\n' "${2:-project}" "$extra" >>"$1/.gitignore"
  fi
}
