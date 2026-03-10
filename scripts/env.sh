#!/bin/bash
# Source this to get aztec on PATH, or use as a wrapper: scripts/env.sh <command>
export PATH="$HOME/.aztec/current/bin:$HOME/.aztec/current/node_modules/.bin:$PATH"

if [ $# -gt 0 ]; then
    exec "$@"
fi
