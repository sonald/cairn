#!/usr/bin/env bash
set -euo pipefail
base="$(cd "$(dirname "$0")" && pwd)"
swiftc -swift-version 6 -O "$base/ChunkedContentProbe.swift" -o "$base/chunked-content-probe"
