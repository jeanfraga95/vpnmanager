#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${project_dir}"
CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o hcr-server ./cmd/hcr-server
echo "Built ${project_dir}/hcr-server"
