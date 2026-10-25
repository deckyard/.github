#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# Create a deck repository in the Deckyard organisation, or bring an existing
# one up to the organisation's usual settings. Safe to run again: every step
# sets a value rather than adding one, so a second run changes nothing.
#
# What it sets:
#   - a public repository `deck-<name>`, with description, homepage (its Pages
#     site) and topics: jennifer-lang, jennifer-deck, deckyard + any given
#   - issues on; wiki and projects off - docs live in the book, plans in issues
#   - squash merges only, branches deleted after merge, auto-merge allowed
#   - secret scanning, push protection, private vulnerability reporting
#     (CONTRIBUTING.md sends security reports to the Security tab)
#   - GitHub Pages built by Actions (docs.yml publishes the book)
#   - the maintainers team, with `maintain` permission
#
# With --protect it also sets the rulesets, which belong after the first push:
#   - main:  no deletion, no force push, and the shared test.yml checks must
#            pass - which means changes reach main through pull requests
#   - tags:  only the maintainers team creates tags; nobody but an
#            organisation owner moves or deletes one; `v*` tags are refused,
#            because a release tag is plain `N.N.N`
#
# With --deck the name, description and keywords come from a local deck's
# manifest; the repository name is taken from its homepage URL when that points
# into the organisation (strider lives in deck-strider-frequency-converter).
#
# Usage:
#   gh-create-project.sh [options] <name> ["description"]
#   gh-create-project.sh [options] --deck <dir>
#
# Options:
#   --org ORG         organisation (default: deckyard)
#   --team SLUG       team given `maintain` (default: maintainers)
#   --topic T         an extra topic; repeatable
#   --deck DIR        read name, description and keywords from DIR's manifest
#   --protect         also set the branch and tag rulesets
#   --check NAME      a required status check for --protect; repeatable
#                     (default: the two jobs of the shared test.yml)
#   --dry-run         print what would be sent, change nothing
#
# Needs: gh (logged in as an organisation owner), python3.
set -euo pipefail

org=deckyard
team=maintainers
topics=()
checks=()
deck=""
protect=no
dry=no
name=""
description=""

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '/^# Usage:/,/^# Needs:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --org) org="${2:?}"; shift 2 ;;
        --team) team="${2:?}"; shift 2 ;;
        --topic) topics+=("${2:?}"); shift 2 ;;
        --deck) deck="${2:?}"; shift 2 ;;
        --protect) protect=yes; shift ;;
        --check) checks+=("${2:?}"); shift 2 ;;
        --dry-run) dry=yes; shift ;;
        -h|--help) usage ;;
        -*) die "unknown option $1" ;;
        *)
            if [[ -z "$name" ]]; then name="$1"
            elif [[ -z "$description" ]]; then description="$1"
            else die "unexpected argument $1"; fi
            shift ;;
    esac
