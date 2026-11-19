#!/bin/bash
# Builds the AirDrop tools of Muna (C, no libraries needed) into airdrop/build/ and runs their tests.
#   scripts/build-airdrop.sh
set -euo pipefail
cd "$(dirname "$0")/../airdrop"
mkdir -p build
CFLAGS="-O2 -Wall -Wextra -Werror"
gcc $CFLAGS -o build/test_awdl test_awdl.c awdl.c
./build/test_awdl
gcc $CFLAGS -o build/muna-awdl muna-awdl.c awdl.c
gcc $CFLAGS -o build/muna-awdld muna-awdld.c awdl.c
python3 test_airdrop.py | tail -1
echo "built airdrop/build/muna-awdl and muna-awdld"
