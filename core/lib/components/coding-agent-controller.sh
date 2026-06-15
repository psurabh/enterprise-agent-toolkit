# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# _coding_agent_model_hf_name
#
# Resolves a model number or slug (as stored in agentic-config.cfg 'models'
# key) to the corresponding Hugging Face model name.
# ---------------------------------------------------------------------------
_coding_agent_model_hf_name() {
    case "${1:-}" in
        21|cpu-llama-8b)                         echo "meta-llama/Llama-3.1-8B-Instruct" ;;
        22|cpu-qwen3-coder-30b)                  echo "Qwen/Qwen3-Coder-30B-A3B-Instruct" ;;
        23|cpu-qwen2-5-coder-14b)                echo "Qwen/Qwen2.5-Coder-14B-Instruct" ;;
        24|cpu-whisper-small)                     echo "openai/whisper-small" ;;
        25|cpu-tei)                              echo "BAAI/bge-small-en-v1.5" ;;
        26|cpu-rerank)                           echo "BAAI/bge-reranker-base" ;;
        *) echo "${1:-Qwen/Qwen3-Coder-30B-A3B-Instruct}" ;;
    esac
}

# ---------------------------------------------------------------------------
# deploy_coding_agent_controller
#
# Builds the Coding Agent container image with nerdctl (BuildKit + containerd
# k8s.io namespace — no Docker daemon, no registry required) and deploys it
# into the cluster via the bundled Helm chart.
#
# Prerequisites (must be satisfied before calling):
#   • Kubernetes is running  (kubectl get nodes)
#   • GenAI Gateway (LiteLLM) is deployed in namespace genai-gateway
#   • SCRIPT_DIR points to the core/ directory
# ---------------------------------------------------------------------------
deploy_coding_agent_controller() {
    local src_dir="${SCRIPT_DIR}/../usecases/coding-agent/src"
    local chart_path="${SCRIPT_DIR}/../usecases/coding-agent/helm-chart"
    local image_name="coding-agent"
    local image_tag="latest"
    local full_image="${image_name}:${image_tag}"
    local litellm_url="http://genai-gateway-service.genai-gateway.svc.cluster.local:4000"
    # Resolve model name dynamically from 'models' variable (set by read_config_file).
    # 'models' may be a comma-separated list; use only the first entry.
    local _first_model
    _first_model="$(echo "${models:-29}" | cut -d',' -f1 | tr -d '[:space:]')"
    local model_name="$(_coding_agent_model_hf_name "${_first_model}")"
    local coding_agent_ns="coding-agent"

    echo "${BLUE}======================================================${NC}"
    echo "${BLUE}  Deploying Coding Agent${NC}"
    echo "${BLUE}  Model: ${model_name}${NC}"
    echo "${BLUE}======================================================${NC}"

    # ── Sanity checks ─────────────────────────────────────────────────────────
    if [[ ! -d "${src_dir}" ]]; then
        echo "${RED}ERROR: Coding agent source not found at ${src_dir}${NC}"
        exit 1
    fi
    if [[ ! -d "${chart_path}" ]]; then
        echo "${RED}ERROR: Coding agent Helm chart not found at ${chart_path}${NC}"
        exit 1
    fi

    # ── Detect containerd socket ──────────────────────────────────────────────
    local containerd_sock=""
    if   [[ -S /run/containerd/containerd.sock ]];     then containerd_sock="/run/containerd/containerd.sock"
    elif [[ -S /var/run/containerd/containerd.sock ]]; then containerd_sock="/var/run/containerd/containerd.sock"
    else
        echo "${RED}ERROR: containerd socket not found. Is Kubernetes running?${NC}"
        echo "${RED}       Check: kubectl get nodes${NC}"
        exit 1
    fi
    echo "${CYAN}Using containerd socket: ${containerd_sock}${NC}"

    # ── Recover LiteLLM master key ────────────────────────────────────────────
    # Priority: 1) k8s secret  2) vault.yml  3) already-set env var  4) fail
    local litellm_api_key=""

    # 1. Try Kubernetes secret (created by genai-gateway helm chart)
    if command -v kubectl &>/dev/null; then
        litellm_api_key="$(kubectl get secret -n genai-gateway litellm-secret \
            -o jsonpath='{.data.LITELLM_MASTER_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    fi

    # 2. Fall back to vault.yml (always present after setup_initial_env)
    if [[ -z "${litellm_api_key}" ]]; then
        local vault_file="${SCRIPT_DIR}/inventory/metadata/vault.yml"
        if [[ -f "${vault_file}" ]]; then
            litellm_api_key="$(grep '^litellm_master_key:' "${vault_file}" \
                | sed 's/litellm_master_key:[[:space:]]*//' \
                | tr -d "'\"" 2>/dev/null || true)"
        fi
    fi

    # 3. Fall back to environment variable
    if [[ -z "${litellm_api_key}" && -n "${LITELLM_MASTER_KEY:-}" ]]; then
        litellm_api_key="${LITELLM_MASTER_KEY}"
    fi

    # 4. Fail clearly rather than deploy with a placeholder key
    if [[ -z "${litellm_api_key}" ]]; then
        echo "${RED}ERROR: Could not determine LITELLM_MASTER_KEY.${NC}"
        echo "${RED}       Tried: k8s secret, vault.yml, \$LITELLM_MASTER_KEY env var.${NC}"
        echo "${RED}       Export it and retry: export LITELLM_MASTER_KEY=sk-...${NC}"
        exit 1
    fi

    echo "${GREEN}LiteLLM master key resolved.${NC}"

    # ── Recover or generate a separate DevUI browser-login token ─────────────
    # Kept separate from the LiteLLM master key so UI access does not expose
    # the backend gateway credential.
    local devui_token=""
    local vault_file_devui="${SCRIPT_DIR}/inventory/metadata/vault.yml"
    if [[ -f "${vault_file_devui}" ]]; then
        devui_token="$(grep '^coding_agent_devui_token:' "${vault_file_devui}" \
            | sed 's/coding_agent_devui_token:[[:space:]]*//' \
            | tr -d "'\"" 2>/dev/null || true)"
    fi
    if [[ -z "${devui_token}" ]]; then
        devui_token="devui-$(openssl rand -hex 16)"
        echo "${YELLOW}Generated new DevUI token — persisting to vault.yml for future runs.${NC}"
        echo "coding_agent_devui_token: \"${devui_token}\"" >> "${vault_file_devui}"
    fi
    echo "${GREEN}DevUI token resolved.${NC}"

    # ── Step 1: Install nerdctl ───────────────────────────────────────────────
    echo ""
    echo "${CYAN}[1/6] Ensuring nerdctl is available...${NC}"
    local nerdctl_version="1.7.7"
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)             arch="amd64" ;;
    esac
    if ! command -v nerdctl &>/dev/null; then
        echo "      Installing nerdctl v${nerdctl_version} (${arch})..."
        curl -fsSL "https://github.com/containerd/nerdctl/releases/download/v${nerdctl_version}/nerdctl-${nerdctl_version}-linux-${arch}.tar.gz" \
            | sudo tar -xz -C /usr/local/bin
        echo "${GREEN}      nerdctl installed.${NC}"
    else
        echo "${GREEN}      nerdctl already present: $(nerdctl --version 2>/dev/null | head -1)${NC}"
    fi

    # ── Step 2: Install BuildKit ──────────────────────────────────────────────
    echo ""
    echo "${CYAN}[2/6] Ensuring BuildKit is available...${NC}"
    local buildkit_version="v0.19.0"
    if ! command -v buildkitd &>/dev/null; then
        echo "      Installing BuildKit ${buildkit_version} (${arch})..."
        curl -fsSL "https://github.com/moby/buildkit/releases/download/${buildkit_version}/buildkit-${buildkit_version}.linux-${arch}.tar.gz" \
            | sudo tar -xz -C /usr/local
        echo "${GREEN}      BuildKit installed.${NC}"
    else
        echo "${GREEN}      BuildKit already present: $(buildkitd --version 2>/dev/null | head -1)${NC}"
    fi

    # ── Step 3: Start buildkitd ───────────────────────────────────────────────
    echo ""
    echo "${CYAN}[3/6] Starting buildkitd daemon...${NC}"
    local bk_started=false
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        if ! sudo systemctl is-active --quiet buildkit 2>/dev/null; then
            if [[ ! -f /etc/systemd/system/buildkit.service ]]; then
                sudo tee /etc/systemd/system/buildkit.service > /dev/null <<BKSVC
