#!/bin/bash

set -ouex pipefail

CONTEXT_PATH="$(realpath "$(dirname "$0")/..")" # should return /ctx
BUILD_SCRIPTS_PATH="$(realpath "$(dirname "$0")")"

# Load all user customizations and export them so the numbered build scripts
# (e.g. 00-config.sh, 20-users.sh) can read $APP_USER, $NEXTCLOUD_HOST, etc.
printf "::group:: === Loading config.env ===\n"
set -a
# shellcheck disable=SC1091
source "${CONTEXT_PATH}/config.env"
set +a
printf "::endgroup::\n"

# Copy the three filesystem trees onto / in order: base, then services, then
# optionals. Each mirrors the target layout (/etc, /usr, ...).
printf "::group:: === Copying files ===\n"
cp -avf "${CONTEXT_PATH}/base_files/." /
cp -avf "${CONTEXT_PATH}/services_files/." /
cp -avf "${CONTEXT_PATH}/optionals_files/." /
printf "::endgroup::\n"

for script in $(find ${BUILD_SCRIPTS_PATH} -maxdepth 1 -iname "*-*.sh" -type f | sort --sort=human-numeric); do
  printf "::group:: === $(basename "$script") ===\n"
  "$(realpath $script)"
  printf "::endgroup::\n"
done

printf "::group:: === Image Cleanup ===\n"
# Ensure these get run at the _end_ of the build no matter what
"${BUILD_SCRIPTS_PATH}/cleanup.sh"
printf "::endgroup::\n"
