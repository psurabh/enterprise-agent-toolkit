#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
# AGENTIC AI STACK — UNIFIED DEPLOYMENT SCRIPT
# Deploys: Kubernetes · NGINX Ingress · LiteLLM (GenAI Gateway) · Redis ·
#          Langfuse (Observability) · Prometheus/Grafana · vLLM CPU ·
#          Qwen2.5-Coder-14B-Instruct (default)
#
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Usage:
#   ./deploy-agentic-stack.sh                        # Deploy full base stack
#   ./deploy-agentic-stack.sh --menu                 # Interactive cluster management menu
#
# Target: Single Ubuntu node (this machine)
# =============================================================================

set -euo pipefail

# Repo root — where this script lives
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Core directory containing lib files, playbooks, inventory, etc.
CORE_DIR="${REPO_DIR}/core"

# ──────────────────────────────────────────────────────────────────────────────
# COLOURS
# ──────────────────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

banner()  { echo -e "\n${BLUE}══════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"; }
success() { echo -e "${GREEN}✔  $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠  $1${NC}"; }
error()   { echo -e "${RED}✘  $1${NC}" >&2; exit 1; }
info()    { echo -e "${CYAN}ℹ  $1${NC}"; }

# ── ERR trap: print the exact failing command + line number on any silent exit ─
trap 'echo -e "\n${RED}✘  Command failed at line ${LINENO}: ${BASH_COMMAND}${NC}" >&2' ERR

# ──────────────────────────────────────────────────────────────────────────────
# PARSE FLAGS
# ──────────────────────────────────────────────────────────────────────────────
SHOW_MENU=false

for arg in "$@"; do
    case "${arg}" in
        --menu)                 SHOW_MENU=true ;;
        --help|-h)
            echo "Usage: $0 [--menu]"
            echo "  (no flags)          Deploy base stack only (recommended first run)"
            echo "  --menu           Open the interactive cluster management menu"
            exit 0 ;;
        *)
            echo "ERROR: Unknown argument '${arg}'" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1 ;;
    esac
done

# ──────────────────────────────────────────────────────────────────────────────
# SYSTEM DETECTION — OS family, architecture, package manager
# ──────────────────────────────────────────────────────────────────────────────
OS_ID=""        # ubuntu | debian | rhel | centos | amzn | fedora
OS_FAMILY=""    # debian | rhel
ARCH=""         # amd64 | arm64
PKG_MGR=""      # apt-get | dnf | yum
CONTAINERD_SOCK=""

detect_system() {
    local raw_arch; raw_arch="$(uname -m)"
    case "${raw_arch}" in
        x86_64)        ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) warn "Unsupported arch ${raw_arch} — defaulting to amd64"; ARCH="amd64" ;;
    esac

    local os_like=""
    if [[ -f /etc/os-release ]]; then
        OS_ID="$(. /etc/os-release && echo "${ID}")"
        os_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
    else
        OS_ID="unknown"
    fi

    case "${OS_ID}" in
        ubuntu|debian|linuxmint|pop)
            OS_FAMILY="debian"; PKG_MGR="apt-get" ;;
        rhel|centos|rocky|almalinux|ol)
            OS_FAMILY="rhel"; PKG_MGR="dnf" ;;
        fedora)
            OS_FAMILY="rhel"; PKG_MGR="dnf" ;;
        amzn)
            OS_FAMILY="rhel"; PKG_MGR="yum" ;;
        *)
            if echo "${os_like}" | grep -qi "debian"; then
                OS_FAMILY="debian"; PKG_MGR="apt-get"
            elif echo "${os_like}" | grep -qi "rhel\|fedora\|centos"; then
                OS_FAMILY="rhel"; PKG_MGR="dnf"
            else
                warn "Unknown OS '${OS_ID}' — assuming Debian-family"
                OS_FAMILY="debian"; PKG_MGR="apt-get"
            fi ;;
    esac

    if [[ -z "${ANSIBLE_USER:-}" ]]; then
        # Prefer the ansible_user already set in hosts.yaml if it exists
        local _hosts_yaml="${CORE_DIR}/inventory/hosts.yaml"
        if [[ -f "${_hosts_yaml}" ]]; then
            ANSIBLE_USER=$(grep 'ansible_user:' "${_hosts_yaml}" | head -1 | awk '{print $2}' | tr -d '"'"'" )
        fi
        # Fall back to OS-based default if hosts.yaml has no value
        if [[ -z "${ANSIBLE_USER:-}" ]]; then
            case "${OS_ID}" in
                ubuntu)                  ANSIBLE_USER="ubuntu" ;;
                debian)                  ANSIBLE_USER="admin" ;;
                amzn)                    ANSIBLE_USER="ec2-user" ;;
                centos)                  ANSIBLE_USER="centos" ;;
                rhel|rocky|almalinux|ol) ANSIBLE_USER="ec2-user" ;;
                *)                       ANSIBLE_USER="${USER:-$(id -un)}" ;;
            esac
        fi
    fi

    if [[ -z "${CONTAINERD_SOCK:-}" ]]; then
        if   [[ -S /run/containerd/containerd.sock ]];     then CONTAINERD_SOCK="/run/containerd/containerd.sock"
        elif [[ -S /var/run/containerd/containerd.sock ]]; then CONTAINERD_SOCK="/var/run/containerd/containerd.sock"
        else CONTAINERD_SOCK="/run/containerd/containerd.sock"
        fi
    fi

    success "System: OS=${OS_ID} (${OS_FAMILY}) | Arch=${ARCH} | PkgMgr=${PKG_MGR} | User=${ANSIBLE_USER}"
}

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit these or pass as env vars before running
# ──────────────────────────────────────────────────────────────────────────────
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-api.example.com}"
HUGGINGFACE_TOKEN="${HUGGINGFACE_TOKEN:-}"          # REQUIRED
MODELS="${MODELS:-cpu-qwen2-5-coder-14b}"
ANSIBLE_USER="${ANSIBLE_USER:-}"
CERT_DIR="${HOME}/certs"

