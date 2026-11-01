#!/usr/bin/env bash
# Usage: snapshot_repo.sh [repo_path] [subdir] [out_file]
#   PATCH_N=3   commits to scan for modification diffs
#   STAT_N=     limit history in the stat log (empty = full history)
set -euo pipefail

REPO=${1:-}
DIR=${2:-.}
OUT=${3:-../$(basename "$REPO")-context.md}
[[ $OUT == /* ]] || OUT="$PWD/$OUT"
PATCH_N=${PATCH_N:-3}
STAT_N=${STAT_N:-}

cd "$REPO"
cd "$(git rev-parse --show-toplevel)"

# glob magic: **/ matches zero or more dirs, so root-level files are excluded too
BASE_EXCLUDES=(
  ':(exclude,glob)**/*.lock'
  ':(exclude,glob)**/package-lock.json'
  ':(exclude,glob)**/*.ipynb'
  ':(exclude,glob)**/*.Dockerfile'
  ':(exclude,glob)**/*.dockerignore'
  ':(exclude,glob)**/*.github'
  #':(exclude,glob)**/test_*'
)
# Worktree listing: broad .env* exclude (catches untracked secrets); templates re-added in list_files.
PATHS=("$DIR" "${BASE_EXCLUDES[@]}" ':(exclude,glob)**/.env*')

G=(git -c core.quotepath=off -c color.ui=never)

# Broad .env* exclude stays (fail-safe for secrets); templates re-added here.
ENV_TEMPLATE_RE='(^|/)\.env\.(example|sample|template|dist)$'

list_files() {
  {
    "${G[@]}" ls-files -z --cached --others --exclude-standard -- "${PATHS[@]}"
    "${G[@]}" ls-files -z --cached --others --exclude-standard -- "$DIR" |
      { grep -zE "$ENV_TEMPLATE_RE" || true; }
  } | sort -zu
}

# fence one backtick longer than the longest run inside the content (min 3)
fence_for() {
  local n
  n=$(grep -o '`\+' "$1" 2>/dev/null | awk '{ if (length > m) m = length } END { print m + 0 }')
  (( n < 3 )) && n=2
  printf '%*s' $((n + 1)) '' | tr ' ' '`'
}

has_head=0
"${G[@]}" rev-parse -q --verify HEAD >/dev/null && has_head=1

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  ref=$("${G[@]}" branch --show-current)
  [[ -z $ref ]] && ref="(detached)"
  rev=$( (( has_head )) && "${G[@]}" describe --always --dirty || echo "(no commits)")
  printf '# %s/%s snapshot — %s @ %s\n' "$(basename "$PWD")" "$DIR" "$ref" "$rev"
  printf '\n_Excluded everywhere: *.lock, package-lock.json, *.ipynb, Docker/GitHub files, .env* (templates kept)._\n'

  if (( has_head )); then
    # History: exclude committed non-template env files by exact name, so templates survive.
    # (while-read, not mapfile: macOS ships bash 3.2)
    HIST_PATHS=("$DIR" "${BASE_EXCLUDES[@]}")
    while IFS= read -r p; do
      HIST_PATHS+=(":(exclude,literal)$p")
    done < <("${G[@]}" log --all --format= --name-only -- "$DIR" |
             grep -E '(^|/)\.env' | grep -vE "$ENV_TEMPLATE_RE" | sort -u || true)

    # --- history map ---
    "${G[@]}" log --oneline --stat=1000 --stat-graph-width=20 \
      ${STAT_N:+-n "$STAT_N"} -- "${HIST_PATHS[@]}" > "$tmp"
    f=$(fence_for "$tmp")
    printf '\n## History (`git log --oneline --stat`)\n%s\n' "$f"
    cat "$tmp"
    printf '%s\n' "$f"

    # --- diffs of modified/renamed files in the last PATCH_N commits ---
    printf '\n## Modifications in last %s commits (added/deleted files omitted; see History)\n' "$PATCH_N"
    shown=0
    while IFS= read -r c; do
      # exit 0 = no M/R changes (also true for merges and root commit) -> skip
      "${G[@]}" diff-tree --quiet -r -M --diff-filter=MR "$c" -- "${HIST_PATHS[@]}" >/dev/null && continue
      "${G[@]}" show -M --diff-filter=MR --no-ext-diff --format='%h %s' "$c" -- "${HIST_PATHS[@]}" > "$tmp"
      f=$(fence_for "$tmp")
      printf '\n%sdiff\n' "$f"
      cat "$tmp"
      printf '%s\n' "$f"
      shown=1
    done < <("${G[@]}" rev-list -n "$PATCH_N" HEAD -- "${HIST_PATHS[@]}")
    (( shown )) || printf '\n_None._\n'
  fi

  # --- file tree ---
  list_files | tr '\0' '\n' > "$tmp"
  printf '\n## File tree\n```\n'
  cat "$tmp"
  printf '```\n'

  # --- file contents ---
  list_files |
  while IFS= read -r -d '' f; do
    [[ -f $f && ! -L $f ]] || continue          # deleted-in-worktree, symlinks, submodules
    grep -Iq . "$f" || continue                  # binary or empty
    base=${f##*/}; ext=${base##*.}
    [[ $ext == "$base" ]] && ext=""
    fc=$(fence_for "$f")
    printf '\n## `%s`\n%s%s\n' "$f" "$fc" "$ext"
    cat "$f"
    [[ -n $(tail -c1 "$f") ]] && printf '\n'     # newline only if file lacks one
    printf '%s\n' "$fc"
  done
} > "$OUT"

echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
