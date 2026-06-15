# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# deploy_pgvector_controller
#
# Deploys a standalone PostgreSQL 16 + pgvector instance into the
# `pgvector` namespace using the bundled Helm chart at
# core/helm-charts/pgvector/.
#
# After deployment the in-cluster connection string is:
#   postgresql://agentuser:<password>@pgvector.pgvector.svc.cluster.local:5432/agentdb
#
# The full DSN is also stored in a Kubernetes Secret:
#   kubectl get secret pgvector-credentials -n pgvector \
#     -o jsonpath='{.data.DATABASE_URL}' | base64 -d
#
# Prerequisites:
#   • Kubernetes is running  (kubectl get nodes)
#   • SCRIPT_DIR points to the core/ directory
# ---------------------------------------------------------------------------
deploy_pgvector_controller() {
    local chart_path="${SCRIPT_DIR}/helm-charts/pgvector"
    local pgvector_ns="pgvector"

    echo "${BLUE}======================================================${NC}"
    echo "${BLUE}  Deploying PostgreSQL + pgvector${NC}"
    echo "${BLUE}======================================================${NC}"

    if [[ ! -d "${chart_path}" ]]; then
        echo "${RED}ERROR: pgvector Helm chart not found at ${chart_path}${NC}"
        exit 1
    fi

    if ! command -v helm &>/dev/null; then
        echo "${CYAN}Installing Helm...${NC}"
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    echo "${CYAN}[1/3] Creating namespace '${pgvector_ns}'...${NC}"
    kubectl create namespace "${pgvector_ns}" --dry-run=client -o yaml | kubectl apply -f -

    # Read passwords from vault.yml (generated once by generate-vault-secrets.sh)
    local vault_file="${SCRIPT_DIR}/inventory/metadata/vault.yml"
    local pgv_password=""
    local pgv_postgres_password=""
    if [[ -f "${vault_file}" ]]; then
        pgv_password="$(grep '^pgvector_password:' "${vault_file}" \
            | sed 's/pgvector_password:[[:space:]]*//' | tr -d '"' || true)"
        pgv_postgres_password="$(grep '^pgvector_postgres_password:' "${vault_file}" \
            | sed 's/pgvector_postgres_password:[[:space:]]*//' | tr -d '"' || true)"
    fi
    if [[ -z "${pgv_password}" || -z "${pgv_postgres_password}" ]]; then
        echo "${RED}ERROR: pgvector_password / pgvector_postgres_password not found in vault.yml.${NC}"
        echo "${RED}       Re-run generate-vault-secrets.sh to regenerate vault.yml.${NC}"
        exit 1
    fi

    echo "${CYAN}[2/3] Deploying PostgreSQL + pgvector via Helm (namespace: ${pgvector_ns})...${NC}"
    helm upgrade --install pgvector "${chart_path}" \
        --namespace "${pgvector_ns}" \
        --set auth.password="${pgv_password}" \
        --set auth.postgresPassword="${pgv_postgres_password}" \
        --wait --timeout 5m

    echo "${CYAN}[3/3] Verifying pgvector extension...${NC}"
    local pg_pod
    pg_pod=$(kubectl get pod -n "${pgvector_ns}" -l app.kubernetes.io/name=pgvector \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "${pg_pod}" ]]; then
        kubectl exec -n "${pgvector_ns}" "${pg_pod}" -- \
            psql -U agentuser -d agentdb \
            -c "SELECT extname, extversion FROM pg_extension WHERE extname='vector';" \
            2>/dev/null && echo "${GREEN}pgvector extension confirmed.${NC}" || \
            echo "${YELLOW}WARN: Could not verify pgvector extension — pod may still be initialising.${NC}"
    fi

    echo ""
    echo "${GREEN}============================================================${NC}"
    echo "${GREEN}  PostgreSQL + pgvector deployed successfully!${NC}"
    echo "${GREEN}  Namespace   : ${pgvector_ns}${NC}"
    echo "${GREEN}  In-cluster  : pgvector.pgvector.svc.cluster.local:5432${NC}"
    echo "${GREEN}  Database    : agentdb${NC}"
    echo "${GREEN}  User        : agentuser${NC}"
    echo "${GREEN}  DSN secret  : pgvector-credentials (key: DATABASE_URL)${NC}"
    echo "${GREEN}============================================================${NC}"
}