done
(( ${#checks[@]} )) || checks=("fmt, lint, guards, tests, examples" "jennifer-tiny")

command -v gh >/dev/null || die "gh is not installed"
command -v python3 >/dev/null || die "python3 is not installed"

# --- what to create ---------------------------------------------------------

# Prints repo, description and keywords (one per line after the first two)
# from a deck manifest, whichever of the four formats it uses.
manifest_facts() {
    python3 - "$1" "$org" <<'PY'
import json, os, re, sys

root, org = sys.argv[1], sys.argv[2]
for ext in ("toml", "yaml", "yml", "json"):
    path = os.path.join(root, "deck." + ext)
    if os.path.isfile(path):
        break
else:
    sys.exit(f"no deck.toml / .yaml / .yml / .json in {root}")
text = open(path, encoding="utf-8").read()
if ext == "toml":
    import tomllib
    doc = tomllib.loads(text)
elif ext == "json":
    doc = json.loads(text)
else:
    try:
        import yaml
        doc = yaml.safe_load(text)
    except ImportError:
        def scalar(key):
            m = re.search(r'^\s*%s:\s*"?(.*?)"?\s*$' % key, text, re.M)
            return m.group(1) if m else ""
        m = re.search(r'^\s*keywords:\s*(\[.*?\])', text, re.M | re.S)
        doc = {"name": scalar("name"), "description": scalar("description"),
               "homepage": scalar("homepage"),
               "keywords": json.loads(m.group(1)) if m else []}
pkg = doc.get("package", doc)
urls = pkg.get("urls", {}) or {}
homepage = urls.get("homepage") or pkg.get("homepage") or pkg.get("repository") or ""
m = re.match(r"https://github\.com/%s/([\w.-]+?)(?:\.git)?/?$" % re.escape(org), homepage)
repo = m.group(1) if m else "deck-" + str(pkg.get("name", "")).split("/")[-1]
print(repo)
print(str(pkg.get("description", "")).rstrip("."))
for k in pkg.get("keywords", []) or []:
    print(k)
PY
}

keywords=()
if [[ -n "$deck" ]]; then
    [[ -d "$deck" ]] || die "$deck is not a directory"
    mapfile -t facts < <(manifest_facts "$deck")
    (( ${#facts[@]} >= 2 )) || die "could not read the manifest in $deck"
    [[ -n "$name" ]] || name="${facts[0]}"
    [[ -n "$description" ]] || description="${facts[1]}"
    keywords=("${facts[@]:2}")
fi
[[ -n "$name" ]] || usage
repo="deck-${name#deck-}"
[[ "$repo" =~ ^deck-[a-z0-9][a-z0-9-]*$ ]] || die "$repo is not a valid deck repository name"
full="$org/$repo"
homepage="https://$org.github.io/$repo/"

# Topics: the organisation's three, then the extras, lower-cased and
# hyphenated as GitHub requires, without duplicates, at most twenty.
mapfile -t topic_list < <(python3 - jennifer-lang jennifer-deck deckyard \
    "${topics[@]+"${topics[@]}"}" "${keywords[@]+"${keywords[@]}"}" <<'PY'
import re, sys
seen = []
for t in sys.argv[1:]:
    t = re.sub(r"[^a-z0-9-]", "-", t.lower()).strip("-")[:50]
    if t and t not in ("jennifer", "deck") and t not in seen and len(seen) < 20:
        seen.append(t)
print("\n".join(seen))
PY
)

# --- talking to GitHub -------------------------------------------------------

# api METHOD PATH [JSON] - a write, skipped (and printed) under --dry-run.
api() {
    local method="$1" path="$2" body="${3-}"
    if [[ "$dry" == yes ]]; then
        echo "  would $method $path${body:+ $body}"
        return 0
    fi
    if [[ -n "$body" ]]; then
        gh api -X "$method" "$path" --input - <<<"$body" >/dev/null
    else
        gh api -X "$method" "$path" >/dev/null
    fi
}

json() { python3 -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1])))' "$1"; }
quote() { python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"; }

gh auth status >/dev/null 2>&1 || die "gh is not logged in - run: gh auth login"
team_id="$(gh api "orgs/$org/teams/$team" --jq .id 2>/dev/null)" \
    || die "team $org/$team not found - create it first"

echo "== $full"

if gh api "repos/$full" >/dev/null 2>&1; then
    echo "  exists - applying the settings"
else
    echo "  creating"
    api POST "orgs/$org/repos" "$(json "{
        \"name\": $(quote "$repo"),
        \"description\": $(quote "$description"),
        \"homepage\": $(quote "$homepage"),
        \"visibility\": \"public\",
        \"has_issues\": true,
        \"auto_init\": false
    }")"
fi

echo "  settings: squash only, delete merged branches, auto-merge, no wiki/projects"
api PATCH "repos/$full" "$(json "{
    \"description\": $(quote "$description"),
    \"homepage\": $(quote "$homepage"),
    \"has_issues\": true,
    \"has_wiki\": false,
    \"has_projects\": false,
    \"allow_squash_merge\": true,
    \"allow_merge_commit\": false,
    \"allow_rebase_merge\": false,
    \"squash_merge_commit_title\": \"PR_TITLE\",
    \"squash_merge_commit_message\": \"PR_BODY\",
    \"delete_branch_on_merge\": true,
    \"allow_auto_merge\": true,
    \"security_and_analysis\": {
        \"secret_scanning\": {\"status\": \"enabled\"},
        \"secret_scanning_push_protection\": {\"status\": \"enabled\"}
    }
}")"

echo "  private vulnerability reporting"
api PUT "repos/$full/private-vulnerability-reporting"

echo "  topics: ${topic_list[*]}"
api PUT "repos/$full/topics" "$(python3 -c 'import json, sys; print(json.dumps({"names": sys.argv[1:]}))' "${topic_list[@]}")"

echo "  pages: built by GitHub Actions"
if gh api "repos/$full/pages" >/dev/null 2>&1; then
    api PUT "repos/$full/pages" '{"build_type": "workflow"}'
else
    api POST "repos/$full/pages" '{"build_type": "workflow"}'
fi

echo "  team $team: maintain"
api PUT "orgs/$org/teams/$team/repos/$full" '{"permission": "maintain"}'

# --- rulesets ------------------------------------------------------------------

# ruleset NAME JSON - create it, or replace the one already carrying that name.
ruleset() {
    local rs_name="$1" body="$2" id=""
    if gh api "repos/$full" >/dev/null 2>&1; then
        id="$(gh api "repos/$full/rulesets" --jq ".[] | select(.name == \"$rs_name\") | .id")"
    fi
    if [[ -n "$id" ]]; then
        api PUT "repos/$full/rulesets/$id" "$body"
    else
        api POST "repos/$full/rulesets" "$body"
    fi
}

if [[ "$protect" == yes ]]; then
    # 15368 is the GitHub Actions app: a check of the same name posted by
    # anything else does not count.
    contexts="$(python3 -c 'import json, sys
print(json.dumps([{"context": c, "integration_id": 15368} for c in sys.argv[1:]]))' "${checks[@]}")"
    owners='{"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "always"}'
    maintainers="{\"actor_id\": $team_id, \"actor_type\": \"Team\", \"bypass_mode\": \"always\"}"

    echo "  ruleset main: no deletion or force push; required: ${checks[*]}"
    ruleset main "$(json "{
        \"name\": \"main\", \"target\": \"branch\", \"enforcement\": \"active\",
        \"conditions\": {\"ref_name\": {\"include\": [\"~DEFAULT_BRANCH\"], \"exclude\": []}},
        \"bypass_actors\": [$owners],
        \"rules\": [
            {\"type\": \"deletion\"},
            {\"type\": \"non_fast_forward\"},
            {\"type\": \"required_status_checks\", \"parameters\": {
                \"strict_required_status_checks_policy\": false,
                \"do_not_enforce_on_create\": true,
                \"required_status_checks\": $contexts}}
        ]
    }")"

    echo "  ruleset release-tags: only the $team team creates tags"
    ruleset release-tags "$(json "{
        \"name\": \"release-tags\", \"target\": \"tag\", \"enforcement\": \"active\",
        \"conditions\": {\"ref_name\": {\"include\": [\"refs/tags/*\"], \"exclude\": []}},
        \"bypass_actors\": [$owners, $maintainers],
        \"rules\": [{\"type\": \"creation\"}]
    }")"

    echo "  ruleset tags-immutable: a pushed tag is never moved or deleted"
    ruleset tags-immutable "$(json "{
        \"name\": \"tags-immutable\", \"target\": \"tag\", \"enforcement\": \"active\",
        \"conditions\": {\"ref_name\": {\"include\": [\"refs/tags/*\"], \"exclude\": []}},
        \"bypass_actors\": [$owners],
        \"rules\": [{\"type\": \"update\"}, {\"type\": \"deletion\"}]
    }")"

    echo "  ruleset no-v-tags: release tags are N.N.N, never vN.N.N"
    ruleset no-v-tags "$(json "{
        \"name\": \"no-v-tags\", \"target\": \"tag\", \"enforcement\": \"active\",
        \"conditions\": {\"ref_name\": {\"include\": [\"refs/tags/v*\"], \"exclude\": []}},
        \"bypass_actors\": [],
        \"rules\": [{\"type\": \"creation\"}]
    }")"
fi

[[ "$dry" == yes ]] && echo "dry run - nothing was changed"
echo "  https://github.com/$full  ->  $homepage"