# GenAI Gateway (LiteLLM) secrets — change before production use
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-litellm-master-$(openssl rand -hex 8)}"
LITELLM_SALT_KEY="${LITELLM_SALT_KEY:-salt-$(openssl rand -hex 8)}"
LITELLM_DB_PASS="${LITELLM_DB_PASS:-pgpass-$(openssl rand -hex 8)}"
# Keycloak/APISIX are not used in this Agentic AI Stack setup

DEPLOY_LOG="${REPO_DIR}/deploy.log"

# ──────────────────────────────────────────────────────────────────────────────
# PACKAGE INSTALLER ABSTRACTION
# ──────────────────────────────────────────────────────────────────────────────
pkg_install() {
    case "${PKG_MGR}" in
        apt-get) sudo apt-get install -y -qq "$@" 2>&1 | tail -3 ;;
        dnf)     sudo dnf install -y -q  "$@" ;;
        yum)     sudo yum install -y -q  "$@" ;;
        *)       warn "Unknown PKG_MGR '${PKG_MGR}' — trying apt-get"
                 sudo apt-get install -y -qq "$@" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# MODEL DISPLAY NAME — converts model number or internal ID to HF model name
# ──────────────────────────────────────────────────────────────────────────────
_model_display_name() {
    case "${1:-}" in
        21|cpu-llama-8b)            echo "meta-llama/Llama-3.1-8B-Instruct" ;;
        22|cpu-qwen3-coder-30b)     echo "Qwen/Qwen3-Coder-30B-A3B-Instruct" ;;
        23|cpu-qwen2-5-coder-14b)   echo "Qwen/Qwen2.5-Coder-14B-Instruct" ;;
        24|cpu-whisper-small)       echo "openai/whisper-small" ;;
        25|cpu-tei)                 echo "BAAI/bge-small-en-v1.5" ;;
        26|cpu-rerank)              echo "BAAI/bge-reranker-base" ;;
        *) echo "${1:-unknown}" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# VALIDATE INPUTS
# ──────────────────────────────────────────────────────────────────────────────
validate_inputs() {
    banner "Validating Inputs"
    [[ -z "${HUGGINGFACE_TOKEN}" ]] && \
        error "HUGGINGFACE_TOKEN is required.\n  Export it: export HUGGINGFACE_TOKEN=hf_xxxx\n  Then re-run this script."
    [[ "$(id -u)" -eq 0 ]] && \
        warn "Running as root is not recommended — prefer a sudo-enabled non-root user."
    success "Inputs OK  (model: $(_model_display_name "${MODELS}"), domain: ${CLUSTER_DOMAIN})"
}

