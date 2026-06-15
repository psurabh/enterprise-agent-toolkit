#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
# COMPATIBILITY SHIM — this script has been merged into deploy-agentic-stack.sh
# at the repository root.
#
# Running this shim is equivalent to running:
#   ../deploy-agentic-stack.sh --menu [OPTIONS]
#
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../deploy-agentic-stack.sh" --menu "$@"
