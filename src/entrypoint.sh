#!/usr/bin/env bash
set -e
# set -u
# set -x

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# shellcheck source=src/sync_common.sh
source "${SCRIPT_DIR}/sync_common.sh"

###########################################
# Precheks
##########################################

if [[ -z "${GITHUB_TOKEN}" ]]; then
    err "Missing input 'github_token: \${{ secrets.GITHUB_TOKEN }}'.";
    exit 1;
fi

if [[ -z "${SOURCE_REPO}" ]]; then
  err "Missing input 'source_repo: \${{ input.source_repo }}'.";
  exit 1
fi

if [[ -z "${HOME}" ]]; then
  err "Missing env variable HOME.";
  exit 1
fi


############################################
# Variables
############################################

SOURCE_REPO_TYPE=$(get_repo_vendor "${SOURCE_REPO}")
SOURCE_REPO_HOSTNAME=$(get_repo_hostname "${SOURCE_REPO}")
SOURCE_REPO_USER=$(get_repo_user "${SOURCE_REPO}")
SOURCE_REPO_PROTO=$(get_repo_protocol "${SOURCE_REPO}")

SOURCE_CRED_FILE="/workspace/git_source_creds.sh"
TARGET_CRED_FILE="/workspace/git_target_creds.sh"

TARGET_REPO=$(git remote get-url origin)

# Explicitly set repo type in case auto detect does not work
# Add more elseifs to extend to other vendors
if [[ "${IS_TARGET_GITEA}" == 'true' ]]; then
  TARGET_REPO_TYPE="gitea"
else
  TARGET_REPO_TYPE=$(get_repo_vendor "${TARGET_REPO}")
fi

if ! [[ "${SOURCE_REPO_TYPE}" == "github" ]]; then
  IS_NOT_SOURCE_GITHUB='true'
fi

GIT_USER_NAME="${GIT_USER_NAME:-${GITHUB_ACTOR}}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-github-action@actions-template-sync.noreply.${SOURCE_REPO_HOSTNAME}}"

################################################
# Functions
################################################

#######################################
# doing the ssh setup.
# Arguments:
#   ssh_private_key_src
#   source_repo_hostname
# Changes:
#   SOURCE_REPO_PREFIX
# Exports:
#   SRC_SSH_PRIVATEKEY_ABS_PATH
#######################################
function ssh_setup() {
  debug "::group::ssh setup"

  info "prepare ssh"

  local src_ssh_file_dir="/tmp/.ssh"
  local src_ssh_private_key_file_name="id_rsa_actions_template_sync"

  local ssh_private_key_src=$1
  local source_repo_hostname=$2

  if [[ -z "${ssh_private_key_src}" ]] &>/dev/null; then
    err "Missing variable 'ssh_private_key_src'.";
    exit 1;
  fi

  if [[ -z "${source_repo_hostname}" ]]; then
    err "Missing variable 'source_repo_hostname'.";
    exit 1;
  fi

  # exporting SRC_SSH_PRIVATEKEY_ABS_PATH to be used later
  export SRC_SSH_PRIVATEKEY_ABS_PATH="${src_ssh_file_dir}/${src_ssh_private_key_file_name}"

  debug "We are using SSH within a private source repo"
  mkdir -p "${src_ssh_file_dir}"
  # use cat <<< instead of echo to swallow output of the private key
  cat <<< "${ssh_private_key_src}" | sed 's/\\n/\n/g' > "${SRC_SSH_PRIVATEKEY_ABS_PATH}"
  chmod 600 "${SRC_SSH_PRIVATEKEY_ABS_PATH}"

  # adjusting outer variable source repo prefix
  SOURCE_REPO_PREFIX="git@${source_repo_hostname}:"

  debug "::endgroup::"
}

#######################################
# doing the gpg setup.
# Arguments:
#   gpg_private_key
#   git_user_email
#######################################
function gpg_setup() {
  debug "::group::gpg setup"
  info "start prepare gpg"

  local gpg_private_key=$1
  local git_user_email=$2

  if [[ -z "${gpg_private_key}" ]] &>/dev/null; then
    err "Missing variable 'gpg_private_key'.";
    exit 1;
  fi

  if [[ -z "${git_user_email}" ]]; then
    err "Missing variable 'git_user_email'.";
    exit 1;
  fi

  echo -e "${gpg_private_key}" | gpg --import --batch
  for fpr in $(gpg --list-key --with-colons "${git_user_email}"  | awk -F: '/fpr:/ {print $10}' | sort -u); do  echo -e "5\ny\n" |  gpg --no-tty --command-fd 0 --expert --edit-key "$fpr" trust; done

  KEY_ID="$(gpg --list-secret-key --with-colons "${git_user_email}" | awk -F: '/sec:/ {print $5}')"
  git config user.signingkey "${KEY_ID}"
  git config commit.gpgsign true
  git config gpg.program "${SCRIPT_DIR}/gpg_no_tty.sh"

  info "done prepare gpg"
  debug "::endgroup::"
}