# ──────────────────────────────────────────────────────────────────────────────
# SYSTEM PREREQUISITES
# ──────────────────────────────────────────────────────────────────────────────
install_prereqs() {
    banner "Installing System Prerequisites"
    case "${PKG_MGR}" in
        apt-get)
            sudo apt-get update -qq
            pkg_install \
                git curl wget openssl sshpass python3 python3-pip python3-venv \
                software-properties-common apt-transport-https ca-certificates \
                jq unzip
            ;;
        dnf)
            sudo dnf makecache -q 2>/dev/null || true
            pkg_install epel-release 2>/dev/null || true
            pkg_install \
                git curl wget openssl sshpass python3 python3-pip \
                ca-certificates jq unzip
            ;;
        yum)
            sudo yum makecache -q 2>/dev/null || true
            pkg_install epel-release 2>/dev/null || true
            pkg_install \
                git curl wget openssl python3 python3-pip \
                ca-certificates jq unzip
            ;;
    esac
    success "System packages installed"
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH KEY SETUP (passwordless localhost)
# ──────────────────────────────────────────────────────────────────────────────
setup_ssh() {
    banner "Configuring SSH (passwordless localhost)"
    if [[ ! -f "${HOME}/.ssh/id_ed25519" ]]; then
        ssh-keygen -t ed25519 -N "" -f "${HOME}/.ssh/id_ed25519" -q
        info "Generated new ed25519 key"
    fi
    local pubkey
    pubkey="$(cat "${HOME}/.ssh/id_ed25519.pub")"
    grep -qF "${pubkey}" "${HOME}/.ssh/authorized_keys" 2>/dev/null || \
        echo "${pubkey}" >> "${HOME}/.ssh/authorized_keys"
    chmod 600 "${HOME}/.ssh/authorized_keys"
    ssh-keyscan -H localhost >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
    ssh-keyscan -H 127.0.0.1 >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
    success "SSH configured for localhost"
}

