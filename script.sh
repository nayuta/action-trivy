#!/bin/bash

# Print commands for debugging
if [[ -n "${RUNNER_DEBUG}" && "${RUNNER_DEBUG}" = "true" ]]; then
  set -x
fi

if [[ -z "${INPUT_TRIVY_COMMAND}" ]]; then
  echo "Error: Missing required input 'trivy_command'."
  exit 1
fi

if [[ -z "${INPUT_TRIVY_TARGET}" ]]; then
  echo "Error: Missing required input 'trivy_target'."
  exit 1
fi

# Fail fast on errors, unset variables, and failures in piped commands
set -Eeuo pipefail

cd "${GITHUB_WORKSPACE}/${INPUT_WORKING_DIRECTORY}" || exit

echo '::group::Preparing ...'
  unameOS="$(uname -s)"
  echo "unameOS=${unameOS}"
  case "${unameOS}" in
    Linux*)     os=Linux;;
    Darwin*)    os=macOS;;
    CYGWIN*)    os=Windows;;
    MINGW*)     os=Windows;;
    MSYS_NT*)   os=Windows;;
    *)          echo "Unknown system: ${unameOS}" && exit 1
  esac

  unameArch="$(uname -m)"
  case "${unameArch}" in
    x86*)      arch=64bit;;
    arm64)     arch=ARM64;;
    *)         echo "Unsupported architecture: ${unameArch}. Only AMD64 and ARM64 are supported by the action" && exit 1
    esac
  
  case "${os}" in 
    Windows)   archive_extension="zip";;
    *)         archive_extension="tar.gz";;
  esac

  TEMP_PATH="$(mktemp -d)"
  echo "Detected ${os} running on ${arch}, will install tools in ${TEMP_PATH}"
  REVIEWDOG_PATH="${TEMP_PATH}/reviewdog"
  TRIVY_PATH="${TEMP_PATH}/trivy"
echo '::endgroup::'

echo "::group::🐶 Installing reviewdog (${INPUT_REVIEWDOG_VERSION}) ... https://github.com/reviewdog/reviewdog"
  test ! -d "${REVIEWDOG_PATH}" && install -d "${REVIEWDOG_PATH}"

  PREV_DIR=$(pwd)
  TEMP_DOWNLOAD_PATH="$(mktemp -d)"
  cd "${TEMP_DOWNLOAD_PATH}" || exit

  archive="reviewdog.${archive_extension}"
  if [[ "${INPUT_REVIEWDOG_VERSION}" = "latest" ]]; then
    # latest release is available on this url.
    # document: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases
    latest_url="https://github.com/reviewdog/reviewdog/releases/latest/"
    release=$(curl $latest_url -s -L -I -o /dev/null -w '%{url_effective}' | awk -F'/' '{print $NF}')
  else
    release="${INPUT_REVIEWDOG_VERSION}"
  fi
  release_num=${release/#v/}
  case "${arch}" in
    64bit) reviewdog_arch="x86_64";;
    ARM64) reviewdog_arch="arm64";;
    *)     echo "Unsupported architecture: ${unameArch}. Only AMD64 and ARM64 are supported by the action" && exit 1
  esac
  url="https://github.com/reviewdog/reviewdog/releases/download/${release}/reviewdog_${release_num}_${os}_${reviewdog_arch}.${archive_extension}"
  echo "Downloading ${url} to ${archive}" # TODO: Remove (Echo url for testing)
  curl --silent --show-error --fail \
    --location "${url}" \
    --output "${archive}"

  ### TODO: Remove (TEST)
  echo "URL: ${url}"
  echo "ARCHIVE: ${archive}"
  ls 
  ### TEST END
  if [[ "${os}" = "Windows" ]]; then
    unzip "${archive}"
  else
    tar -xzf "${archive}"
  fi
  install reviewdog "${TRIVY_PATH}"
  cd "${PREV_DIR}" || exit
echo '::endgroup::'

echo "::group:: Installing trivy (${INPUT_TRIVY_VERSION}) ... https://github.com/aquasecurity/trivy"
  test ! -d "${TRIVY_PATH}" && install -d "${TRIVY_PATH}"

  PREV_DIR=$(pwd)
  TEMP_DOWNLOAD_PATH="$(mktemp -d)"
  cd "${TEMP_DOWNLOAD_PATH}" || exit

  archive="trivy.${archive_extension}"
  if [[ "${INPUT_TRIVY_VERSION}" = "latest" ]]; then
    # latest release is available on this url.
    # document: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases
    latest_url="https://github.com/aquasecurity/trivy/releases/latest/"
    release=$(curl $latest_url -s -L -I -o /dev/null -w '%{url_effective}' | awk -F'/' '{print $NF}')
  else
    release="${INPUT_TRIVY_VERSION}"
  fi
  release_num=${release/#v/}
  url="https://github.com/aquasecurity/trivy/releases/download/${release}/trivy_${release_num}_${os}-${arch}.${archive_extension}"
  echo "Downloading ${url} to ${archive}" # TODO: Remove (Echo url for testing)
  curl --silent --show-error --fail \
    --location "${url}" \
    --output "${archive}"

  ### TODO: Remove (TEST)
  echo "URL: ${url}"
  echo "ARCHIVE: ${archive}"
  ls 
  ### TEST END
  if [[ "${os}" = "Windows" ]]; then
    unzip "${archive}"
  else
    tar -xzf "${archive}"
  fi
  install trivy "${TRIVY_PATH}"
  cd "${PREV_DIR}" || exit
echo '::endgroup::'

echo "::group:: Print trivy details ..."
  "${TRIVY_PATH}/trivy" --version
echo '::endgroup::'

echo '::group:: Running trivy with reviewdog 🐶 ...'
  export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

  # Allow failures now, as reviewdog handles them
  set +Eeuo pipefail

  # shellcheck disable=SC2086
  "${TRIVY_PATH}/trivy" --format sarif ${INPUT_TRIVY_FLAGS:-} --exit-code 1 ${INPUT_TRIVY_COMMAND} ${INPUT_TRIVY_TARGET} 2> /dev/null \
    |  "${REVIEWDOG_PATH}/reviewdog" -f=sarif \
        -name="${INPUT_TOOL_NAME}" \
        -reporter="${INPUT_REPORTER}" \
        -level="${INPUT_LEVEL}" \
        -fail-on-error="${INPUT_FAIL_ON_ERROR}" \
        -filter-mode="${INPUT_FILTER_MODE}" \
        ${INPUT_FLAGS}

  trivy_return="${PIPESTATUS[0]}" reviewdog_return="${PIPESTATUS[1]}" exit_code=$?
  echo "trivy-return-code=${trivy_return}" >> "$GITHUB_OUTPUT"
  echo "reviewdog-return-code=${reviewdog_return}" >> "$GITHUB_OUTPUT"
echo '::endgroup::'

exit "${exit_code}"
