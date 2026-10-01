#!/bin/zsh
set -eu
TASK_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/.build/offline-tests"
mkdir -p "$TASK_BUILD/module-cache"
xcrun swiftc -swift-version 6 -module-cache-path "$TASK_BUILD/module-cache" \
  "$TASK_ROOT"/Shared/*.swift \
  "$TASK_ROOT/App/ProfileStore.swift" "$TASK_ROOT/App/SubscriptionService.swift" "$TASK_ROOT/App/LibraryModel.swift" \
  "$TASK_ROOT/Tests/LibraryTests.swift" "$TASK_ROOT/Tests/OfflineTests.swift" \
  -o "$TASK_BUILD/offline-tests"
"$TASK_BUILD/offline-tests"