# ──────────────────────────────────────────────────────────────────────────────
# SELF-SIGNED TLS CERTIFICATE
# ──────────────────────────────────────────────────────────────────────────────
generate_certs() {
    banner "Generating Self-Signed TLS Certificate"
    mkdir -p "${CERT_DIR}"
    if [[ -f "${CERT_DIR}/cert.pem" && -f "${CERT_DIR}/key.pem" ]]; then
        warn "Certificates already exist at ${CERT_DIR} — reusing"
        return
    fi
    openssl req -x509 -newkey rsa:4096 -keyout "${CERT_DIR}/key.pem" \
        -out "${CERT_DIR}/cert.pem" -days 365 -nodes \
        -subj "/CN=${CLUSTER_DOMAIN}" \
        -addext "subjectAltName=DNS:${CLUSTER_DOMAIN},DNS:trace-${CLUSTER_DOMAIN},DNS:*.${CLUSTER_DOMAIN}" \
        2>/dev/null
    success "Certificate generated → ${CERT_DIR}/cert.pem"

    info "Adding ${CLUSTER_DOMAIN} and use-case subdomains → 127.0.0.1 to /etc/hosts (requires sudo)"
    if ! grep -q "${CLUSTER_DOMAIN}" /etc/hosts; then
        echo "127.0.0.1 ${CLUSTER_DOMAIN} trace-${CLUSTER_DOMAIN}" | sudo tee -a /etc/hosts > /dev/null
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# PREPARE REPO — patch model list and strip stale kubespray
# ──────────────────────────────────────────────────────────────────────────────
prepare_repo() {
    banner "Preparing Repository"

    # Remove stale kubespray so the deployment clones a fresh copy
    if [[ -d "${CORE_DIR}/kubespray" ]]; then
        info "Removing stale kubespray (will be cloned fresh during deployment)…"
        rm -rf "${CORE_DIR}/kubespray"
        success "Stale kubespray removed"
    fi

    success "Repository prepared"
}

# ──────────────────────────────────────────────────────────────────────────────
# WRITE hosts.yaml (single-node — this machine)
# ──────────────────────────────────────────────────────────────────────────────
write_hosts_yaml() {
    banner "Writing Inventory (hosts.yaml)"
    mkdir -p "${CORE_DIR}/inventory"
    cat > "${CORE_DIR}/inventory/hosts.yaml" <<EOF
all:
  hosts:
    master1:
      ansible_connection: local
      ansible_user: ${ANSIBLE_USER}
      ansible_become: true
  children:
    kube_control_plane:
      hosts:
        master1:
    kube_node:
      hosts:
        master1:
    etcd:
      hosts:
        master1:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
EOF
    success "hosts.yaml written"
}

# ──────────────────────────────────────────────────────────────────────────────
# WRITE agentic-config.cfg
# Enables: K8s · Ingress · GenAI Gateway · Observability · Qwen3-Coder-30B
# Keycloak and APISIX are explicitly excluded from this stack.
#
# IMPORTANT: If the file already exists, only missing keys are added.
#            Existing values are NEVER overwritten — re-runs are safe.
# ──────────────────────────────────────────────────────────────────────────────
write_config() {
    banner "Writing Agentic AI Config (agentic-config.cfg)"
    mkdir -p "${CORE_DIR}/inventory"
    local _cfg="${CORE_DIR}/inventory/agentic-config.cfg"

    # Helper: append key=value only when the key is not already in the file
    _cfg_set_default() {
        local _key="$1" _val="$2"
        if ! grep -qE "^${_key}=" "${_cfg}" 2>/dev/null; then
            echo "${_key}=${_val}" >> "${_cfg}"
        fi
    }

    # Compute proxy values (env vars take priority over nothing)
    local _http_proxy="${http_proxy:-${HTTP_PROXY:-}}"
    local _https_proxy="${https_proxy:-${HTTPS_PROXY:-}}"
    local _no_proxy="${no_proxy:-${NO_PROXY:-}}"
    local _k8s_no_proxy=".svc,.svc.cluster.local,169.254.0.0/16,${CLUSTER_DOMAIN}"
    if [[ -n "${_no_proxy}" ]]; then
        [[ "${_no_proxy}" != *".svc.cluster.local"* ]] && _no_proxy="${_no_proxy},${_k8s_no_proxy}"
    else
        _no_proxy="${_k8s_no_proxy}"
    fi

    if [[ ! -f "${_cfg}" ]]; then
        # ── Fresh file: write all defaults ──────────────────────────────────
        cat > "${_cfg}" <<EOF
cluster_url=${CLUSTER_DOMAIN}
cert_file=${CERT_DIR}/cert.pem
key_file=${CERT_DIR}/key.pem
hugging_face_token=${HUGGINGFACE_TOKEN}
hugging_face_token_falcon3=${HUGGINGFACE_TOKEN}
models=cpu-qwen2-5-coder-14b
cpu_or_gpu=cpu
vault_pass_code=place-holder-123
deploy_kubernetes_fresh=on
deploy_ingress_controller=on
deploy_genai_gateway=on
deploy_observability=on
deploy_llm_models=on
deploy_ceph=off
deploy_istio=off
uninstall_ceph=off
deploy_agenticai_plugin=off
deploy_redis=on
http_proxy=${_http_proxy}
https_proxy=${_https_proxy}
no_proxy=${_no_proxy}
EOF
        success "agentic-config.cfg created with defaults"
    else
        # ── File already exists: only fill in any keys that are missing ─────
        warn "agentic-config.cfg already exists — preserving all existing values"
        info "Adding any missing config keys with defaults…"

        _cfg_set_default "cluster_url"              "${CLUSTER_DOMAIN}"
        _cfg_set_default "cert_file"                "${CERT_DIR}/cert.pem"
        _cfg_set_default "key_file"                 "${CERT_DIR}/key.pem"
        _cfg_set_default "hugging_face_token"        "${HUGGINGFACE_TOKEN}"
        _cfg_set_default "hugging_face_token_falcon3" "${HUGGINGFACE_TOKEN}"
        _cfg_set_default "models"                   "cpu-qwen2-5-coder-14b"
        _cfg_set_default "cpu_or_gpu"               "cpu"
        _cfg_set_default "vault_pass_code"          "place-holder-123"
        _cfg_set_default "deploy_kubernetes_fresh"  "on"
        _cfg_set_default "deploy_ingress_controller" "on"
        _cfg_set_default "deploy_genai_gateway"     "on"
        _cfg_set_default "deploy_observability"     "on"
        _cfg_set_default "deploy_llm_models"        "on"
        _cfg_set_default "deploy_ceph"              "off"
        _cfg_set_default "deploy_istio"             "off"
        _cfg_set_default "uninstall_ceph"           "off"
        _cfg_set_default "deploy_agenticai_plugin"  "off"
        _cfg_set_default "deploy_redis"             "on"
        _cfg_set_default "http_proxy"               "${_http_proxy}"
        _cfg_set_default "https_proxy"              "${_https_proxy}"
        # no_proxy gets k8s suffixes injected only when the key is absent
        if ! grep -qE "^no_proxy=" "${_cfg}" 2>/dev/null; then
            echo "no_proxy=${_no_proxy}" >> "${_cfg}"
        fi

        success "agentic-config.cfg verified — all existing values preserved"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# SOURCE CORE LIB FILES
# Sets SCRIPT_DIR / HOMEDIR / KUBESPRAYDIR to the core/ directory so all
# lib functions resolve paths correctly (ansible playbooks, inventory, etc.)
# ──────────────────────────────────────────────────────────────────────────────
_source_core_libs() {
    # The lib files use variables set dynamically by read_config_file / parse_arguments
    # and were written without nounset. Disable -u while sourcing and running lib code
    # to avoid "unbound variable" errors for conditionally-set config vars.
    set +u

    # Override SCRIPT_DIR / HOMEDIR before AND after sourcing config-vars.sh
    # because config-vars.sh resets HOMEDIR to $(pwd) and KUBESPRAYDIR to $0-based path.
    SCRIPT_DIR="${CORE_DIR}"
    HOMEDIR="${CORE_DIR}"
    KUBESPRAYDIR="${CORE_DIR}/kubespray"
    VENVDIR="${CORE_DIR}/kubespray225-venv"
    INVENTORY_PATH="${KUBESPRAYDIR}/inventory/mycluster/hosts.yaml"

    source "${CORE_DIR}/lib/system/config-vars.sh"

    # Re-apply after sourcing (config-vars.sh overwrites these with $(pwd)/$0 values)
    SCRIPT_DIR="${CORE_DIR}"
    HOMEDIR="${CORE_DIR}"
    KUBESPRAYDIR="${CORE_DIR}/kubespray"
    VENVDIR="${CORE_DIR}/kubespray225-venv"
    INVENTORY_PATH="${KUBESPRAYDIR}/inventory/mycluster/hosts.yaml"

    source "${CORE_DIR}/lib/system/execute-and-check.sh"
    source "${CORE_DIR}/lib/system/setup-env.sh"
    source "${CORE_DIR}/lib/system/precheck/read-config-file.sh"
    source "${CORE_DIR}/lib/system/precheck/prereq-check.sh"
    source "${CORE_DIR}/lib/system/precheck/readiness-check.sh"

    source "${CORE_DIR}/lib/cluster/config/cluster-config-init.sh"
    source "${CORE_DIR}/lib/cluster/config/setup-user-cluster-config.sh"
    source "${CORE_DIR}/lib/cluster/config/label-nodes.sh"
    source "${CORE_DIR}/lib/cluster/state/cluster-state-check.sh"
    source "${CORE_DIR}/lib/cluster/deployment/fresh-install.sh"
    source "${CORE_DIR}/lib/cluster/deployment/cluster-update.sh"
    source "${CORE_DIR}/lib/cluster/deployment/cluster-purge.sh"
    source "${CORE_DIR}/lib/cluster/nodes/add-node.sh"
    source "${CORE_DIR}/lib/cluster/nodes/remove-node.sh"
    source "${CORE_DIR}/lib/cluster/drv-fw-update.sh"

    source "${CORE_DIR}/lib/components/kubernetes-setup.sh"
    source "${CORE_DIR}/lib/components/intel-base-operator.sh"
    source "${CORE_DIR}/lib/components/ingress-controller.sh"
    # keycloak-controller.sh intentionally not sourced — Keycloak/APISIX not used
    source "${CORE_DIR}/lib/components/genai-gateway-controller.sh"
    source "${CORE_DIR}/lib/components/observability-controller.sh"
    source "${CORE_DIR}/lib/components/storage/install-ceph-cluster.sh"
    source "${CORE_DIR}/lib/components/storage/uninstall-ceph-cluster.sh"
    source "${CORE_DIR}/lib/components/service-mesh/install-istio.sh"
    source "${CORE_DIR}/lib/components/redis-controller.sh"
    source "${CORE_DIR}/lib/components/pgvector-controller.sh"

    source "${CORE_DIR}/lib/models/model-selection.sh"
    source "${CORE_DIR}/lib/models/list-model.sh"
    source "${CORE_DIR}/lib/models/install-model.sh"
    source "${CORE_DIR}/lib/models/uninstall-model.sh"
    source "${CORE_DIR}/lib/models/install-model-hf.sh"
    source "${CORE_DIR}/lib/models/uninstall-model-hf.sh"

    source "${CORE_DIR}/lib/xeon/ballon-policy.sh"

    source "${CORE_DIR}/lib/user-menu/parse-user-prompts.sh"
    source "${CORE_DIR}/lib/user-menu/user-menu.sh"

    source "${CORE_DIR}/lib/brownfield/brownfield_deployment.sh"
}

# ──────────────────────────────────────────────────────────────────────────────
# INTERACTIVE MANAGEMENT MENU (formerly core/agentic-stack.sh entry-point)
# ──────────────────────────────────────────────────────────────────────────────
_show_main_menu() {
    set +u
    _source_core_libs
    # Ensure lib functions see core/ as their working base
    SCRIPT_DIR="${CORE_DIR}"
    HOMEDIR="${CORE_DIR}"
    KUBESPRAYDIR="${CORE_DIR}/kubespray"
    VENVDIR="${CORE_DIR}/kubespray225-venv"
    INVENTORY_PATH="${KUBESPRAYDIR}/inventory/mycluster/hosts.yaml"

    # Strip --menu from args before passing to the core lib's parse_arguments,
    # which does not know about this wrapper-level flag.
    local _filtered_args=()
    for _a in "$@"; do [[ "${_a}" != "--menu" ]] && _filtered_args+=("${_a}"); done

    parse_arguments "${_filtered_args[@]+"${_filtered_args[@]}"}"

    echo -e "${BLUE}----------------------------------------------------------${NC}"
    echo -e "${BLUE}|  Intel Agentic AI Stack                                |${NC}"
    echo -e "${BLUE}|---------------------------------------------------------|${NC}"
    echo -e "| ${CYAN}1)${NC} Provision Base stack Infrastructure                  |"
    echo -e "| ${CYAN}2)${NC} Decommission Existing Cluster                        |"
    echo -e "| ${CYAN}3)${NC} Update Deployed AI Stack                             |"
    echo -e "${BLUE}|---------------------------------------------------------|${NC}"
    echo -e "Please choose an option (${CYAN}1${NC}, ${CYAN}2${NC} or ${CYAN}3${NC}):"
    read -rp "$(echo -e "${CYAN}> ${NC}")" user_choice
    case "${user_choice}" in
        1) fresh_installation "${_filtered_args[@]+"${_filtered_args[@]}"}" ;;
        2) reset_cluster "${_filtered_args[@]+"${_filtered_args[@]}"}" ;;
        3) update_cluster "${_filtered_args[@]+"${_filtered_args[@]}"}" ;;
        *)
            echo "Invalid option. Please enter 1, 2 or 3."
            _show_main_menu "${_filtered_args[@]+"${_filtered_args[@]}"}"            ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# RESUME DETECTION
