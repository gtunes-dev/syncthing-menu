#!/bin/bash
# Build and run the unit test suite (SyncthingMenuTests) via xcodebuild.
# Ad-hoc signing, same as the Debug build task. Extra args pass through,
# e.g.: Scripts/test.sh -only-testing:SyncthingMenuTests/DaemonSessionTests
set -euo pipefail
cd "$(dirname "$0")/.."

# Silence os_log chatter from the test host (Network.framework's harmless
# nw_path_necp complaints under the test runner). Also mutes the app's NSLog
# lines — when debugging a failing test, run with
# TEST_RUNNER_OS_ACTIVITY_MODE=default to get them back.
export TEST_RUNNER_OS_ACTIVITY_MODE="${TEST_RUNNER_OS_ACTIVITY_MODE:-disable}"

xcodebuild \
  -project SyncthingMenu.xcodeproj \
  -scheme SyncthingMenu \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  test "$@"
