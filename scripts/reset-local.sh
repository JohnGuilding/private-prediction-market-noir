#!/bin/bash
# Reset local development environment for a clean run.
# Safe to run repeatedly — only affects local dev state.

set -e

echo "=== Resetting local dev environment ==="

# Kill any existing aztec processes
echo "Stopping any running aztec processes..."
pkill -f "aztec start" 2>/dev/null || true
pkill -f "anvil" 2>/dev/null || true
sleep 2

# Clean PXE store (local wallet state)
echo "Clearing PXE store..."
rm -rf ./store

# Clean build artifacts (optional, pass --full for full clean)
if [ "$1" = "--full" ]; then
    echo "Full clean: removing artifacts, target, and codegenCache..."
    rm -rf ./src/artifacts ./target ./codegenCache.json
fi

# Stop docker containers if any
if command -v docker &> /dev/null; then
    echo "Stopping docker containers..."
    docker compose down 2>/dev/null || true
fi

echo "=== Reset complete ==="