# Before running fresh_installation, check what is already deployed in the
# cluster and turn the corresponding config flags to 'off' so they are skipped.
# This makes re-runs safe and resumable after a partial failure.
# ──────────────────────────────────────────────────────────────────────────────
_auto_skip_deployed_components() {
    local _cfg="${CORE_DIR}/inventory/agentic-config.cfg"
    [[ ! -f "${_cfg}" ]] && return

    # Only auto-skip when kubectl is available and the cluster is reachable
    if ! command -v kubectl &>/dev/null || ! kubectl get nodes &>/dev/null 2>&1; then
        info "Cluster not reachable yet — all components will be installed fresh"
        return
    fi

    banner "Checking Already-Deployed Components (Resume Mode)"

    # Helper: set a key to 'off' in the config file
    _cfg_turn_off() {
        local _key="$1"
        sed -i "s|^${_key}=.*|${_key}=off|" "${_cfg}" 2>/dev/null || true
    }

    # Kubernetes — if nodes are Ready, K8s is installed
    if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
        _cfg_turn_off "deploy_kubernetes_fresh"
        success "Kubernetes: already running — skipping"
    fi

    # Ingress NGINX controller
    if kubectl get namespace ingress-nginx &>/dev/null 2>&1; then
        _cfg_turn_off "deploy_ingress_controller"
        success "Ingress NGINX: already deployed — skipping"
    fi

    # Keycloak / APISIX — not part of this stack; force off in case they
    # still exist in user-edited configs from a previous run.
    # Keycloak / APISIX — not part of this stack; force off in case they
    # still exist in user-edited configs from a previous run.
    _cfg_turn_off "deploy_keycloak"
    _cfg_turn_off "deploy_apisix"

    # GenAI Gateway (LiteLLM + Langfuse)
    if kubectl get namespace genai-gateway &>/dev/null 2>&1; then
        _cfg_turn_off "deploy_genai_gateway"
        success "GenAI Gateway: already deployed — skipping"
    fi

    # Observability (Prometheus/Grafana/Langfuse trace stack)
    if kubectl get namespace observability &>/dev/null 2>&1; then
        _cfg_turn_off "deploy_observability"
        success "Observability: already deployed — skipping"
    fi

    # LLM Models — only skip if the SPECIFIC requested model's helm release is already deployed.
    # If a different model is running, allow deployment of the new one.
    local _model_helm_release=""
    case "${MODELS}" in
        21|cpu-llama-8b)          _model_helm_release="vllm-llama-8b-cpu" ;;
        22|cpu-qwen3-coder-30b)   _model_helm_release="vllm-qwen3-coder-30b-cpu" ;;
        23|cpu-qwen2-5-coder-14b) _model_helm_release="vllm-qwen-2-5-coder-14b-cpu" ;;
        24|cpu-whisper-small)     _model_helm_release="vllm-whisper-small-cpu" ;;
        25|cpu-tei)               _model_helm_release="vllm-tei-cpu" ;;
        26|cpu-rerank)            _model_helm_release="vllm-rerank-cpu" ;;
    esac
    if [[ -n "${_model_helm_release}" ]] && \
       helm list -n default --short 2>/dev/null | grep -q "^${_model_helm_release}$"; then
        _cfg_turn_off "deploy_llm_models"
        success "LLM Models: ${_model_helm_release} already deployed — skipping"
    else
        info "LLM Models: ${_model_helm_release:-unknown} not yet deployed — will install"
    fi

    # Redis
    if kubectl get namespace redis &>/dev/null 2>&1; then
        _cfg_turn_off "deploy_redis"
        success "Redis: already deployed — skipping"
    fi

    info "Resume check complete — only pending components will be installed"
}