#######################################
# doing the git credential setup for the
# source repo
#
# for destination, we use gh/tea
#######################################
function add_git_cred_helpers() {
  info "set git source cred configuration"
  echo '#!/bin/bash' > ${SOURCE_CRED_FILE}
  echo "sleep 1" >> ${SOURCE_CRED_FILE}
  echo "echo username=${SOURCE_REPO_USER}" >> ${SOURCE_CRED_FILE}
  echo "echo password=${SOURCE_REPO_TOKEN}" >> ${SOURCE_CRED_FILE}

  info "set git target cred configuration"
  echo '#!/bin/bash' > ${TARGET_CRED_FILE}
  echo "sleep 1" >> ${TARGET_CRED_FILE}
  echo "echo username=${GITHUB_USER}" >> ${TARGET_CRED_FILE}
  echo "echo password=${GITHUB_TOKEN}" >> ${TARGET_CRED_FILE}
}

function git_activate_source_repo() {
  info "set git source as active repo"
  git config --global credential.helper "/bin/bash ${SOURCE_CRED_FILE}"
}

function git_activate_target_repo() {
  info "set git target as active repo"
  git config --global credential.helper "/bin/bash ${TARGET_CRED_FILE}"
}

#######################################
# doing the git setup.
# Arguments:
#   git_user_email
#   git_user_name
#   source_repo_hostname
#######################################
function git_init() {
  debug "::group::git init"
  info "set git global configuration"

  local git_user_email=$1
  local git_user_name=$2
  local source_repo_hostname=$3

  git config user.email "${git_user_email}"
  git config user.name "${git_user_name}"
  git config pull.rebase false
  git config --add safe.directory /github/workspace

   if [[ "${IS_GIT_LFS}" == 'true' ]]; then
    info "enable git lfs."
    git lfs install
  fi

  add_git_cred_helpers

  if [[ "${SOURCE_REPO_PROTO}" == 'ssh' ]]; then
    info "the source repository is ssh."
    mkdir -p "${HOME}"/.ssh
    ssh-keyscan -t rsa "${source_repo_hostname}" >> "${HOME}"/.ssh/known_hosts
  fi

  if [[ "${SOURCE_REPO_TYPE}" == "github" ]]; then
    info "the source repository is in GitHub."
    gh auth setup-git --hostname "${source_repo_hostname}"
    gh auth status --hostname "${source_repo_hostname}"
  fi
  if [[ "${SOURCE_REPO_TYPE}" == "gitea" ]]; then
    base_url=$(echo "${SOURCE_REPO}" | cut -d "/" -f 1-3)
    info "the source repository is in Gitea. Adding ${base_url} login to tea"
    tea login add --name source --url "${base_url}" --token "${SOURCE_REPO_TOKEN}"
  fi
  if [[ "${TARGET_REPO_TYPE}" == "gitea" ]]; then
    base_url=$(echo "${TARGET_REPO}" | cut -d "/" -f 1-3)
    info "the target repository is in Gitea. Adding ${base_url} login to tea"
    tea login add --name target --url "${base_url}" --user "${GITHUB_USER}" --password "${GITHUB_TOKEN}" --token "${GITHUB_TOKEN}"
  fi

  debug "::endgroup::"
}

###################################################
# Logic
###################################################

if [[ "${TARGET_REPO_TYPE}" == 'gitea' ]]; then
  info "The target repository is located in Gitea. Install tea."
  wget -nv https://dl.gitea.com/tea/main/tea-main-linux-amd64 -O /usr/bin/tea
  chmod 755 /usr/bin/tea
fi

# Forward to /dev/null to swallow the output of the private key
if [[ -n "${SSH_PRIVATE_KEY_SRC}" ]] &>/dev/null; then
  ssh_setup "${SSH_PRIVATE_KEY_SRC}" "${SOURCE_REPO_HOSTNAME}"
elif [[ "${SOURCE_REPO_HOSTNAME}" != "${DEFAULT_REPO_HOSTNAME}" ]]; then
  if [[ "${SOURCE_REPO_TYPE}" == "github" ]]; then
    info "the source repository is located in Github."
    gh auth login --git-protocol "https" --hostname "${SOURCE_REPO_HOSTNAME}" --with-token <<< "${GITHUB_TOKEN}"
  fi
fi

git_init "${GIT_USER_EMAIL}" "${GIT_USER_NAME}" "${SOURCE_REPO_HOSTNAME}"

if [[ -n "${GPG_PRIVATE_KEY}" ]] &>/dev/null; then
  gpg_setup "${GPG_PRIVATE_KEY}" "${GIT_USER_EMAIL}"
fi

# shellcheck source=src/sync_template.sh
source "${SCRIPT_DIR}/sync_template.sh"
