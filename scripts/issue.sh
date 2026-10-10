#!/usr/bin/env bash
# Keep one open `upstream-sync` issue per problem, keyed by its title.
#
#   issue.sh open  "<title>" <body-file>   open it, or comment on the open one
#   issue.sh close "<title>" "<comment>"   close it if it is open
set -euo pipefail
repo="${GITHUB_REPOSITORY:-agent-harbor/nixpkgs}"
label=upstream-sync
action=$1 title=$2

find_issue() {
  gh issue list -R "$repo" --label "$label" --state open --limit 100 \
    --json number,title --jq ".[] | select(.title == \"$title\") | .number" | head -n1
}

num=$(find_issue)
case "$action" in
  open)
    if [[ -n "$num" ]]; then
      gh issue comment "$num" -R "$repo" --body-file "$3"
    else
      gh issue create -R "$repo" --title "$title" --label "$label" --body-file "$3"
    fi
    ;;
  close)
    if [[ -n "$num" ]]; then
      gh issue close "$num" -R "$repo" --comment "$3"
    fi
    ;;
  *) echo "usage: $0 open|close <title> ..." >&2; exit 2 ;;
esac
