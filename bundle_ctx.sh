#!/usr/bin/env bash
# Usage: bundle_ctx.sh [-o out.txt] [-x glob]... path [path...]
#   Bundles text files (and text files under dirs) into one LLM-ready file.
#   Dirs inside a git repo respect .gitignore; elsewhere common junk dirs are pruned.
#   -o file  output (default: context.txt)
#   -x glob  extra exclude for dir contents, matched on relative path and basename (repeatable)
#   MAX_KB=512  skip files larger than this
# Explicit file args bypass excludes; binary/empty/oversize checks always apply.
set -euo pipefail

OUT=context.txt
MAX_KB=${MAX_KB:-512}
EXCLUDES=('*.lock' 'package-lock.json' '.env*' '*.ipynb' '*.min.js' '*.map' '*.pyc')
SKIP_DIRS=(.git node_modules __pycache__ .venv venv .mypy_cache .pytest_cache .ruff_cache dist build .idea .vscode)

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }
while getopts 'o:x:h' opt; do
  case $opt in
    o) OUT=$OPTARG ;;
    x) EXCLUDES+=("$OPTARG") ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
(( $# )) || { usage >&2; exit 2; }

# fence one backtick longer than the longest run inside the content (min 3)
fence_for() {
  local n
  n=$(grep -o '`\+' -- "$1" 2>/dev/null | awk '{ if (length > m) m = length } END { print m + 0 }' || true)
  (( n < 3 )) && n=2
  printf '%*s' $((n + 1)) '' | tr ' ' '`'
}

# $1 = path relative to the dir arg
excluded() {
  local f=$1 base=${1##*/} dirpart="" p d
  [[ $f == */* ]] && dirpart=${f%/*}
  for d in "${SKIP_DIRS[@]}"; do [[ /$dirpart/ == */"$d"/* ]] && return 0; done
  for p in "${EXCLUDES[@]}"; do
    # shellcheck disable=SC2053  # intentional glob match
    [[ $f == $p || $base == $p ]] && return 0
  done
  return 1
}

# NUL-separated paths relative to $1, sorted
list_dir() {
  local d=$1 expr=() s
  if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$d" -c core.quotepath=off ls-files -z --cached --others --exclude-standard -- .
  else
    for s in "${SKIP_DIRS[@]}"; do expr+=(-name "$s" -o); done
    unset 'expr[${#expr[@]}-1]'
    find "$d" -mindepth 1 -type d \( "${expr[@]}" \) -prune -o -type f -print0 |
      while IFS= read -r -d '' f; do printf '%s\0' "${f#"$d"/}"; done
  fi | sort -zu
}

seen=$'\n'   # newline-delimited set; bash 3.2 (stock macOS) has no assoc arrays
files=()
add() {
  local f=${1#./}
  while [[ $f == *//* ]]; do f=${f//\/\//\/}; done
  [[ -e $OUT && $f -ef $OUT ]] && return 0      # never bundle the output into itself
  case $seen in *$'\n'"$f"$'\n'*) return 0 ;; esac
  seen+="$f"$'\n'
  files+=("$f")
}

for arg in "$@"; do
  if [[ -d $arg ]]; then
    d=${arg%/}; [[ -z $d ]] && d=/
    while IFS= read -r -d '' rel; do
      [[ -L $d/$rel ]] && continue               # avoid symlink loops inside dirs
      excluded "$rel" || add "$d/$rel"
    done < <(list_dir "$d")
  elif [[ -e $arg ]]; then
    add "$arg"
  else
    echo "warn: no such path: $arg" >&2
  fi
done

kept=() skipped=()
(( ${#files[@]} )) || { echo "error: nothing to bundle" >&2; exit 1; }
for f in "${files[@]}"; do
  if [[ ! -f $f ]]; then reason="not a regular file"
  elif (( $(wc -c < "$f") > MAX_KB * 1024 )); then reason="larger than ${MAX_KB}KB"
  elif [[ ! -s $f ]]; then reason="empty"
  elif ! grep -Iq . -- "$f"; then reason="binary"
  else kept+=("$f"); continue
  fi
  skipped+=("$f — $reason")
done

(( ${#kept[@]} )) || { echo "error: no text files to bundle" >&2; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  printf '# Context bundle — %d files — %s\n' "${#kept[@]}" "$(date '+%Y-%m-%d %H:%M')"

  printf '\n## File tree\n```\n'
  printf '%s\n' "${kept[@]}"
  printf '```\n'

  for f in "${kept[@]}"; do
    base=${f##*/}; ext=${base##*.}
    [[ $ext == "$base" ]] && ext=""
    fc=$(fence_for "$f")
    printf '\n## `%s`\n%s%s\n' "$f" "$fc" "$ext"
    cat -- "$f"
    [[ -n $(tail -c1 -- "$f") ]] && printf '\n'  # newline only if file lacks one
    printf '%s\n' "$fc"
  done

  if (( ${#skipped[@]} )); then
    printf '\n## Skipped\n'
    printf -- '- %s\n' "${skipped[@]}"
  fi
} > "$tmp"

mv "$tmp" "$OUT"
trap - EXIT
bytes=$(wc -c < "$OUT")
echo "wrote $OUT (${#kept[@]} files, ${#skipped[@]} skipped, $bytes bytes, ~$((bytes / 4)) tokens)"
