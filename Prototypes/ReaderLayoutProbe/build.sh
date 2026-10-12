#!/usr/bin/env bash
set -euo pipefail
base="$(cd "$(dirname "$0")" && pwd)"
swiftc -swift-version 5 -O "$base/ReaderLayoutProbe.swift" -o "$base/reader-layout-probe"
