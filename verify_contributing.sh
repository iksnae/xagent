#!/bin/sh
set -e
grep -q 'Swift 6' CONTRIBUTING.md
grep -q 'swift build' CONTRIBUTING.md
grep -q 'swift test' CONTRIBUTING.md
grep -q 'XAgentCore' CONTRIBUTING.md
grep -q 'XAgentDaemon' CONTRIBUTING.md
grep -q 'XAgentHTTP' CONTRIBUTING.md
grep -q 'XAgentCLI' CONTRIBUTING.md
grep -q 'XAgentApp' CONTRIBUTING.md
grep -qi 'pull request' CONTRIBUTING.md
echo "ALL CHECKS PASSED"