# ──────────────────────────────────────────────────────────────────────────────
# RUN THE MAIN DEPLOYMENT (one-click base stack)
# Sources the core lib files and calls fresh_installation directly.
# "yes" is fed automatically to the confirmation prompt.
# ──────────────────────────────────────────────────────────────────────────────
run_deployment() {
    banner "Running Agentic AI Stack Deployment"
    info "This will take 20-40 minutes for a fresh install…"
    info "Log: ${DEPLOY_LOG}"

    set +u
    _source_core_libs

    # Check what's already in the cluster and skip those components
    _auto_skip_deployed_components

    # Pass deployment parameters through the lib's argument parser
    parse_arguments \
        --cluster-url             "${CLUSTER_DOMAIN}" \
        --cert-file               "${CERT_DIR}/cert.pem" \
        --key-file                "${CERT_DIR}/key.pem" \
        --hugging-face-token      "${HUGGINGFACE_TOKEN}" \
        --models                  "${MODELS}" \
        --cpu-or-gpu              "cpu"

    # Keycloak/APISIX are not used — pre-set to "no" so prompt_for_input()
    # never blocks waiting for interactive input on these.
    deploy_keycloak="no"
    deploy_apisix="no"

    # ansible-playbook uses relative paths; lib functions must run with CWD=core/
    pushd "${CORE_DIR}" > /dev/null

    # Feed "yes" automatically to the "Do you wish to continue?" prompt inside
    # fresh_installation so the one-click flow requires no manual interaction.
    fresh_installation < <(echo "yes") 2>&1 | tee "${DEPLOY_LOG}"

    popd > /dev/null
    success "Base stack deployment complete"
}