[Unit]
Description=BuildKit daemon
Documentation=https://github.com/moby/buildkit
After=containerd.service

[Service]
ExecStart=/usr/local/bin/buildkitd --oci-worker=false --containerd-worker=true --containerd-worker-namespace=k8s.io --containerd-worker-addr ${containerd_sock}
Restart=always
RestartSec=5
KillMode=process

[Install]
WantedBy=multi-user.target
BKSVC
                sudo systemctl daemon-reload
                sudo systemctl enable buildkit 2>/dev/null || true
            fi
            sudo systemctl start buildkit
        fi
        bk_started=true
    fi

    if [[ "${bk_started}" == "false" ]]; then
        if ! pgrep -x buildkitd &>/dev/null; then
            sudo buildkitd \
                --oci-worker=false \
                --containerd-worker=true \
                --containerd-worker-namespace=k8s.io \
                --containerd-worker-addr "${containerd_sock}" \
                &>/tmp/buildkitd.log &
        fi
    fi

    local retries=0
    until sudo buildctl debug workers &>/dev/null 2>&1 || [[ ${retries} -ge 20 ]]; do
        sleep 2; (( retries++ ))
    done
    if [[ ${retries} -ge 20 ]]; then
        echo "${RED}ERROR: buildkitd did not start in time. Check /tmp/buildkitd.log${NC}"
        exit 1
    fi
    echo "${GREEN}      buildkitd ready.${NC}"

    # ── Step 4: Build image into containerd k8s.io namespace ─────────────────
    echo ""
    echo "${CYAN}[4/6] Building Coding Agent image (${full_image}) via nerdctl...${NC}"
    sudo nerdctl \
        --namespace k8s.io \
        build \
        --no-cache \
        --build-arg HTTP_PROXY="${HTTP_PROXY:-}" \
        --build-arg HTTPS_PROXY="${HTTPS_PROXY:-}" \
        --build-arg NO_PROXY="${NO_PROXY:-}" \
        --build-arg http_proxy="${http_proxy:-}" \
        --build-arg https_proxy="${https_proxy:-}" \
        --build-arg no_proxy="${no_proxy:-}" \
        --tag "${full_image}" \
        "${src_dir}"

    if sudo ctr -n k8s.io images ls 2>/dev/null | grep -q "${image_name}"; then
        echo "${GREEN}      Image confirmed in containerd k8s.io namespace: ${full_image}${NC}"
    else
        echo "${YELLOW}WARN: Could not verify image in containerd — check: sudo ctr -n k8s.io images ls | grep coding-agent${NC}"
    fi

    # ── Step 5: Ensure Helm is available ─────────────────────────────────────
    echo ""
    echo "${CYAN}[5/6] Ensuring Helm is available...${NC}"
    if ! command -v helm &>/dev/null; then
        echo "      Installing Helm..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
    echo "${GREEN}      Helm ready: $(helm version --short 2>/dev/null)${NC}"

    # ── Step 6: Helm install / upgrade ────────────────────────────────────────
    echo ""
    echo "${CYAN}[6/6] Deploying Coding Agent via Helm (namespace: ${coding_agent_ns})...${NC}"
    helm upgrade --install coding-agent "${chart_path}" \
        --namespace "${coding_agent_ns}" \
        --create-namespace \
        --set agent.openaiApiKey="${litellm_api_key}" \
        --set agent.devuiAuthToken="${devui_token}" \
        --set agent.openaiBaseUrl="${litellm_url}/v1" \
        --set agent.modelName="${model_name}" \
        --set agent.image.repository="${image_name}" \
        --set agent.image.tag="${image_tag}" \
        --set agent.image.pullPolicy="Never" \
        --set redisUrl="redis://redis-stack-server.redis.svc.cluster.local:6379" \
        --set ingress.enabled=true \
        --set ingress.className=nginx \
        --set ingress.host="coding-agent-${cluster_url}" \
        --set ingress.tls.enabled=true \
        --set ingress.tls.secretName="${cluster_url}" \
        --wait --timeout 10m

    echo ""
    echo "${GREEN}============================================================${NC}"
    echo "${GREEN}  Coding Agent deployed successfully!${NC}"
    echo "${GREEN}  Namespace : ${coding_agent_ns}${NC}"
    echo "${GREEN}  URL       : https://coding-agent-${cluster_url}${NC}"
    echo "${GREEN}============================================================${NC}"
    echo ""
    echo "${YELLOW}  DevUI login token (enter in the browser login prompt):${NC}"
    echo "${CYAN}  ${devui_token}${NC}"
    echo "${YELLOW}  (separate from the LiteLLM master key — UI access only)${NC}"
    echo ""
    echo "  Local access (no DNS): kubectl port-forward -n ${coding_agent_ns} svc/coding-agent 8090:8090"
    echo "                         then open http://localhost:8090"
}
