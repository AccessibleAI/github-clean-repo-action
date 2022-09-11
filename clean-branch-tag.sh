#!/bin/bash

set -eo pipefail

[[ -n ${INPUT_REPO_TOKEN} ]] || { echo "Please set the REPO_TOKEN input"; exit 1; }
git config --global --add safe.directory /github/workspace
BASE_URI="https://api.github.com"
REPO="${INPUT_REPO}"
BRANCH_DATE=${INPUT_BRANCH_DATE:-"12 months ago"}
TAG_DATE=${INPUT_TAG_DATE:-"31556952"} #year in seconds
GITHUB_TOKEN=${INPUT_REPO_TOKEN}
DRY_RUN=${INPUT_DRY_RUN:-true}
EXCLUDE_BRANCH_REGEX=${INPUT_EXTRA_PROTECTED_BRANCH_REGEX:-^(master|main|daily|saas)$}
echo "Dry Run: ${DRY_RUN}"
tag_counter=0
branch_counter=0
current_time=$(date +%s)

branch_protected() {
    local br=${1}

    protected=$(curl -X GET -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        "${BASE_URI}/repos/${REPO}/branches/${br}" | jq -r .protected)

    # If we got null then something else happened (like no access error etc) so
    # we can't determine the status for the branch
    case ${protected} in
        null) echo "Unable to determine status for branch: ${br}"; return 0 ;;
        true) return 0 ;;
        *) return 1 ;;
    esac
}

extra_branch_protected() {
    local br=${1}

    echo "${br}" | grep -qE "${EXCLUDE_BRANCH_REGEX}"

    return $?
}

delete_branch_or_tag() {
    local br=${1} ref="${2}" log=${3:-''}
    if [[ "${ref}" == "tags" ]]; then
        tag_counter=$((tag_counter+1))
    elif [[ "${ref}" == "heads" ]]; then
        branch_counter=$((branch_counter+1))
    fi

    if [[ "${DRY_RUN}" == false ]]; then
        status=$(curl -X DELETE  -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
               -w "%{http_code}"  "${BASE_URI}/repos/${REPO}/git/refs/${ref}/${br}")

        case ${status} in
            204) echo "Deleting ${ref}: ${br} - Reason: ${log} - http_status=${status} ";;
            *)  echo "Deletion of ${ref} ${br} failed with http_status=${status}"
                echo "===== Dumping curl url ===== : ${BASE_URI}/repos/${REPO}/git/refs/${ref}/${br}"
                ;;
        esac
    else
        echo "Deleting ${ref}: ${br}  - Reason: ${log}"
    fi
}
main() {
    # fetch history etc
    git fetch --prune --prune-tags --tags
    git branch -r --merged $(git symbolic-ref HEAD | sed "s@^.*heads/@@") | grep -Ev "(^\*|master|main|daily)" | cut -d/ -f2- > merged_to_master_file || true

    for br in $(git ls-remote -q --heads --refs | sed "s@^.*heads/@@"); do
        branch_protected "${br}" && echo "branch: ${br} is likely protected. Won't delete it" && continue
        extra_branch_protected "${br}" && echo "branch: ${br} is explicitly protected and won't be deleted" && continue
        deleted=false
        # local tag_counter=1
        # local branch_counter=1

        #if merged to master delete branch
        if grep -qx "${br}" merged_to_master_file && [[ -z "$(git log --oneline -1 --since="2 weeks ago" origin/"${br}")" ]]; then
            delete_branch_or_tag "${br}" "heads" "${br} has been merged to master"
            deleted=true
        fi
        #delete branches older then DATE - default 6 months
        if [[ -z "$(git log --oneline -1 --since="${BRANCH_DATE}" origin/"${br}")" && "${deleted}" == "false" ]]; then
            delete_branch_or_tag "${br}" "heads" "${br} older then ${BRANCH_DATE}"
        fi

    done
    #delete tags of deleted branches
    echo "Checking tags"
    git fetch --prune --prune-tags --tags
    for tag in $(git for-each-ref  --format='%(refname:lstrip=2)' refs/tags | grep -vE "^v?[0-9]+\.[0-9]+\.[0-9]+$" | grep -oE "\-.*\-" | sed 's/.$//' |  sed 's/^.//' | uniq); do
        local delete="true"
        branches=$(git ls-remote -q --heads --refs | sed "s@^.*heads/@@")
        if $(echo "${branches}" | grep -qx "${tag}") ;  then
            delete="false"
        fi
        echo "Delete tags that belong to ${tag}"
        if ${delete}; then
            tags=$(git for-each-ref  --format='%(refname:lstrip=2)' refs/tags | grep -E "^v?[0-9]+\.[0-9]+\.[0-9]+(-${tag}-)+[0-9]")
            echo "tags to get deleted: ${tags}"
            for i in ${tags};do
                delete_branch_or_tag "${i}" "tags" "Branch has been deleted. orphaned tag"
            done
        fi
    done
    git fetch --prune --prune-tags --tags
    #delete tags older then DATE - default 12 months
    d1year=$((${current_time} - ${TAG_DATE}))
    tags=$(git for-each-ref --format="%(refname:lstrip=2) %(creatordate:unix)" refs/tags | awk '{ if ($2 < '"$d1year"') print $1 }')
    for i in ${tags};do
        delete_branch_or_tag "${i}" "tags" "Tag is older then ${TAG_DATE}"
    done
    printf "tags deleted: %s \nbranches delete: %s" "${tag_counter}" "${branch_counter}"
}

main "$@"