print_summary() {
    local _first_model _model_display _test_label _test_body _model_label
    _first_model="$(echo "${MODELS}" | cut -d',' -f1 | xargs)"
    _model_display="$(_model_display_name "${_first_model}")"

    case "${_first_model}" in
        30|cpu-whisper-small)
            _model_label="Whisper Small (ASR)"
            _test_label="Whisper Small (ASR) via LiteLLM"
            _test_body="  curl -k https://${CLUSTER_DOMAIN}/v1/audio/transcriptions \\\n    -H \"Authorization: Bearer ${LITELLM_MASTER_KEY}\" \\\n    -F \"model=openai/openai/whisper-small\" \\\n    -F \"file=@audio.wav\""
            ;;
        31|cpu-tei)
            _model_label="BGE Embedding"
            _test_label="BGE Embedding via LiteLLM"
            _test_body="  curl -k https://${CLUSTER_DOMAIN}/v1/embeddings \\\n    -H \"Content-Type: application/json\" \\\n    -H \"Authorization: Bearer ${LITELLM_MASTER_KEY}\" \\\n    -d '{\"model\": \"huggingface/BAAI/bge-small-en-v1.5\", \"input\": \"Hello world\"}'"
            ;;
        32|cpu-rerank)
            _model_label="BGE Reranker"
            _test_label="BGE Reranker via LiteLLM"
            _test_body="  curl -k https://${CLUSTER_DOMAIN}/v1/rerank \\\n    -H \"Content-Type: application/json\" \\\n    -H \"Authorization: Bearer ${LITELLM_MASTER_KEY}\" \\\n    -d '{\"model\": \"huggingface/BAAI/bge-reranker-base\", \"query\": \"search query\", \"documents\": [\"doc 1\", \"doc 2\"]}'"
            ;;
        *)
            _model_label="${_model_display}"
            _test_label="${_model_display} via LiteLLM"
            _test_body="  curl -k https://${CLUSTER_DOMAIN}/v1/chat/completions \\\n    -H \"Content-Type: application/json\" \\\n    -H \"Authorization: Bearer ${LITELLM_MASTER_KEY}\" \\\n    -d '{\n      \"model\": \"openai/${_model_display}\",\n      \"messages\": [{\"role\":\"user\",\"content\":\"Write a Python function to reverse a string\"}],\n      \"max_tokens\": 200\n    }'"
            ;;
    esac

    banner "Deployment Complete — Access Points"
    echo ""
    echo -e "  ${GREEN}Component              URL / Command${NC}"
    echo    "  ─────────────────────────────────────────────────────────────────────"
    echo -e "  ${CYAN}LiteLLM (GenAI GW)${NC}   https://${CLUSTER_DOMAIN}/ui"
    echo -e "  ${CYAN}Langfuse Traces${NC}       https://trace-${CLUSTER_DOMAIN}"
    echo -e "  ${CYAN}Grafana Dashboards${NC}    https://${CLUSTER_DOMAIN}/observability/login"
    echo -e "  ${CYAN}${_model_label}${NC}      https://${CLUSTER_DOMAIN}/v1"
    echo ""
    echo -e "  ${YELLOW}Quick Test — ${_test_label}${NC}"
    echo    "  ─────────────────────────────────────────────────────────────────────"
    echo -e "${_test_body}"
    echo ""
    echo -e "  ${GREEN}Full deployment log: ${DEPLOY_LOG}${NC}"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
