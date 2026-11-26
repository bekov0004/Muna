#!/usr/bin/env bash
# Builds and tests Muna for Windows on Linux (docker, the .NET 10 SDK image); the app itself runs only on Windows.
#   windows/scripts/build.sh [test|build|publish]
set -euo pipefail
WIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run() { docker run --rm -v "$WIN":/src -w /src mcr.microsoft.com/dotnet/sdk:10.0 bash -c "$1"; }
case "${1:-build}" in
    test)    run "dotnet test MunaCore.Tests/MunaCore.Tests.csproj" ;;
    build)   run "dotnet build Muna/Muna.csproj -c Release" ;;
    publish) run "dotnet publish Muna/Muna.csproj -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o publish" ;;
    *) echo "usage: $0 [test|build|publish]" >&2; exit 1 ;;
esac
