#!/usr/bin/env bash
# Splice deployment tx hashes from the forge broadcast log into mock-suite.json.
#
# Usage:  ./script/merge-mock-suite-txhashes.sh <chainId> [suiteJson] [broadcastJson]
#         chainId        e.g. 11155111 for Sepolia
#         suiteJson      default ./mock-suite.json
#         broadcastJson  default ./broadcast/DeployMockSuite.s.sol/<chainId>/run-latest.json
#
# Writes the merged result to <suiteJson> in place (and a backup at <suiteJson>.bak).
# Requires: jq

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <chainId> [suiteJson] [broadcastJson]" >&2
  exit 1
fi
chainId="$1"
suite="${2:-mock-suite.json}"
bcast="${3:-broadcast/DeployMockSuite.s.sol/$chainId/run-latest.json}"

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }
[ -f "$suite" ] || { echo "missing $suite" >&2; exit 1; }
[ -f "$bcast" ] || { echo "missing $bcast" >&2; exit 1; }

cp "$suite" "$suite.bak"
jq --slurpfile b "$bcast" '
  # Pre-build address -> first-CREATE-hash map from the broadcast log
  ( reduce ($b[0].transactions[] | select(.transactionType == "CREATE")) as $t
      ({}; . + { ($t.contractAddress | ascii_downcase): $t.hash })
  ) as $hashes
  | .erc20  |= map(. as $i | . + {txHash: ($hashes[$i.address | ascii_downcase] // null)})
  | .erc721 |= map(. as $i | . + {txHash: ($hashes[$i.address | ascii_downcase] // null)})
' "$suite" > "$suite.tmp"
mv "$suite.tmp" "$suite"
echo "merged tx hashes into $suite (backup at $suite.bak)"
