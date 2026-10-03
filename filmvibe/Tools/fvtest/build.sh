#!/bin/zsh
# Builds a macOS CLI that runs the app's exact film engine on RAW/JPEG files.
# Usage after building (from this folder):
#   ./fvtest <image> <out.jpg> <longEdge|0=full> <columns> std neutral retro-slide "retro-slide|s=4,cl=-2" ...
# Env: CAPDR=2 (capture DR stops, for photos shot with DR400), NOEV=1 (don't add recipe EV),
#      CROP=x,y,size (100% crop centred at normalised x,y), TUNING=tuning.json (exported from the app).
set -e
cd "$(dirname "$0")"
E=../../FilmVibe
xcrun -sdk macosx metal -c -fcikernel $E/Engine/FilmKernels.metal -o k.air
xcrun -sdk macosx metallib -cikernel k.air -o k.metallib
swiftc -O -o fvtest $E/Model/Recipe.swift $E/Model/EngineTuning.swift $E/Engine/FilmParams.swift \
  $E/Engine/FilmEngine.swift $E/Engine/DevelopSession.swift main.swift
echo "built ./fvtest"
