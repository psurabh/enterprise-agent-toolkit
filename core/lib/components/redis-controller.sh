# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# deploy_redis_controller
#
# Deploys a standalone Redis instance (Bitnami Redis OSS, BSD-3-Clause) into
# the `redis` namespace using the self-contained Helm chart at
# core/helm-charts/redis/.
#
# Image : docker.io/bitnami/redis:8.0.1  (BSD-3-Clause engine, Apache-2.0 packaging)
# License: fully OSI-approved — no RSALv2 / SSPLv1 modules.
#
# After deployment the in-cluster URL is:
#   redis://redis-stack-server.redis.svc.cluster.local:6379
#
# The Service is named `redis-stack-server` for backward compatibility.
#
# To point any agent at this shared instance:
#   --set redisUrl="redis://redis-stack-server.redis.svc.cluster.local:6379"
#
# Prerequisites:
#   • Kubernetes is running  (kubectl get nodes)
#   • SCRIPT_DIR points to the core/ directory
# ---------------------------------------------------------------------------
deploy_redis_controller() {
    local chart_path="${SCRIPT_DIR}/helm-charts/redis"
    local redis_ns="redis"

    echo "${BLUE}======================================================${NC}"
    echo "${BLUE}  Deploying Standalone Redis (Bitnami Redis OSS)${NC}"
    echo "${BLUE}======================================================${NC}"

    if [[ ! -d "${chart_path}" ]]; then
        echo "${RED}ERROR: Redis Helm chart not found at ${chart_path}${NC}"
        exit 1
    fi

    # Ensure Helm is available
    if ! command -v helm &>/dev/null; then
        echo "${CYAN}Installing Helm...${NC}"
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    echo "${CYAN}[1/2] Creating namespace '${redis_ns}'...${NC}"
    kubectl create namespace "${redis_ns}" --dry-run=client -o yaml | kubectl apply -f -

    echo "${CYAN}[2/2] Installing Redis via Helm (namespace: ${redis_ns})...${NC}"
    helm upgrade --install redis "${chart_path}" \
        --namespace "${redis_ns}" \
        --set persistence.storageClass="local-path" \
        --wait --timeout 5m

    echo ""
    echo "${GREEN}============================================================${NC}"
    echo "${GREEN}  Redis deployed successfully!${NC}"
    echo "${GREEN}  Image     : docker.io/bitnami/redis:8.0.1 (BSD-3-Clause)${NC}"
    echo "${GREEN}  Namespace : ${redis_ns}${NC}"
    echo "${GREEN}  In-cluster URL: redis://redis-stack-server.redis.svc.cluster.local:6379${NC}"
    echo "${GREEN}============================================================${NC}"
}
