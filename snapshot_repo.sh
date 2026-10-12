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
PATHS=(
  "$DIR"
  ':(exclude,glob)**/*.lock'
  ':(exclude,glob)**/package-lock.json'
  ':(exclude,glob)**/.env*'
  ':(exclude,glob)**/*.ipynb'
  ':(exclude,glob)**/test_*'
)

G=(git -c core.quotepath=off -c color.ui=never)

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

  if (( has_head )); then
    # --- history map ---
    "${G[@]}" log --oneline --stat=1000 --stat-graph-width=20 \
      ${STAT_N:+-n "$STAT_N"} -- "${PATHS[@]}" > "$tmp"
    f=$(fence_for "$tmp")
    printf '\n## History (`git log --oneline --stat`)\n%s\n' "$f"
    cat "$tmp"
    printf '%s\n' "$f"

    # --- diffs of modified/renamed files in the last PATCH_N commits ---
    printf '\n## Modifications in last %s commits (added/deleted files omitted; see History)\n' "$PATCH_N"
    shown=0
    while IFS= read -r c; do
      # exit 0 = no M/R changes (also true for merges and root commit) -> skip
      "${G[@]}" diff-tree --quiet -r -M --diff-filter=MR "$c" -- "${PATHS[@]}" >/dev/null && continue
      "${G[@]}" show -M --diff-filter=MR --no-ext-diff --format='%h %s' "$c" -- "${PATHS[@]}" > "$tmp"
      f=$(fence_for "$tmp")
      printf '\n%sdiff\n' "$f"
      cat "$tmp"
      printf '%s\n' "$f"
      shown=1
    done < <("${G[@]}" rev-list -n "$PATCH_N" HEAD -- "${PATHS[@]}")
    (( shown )) || printf '\n_None._\n'
  fi

  # --- file tree ---
  "${G[@]}" ls-files --cached --others --exclude-standard -- "${PATHS[@]}" | sort -u > "$tmp"
  printf '\n## File tree\n```\n'
  cat "$tmp"
  printf '```\n'

  # --- file contents ---
  "${G[@]}" ls-files -z --cached --others --exclude-standard -- "${PATHS[@]}" |
  sort -zu |
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