main() {
    # detect_system MUST run first — sets OS_ID, ARCH, PKG_MGR, ANSIBLE_USER, CONTAINERD_SOCK
    detect_system

    # Load settings from existing config so re-runs and one-click runs work without
    # requiring env vars for values that are already stored in agentic-config.cfg.
    local _base_cfg="${CORE_DIR}/inventory/agentic-config.cfg"
    if [[ -f "${_base_cfg}" ]]; then
        local _existing_url _existing_hf_token
        _existing_url=$(grep -E '^cluster_url=' "${_base_cfg}" | cut -d= -f2- || true)
        _existing_hf_token=$(grep -E '^hugging_face_token=' "${_base_cfg}" | cut -d= -f2- || true)

        # cluster_url: only override when CLUSTER_DOMAIN is still the placeholder
        [[ -n "${_existing_url}" && "${CLUSTER_DOMAIN}" == "api.example.com" ]] && \
            CLUSTER_DOMAIN="${_existing_url}"

        # hugging_face_token: load from config when not set via env var
        [[ -z "${HUGGINGFACE_TOKEN}" && -n "${_existing_hf_token}" ]] && \
            HUGGINGFACE_TOKEN="${_existing_hf_token}"

        # models: load from config so banner and deployment use the configured model
        local _existing_models
        _existing_models=$(grep -E '^models=' "${_base_cfg}" | cut -d= -f2- | xargs || true)
        [[ -n "${_existing_models}" ]] && MODELS="${_existing_models}"
    fi

    # ── Interactive menu mode ─────────────────────────────────────────────────
    if [[ "${SHOW_MENU}" == "true" ]]; then
        banner "Agentic AI Stack — Interactive Cluster Management"
        _show_main_menu "$@"
        return
    fi

    # ── One-click base stack deployment (Step 1) ──────────────────────────────
    banner "Agentic AI Stack — One-Click Deployment"
    info "Domain  : ${CLUSTER_DOMAIN}"
    info "Model   : $(_model_display_name "${MODELS}") (vLLM CPU)"
    info "OS      : ${OS_ID} (${OS_FAMILY}) | Arch: ${ARCH} | User: ${ANSIBLE_USER}"
    echo ""
    read -rp "$(echo -e "${CYAN}Do you want to continue with the deployment? [y/N]: ${NC}")" _confirm
    case "${_confirm}" in
        [yY]|[yY][eE][sS]) ;;
        *)
            echo "Deployment cancelled."
            exit 0
            ;;
    esac
    echo ""

    validate_inputs
    install_prereqs
    setup_ssh
    generate_certs
    prepare_repo
    write_hosts_yaml
    write_config

    run_deployment
    print_summary
}

[[ "${DEPLOY_SOURCED:-0}" == "1" ]] || main "$@"
