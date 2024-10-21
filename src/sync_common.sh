#!/usr/bin/env bash

set -e
# set -u
# set -x

#######################################
# write a message to STDERR.
# Arguments:
#   message to print.
#######################################
function err() {
  echo "::error::[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2;
}

#######################################
# write a debug message.
# Arguments:
#   message to print.
#######################################
function debug() {
  echo "::debug::$*";
}

#######################################
# write a warn message.
# Arguments:
#   message to print.
#######################################
function warn() {
  echo "::warn::$*";
}

#######################################
# write a info message.
# Arguments:
#   message to print.
#######################################
function info() {
  echo "::info::$*";
}

#######################################
# Executes commands defined within yml file or env variable
# Arguments:
#   hook -> the hook to use
#
####################################3#
function cmd_from_yml() {
  local FILE_NAME="templatesync.yml"
  local HOOK=$1
  local YML_PATH_SUFF=".${HOOK}.commands"

  if [ "$IS_ALLOW_HOOKS" != "true" ]; then
    debug "execute cmd hooks not enabled"
  else
    info "execute cmd hooks enabled"

    if ! [ -x "$(command -v yq)" ]; then
      err "yaml query yq is not installed. 'https://mikefarah.gitbook.io/yq/'";
      exit 1;
    fi

    if [[ -n "${HOOKS}" ]]; then
      debug "hooks input variable is set. Using the variable"
      echo "${HOOKS}" > "tmp.${FILE_NAME}"
      YML_PATH="${YML_PATH_SUFF}"
    else
      cp ${FILE_NAME} "tmp.${FILE_NAME}"
      YML_PATH=".hooks${YML_PATH_SUFF}"
    fi

    readarray cmd_Arr < <(yq "${YML_PATH} | .[]"  "tmp.${FILE_NAME}")

    rm "tmp.${FILE_NAME}"

    for key in "${cmd_Arr[@]}"; do echo "${key}" | bash; done
  fi
}

function get_repo_vendor() {
  local giturl=$1
  if [[ "$giturl" =~ ^http* ]]; then
    header=$(curl --silent --head "${giturl}")
    if [[ "$header" =~ github ]]; then
      echo "github"
    elif [[ "$header" =~ gitea ]]; then
      echo "gitea"
    elif [[ "$header" =~ gitlab ]]; then
      echo "gitlab"
    else
      echo "unknown"
    fi
  else
    if [[ "$giturl" =~ github ]]; then
      echo "github"
    elif [[ "$giturl" =~ gitea ]]; then
      echo "gitea"
    elif [[ "$giturl" =~ gitlab ]]; then
      echo "gitlab"
    else
      echo "unknown"
    fi
  fi
}

function get_repo_user() {
  local giturl=$1
  if [[ "$giturl" =~ ^http* ]]; then
    echo "${giturl}" | cut -d "/" -f 4
  else
    echo "${giturl}" | cut -d ":" -f 2 | cut -d "/" -f 1
  fi
}
