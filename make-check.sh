#!/bin/sh
# Measure the things this renderer has got wrong before, and check that the two
# Uniforms declarations still agree.
# See Tools/check-render/main.swift for what each one is and why it exists.
set -e
cd "$(dirname "$0")"
swift run check-render Sources/BlackHoleApp/BlackHole.metal
