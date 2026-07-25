#!/bin/sh
# Measure the three things this renderer has got wrong before.
# See Tools/check-render.swift for what each one is and why it exists.
set -e
cd "$(dirname "$0")"
swift Tools/check-render.swift Sources/BlackHoleApp/BlackHole.metal
