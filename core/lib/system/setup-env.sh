# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

setup_initial_env() {
    echo "Setting up the Initial Environment..."
    
    if [[ "$skip_check" != "true" ]]; then
        echo "Performing initial system prerequisites check..."
        if ! run_system_prerequisites_check; then
            echo "System prerequisites check failed. Please install missing dependencies and try again."
            exit 1
        fi
        echo "System prerequisites check completed successfully."
    else
        echo "Skipping system prerequisites check due to --skip-check argument."
    fi
        
    if [[ -n "$https_proxy" ]]; then
        git config --global http.proxy "$https_proxy"
        git config --global https.proxy "$https_proxy"
    fi
    if [ ! -d "$KUBESPRAYDIR" ]; then
        git clone https://github.com/kubernetes-sigs/kubespray.git $KUBESPRAYDIR
        if [ $? -ne 0 ] || [ ! -d "$KUBESPRAYDIR/.git" ]; then
            echo -e "${RED}----------------------------------------------------------------------------${NC}"
            echo -e "${RED}|  NOTICE: Failed to clone Kubespray Repository.                           |${NC}"        
            echo -e "${RED}|  Unable to proceed with Inference Stack Deployment                        |${NC}"        
            echo -e "${RED}|  due to missing dependency                                                |${NC}"        
            echo -e "${RED}----------------------------------------------------------------------------${NC}"            
            exit 1
        fi
        cd $KUBESPRAYDIR        
        git checkout "$kubespray_version"
    else
        echo "Kubespray directory already exists, skipping clone."
        cd $KUBESPRAYDIR
    fi
    if [[ -n "$https_proxy" ]]; then
        git config --global --unset http.proxy
        git config --global --unset https.proxy
    fi
    
    VENVDIR="$KUBESPRAYDIR/venv"
    REMOTEDIR="/tmp/helm-charts"    
    if [ ! -d "$VENVDIR" ]; then                
        echo "Installing python3-venv package..."
        if command -v apt &> /dev/null; then            
            python_version=$($python3_interpreter -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")            
            sudo apt install -y python${python_version}-venv || sudo apt install -y python3-venv        
        fi                
        if $python3_interpreter -m venv $VENVDIR; then
            echo "Virtual environment created within Kubespray directory."
        else
            echo -e "${RED}Failed to create virtual environment.${NC}"
            exit 1
        fi
    else
        echo "Virtual environment already exists within Kubespray directory, skipping creation."
    fi
    source $VENVDIR/bin/activate
    echo "Attempting to activate the virtual environment..."    
    if [ -z "$VIRTUAL_ENV" ]; then        
        rm -rf "$KUBESPRAYDIR"
        echo -e "${RED}----------------------------------------------------------------------------${NC}"
        echo -e "${RED}|  NOTICE: Failed to activate the virtual environment.                      |${NC}"
        echo -e "${RED}|  Please retrigger the Inference Stack Deployment                          |${NC}"
        echo -e "${RED}|                                                                           |${NC}"
        echo -e "${RED}----------------------------------------------------------------------------${NC}"
        exit 1
    else
        echo "Virtual environment activated successfully. Path: $VIRTUAL_ENV"
    fi                 
        
    export PIP_BREAK_SYSTEM_PACKAGES=1
    $VENVDIR/bin/python3 -m pip install --upgrade pip
    $VENVDIR/bin/python3 -m pip install -U -r requirements.txt    
    
    echo "Verifying Ansible Installation..."
    if $VENVDIR/bin/python3 -c "import ansible" &> /dev/null; then
        echo -e "${GREEN} Ansible installed successfully${NC}"
    else
        echo -e "${RED}----------------------------------------------------------------------------${NC}"
        echo -e "${RED}|  NOTICE: Ansible Installation Failed.                                     |${NC}"        
        echo -e "${RED}|  Unable to proceed with Inference Stack Deployment                        |${NC}"        
        echo -e "${RED}|  due to missing dependency                                                |${NC}"        
        echo -e "${RED}----------------------------------------------------------------------------${NC}"        
        exit 1
    fi    

    echo -e "${GREEN} Enterprise Inference requirements installed.${NC}"
    cp -r "$HOMEDIR"/helm-charts "$HOMEDIR"/scripts "$KUBESPRAYDIR"/
    cp -r "$KUBESPRAYDIR"/inventory/sample/ "$KUBESPRAYDIR"/inventory/mycluster
    cp  "$HOMEDIR"/inventory/hosts.yaml $KUBESPRAYDIR/inventory/mycluster/
    cp "$HOMEDIR"/inventory/metadata/addons.yml $KUBESPRAYDIR/inventory/mycluster/group_vars/k8s_cluster/addons.yml    
    cp "$HOMEDIR"/playbooks/* "$KUBESPRAYDIR"/playbooks/    
    gaudi2_values_file_path="$REMOTEDIR/vllm/gaudi-values.yaml"
    gaudi3_values_file_path="$REMOTEDIR/vllm/gaudi3-values.yaml"
    xeon_values_file_path="$REMOTEDIR/vllm/xeon-values.yaml"
    cp "$HOMEDIR"/inventory/metadata/addons.yml $KUBESPRAYDIR/inventory/mycluster/group_vars/k8s_cluster/addons.yml
    cp "$HOMEDIR"/inventory/metadata/all.yml $KUBESPRAYDIR/inventory/mycluster/group_vars/all/all.yml
    # Copy roles to kubespray/roles/ AND to kubespray/playbooks/roles/ so Ansible
    # finds them both via roles_path config and relative-to-playbook discovery.
    mkdir -p "$KUBESPRAYDIR/roles" "$KUBESPRAYDIR/playbooks/roles"
    cp -r "$HOMEDIR"/roles/* $KUBESPRAYDIR/roles/
    cp -r "$HOMEDIR"/roles/* $KUBESPRAYDIR/playbooks/roles/

    mkdir -p "$KUBESPRAYDIR/config"        
    chmod +x $HOMEDIR/scripts/generate-vault-secrets.sh

    # Only generate vault secrets if vault.yml doesn't exist or is incomplete
    vault_file="$HOMEDIR/inventory/metadata/vault.yml"
    mandatory_keys=("litellm_master_key" "litellm_salt_key" "redis_password" "langfuse_secret_key" "langfuse_public_key" "postgresql_username" "postgresql_password" "clickhouse_username" "clickhouse_password" "langfuse_login" "langfuse_user" "langfuse_password" "minio_secret" "minio_user" "postgres_user" "postgres_password" "pgvector_password" "pgvector_postgres_password")

    if [ ! -f "$vault_file" ]; then
        echo "vault.yml not found at $vault_file, generating vault secrets..."
        bash $HOMEDIR/scripts/generate-vault-secrets.sh
    else
        echo "Checking vault.yml for mandatory keys..."
        missing_keys=()
        for key in "${mandatory_keys[@]}"; do
            if ! grep -q "^${key}:" "$vault_file"; then
                missing_keys+=("$key")
            fi
        done

        if [ ${#missing_keys[@]} -gt 0 ]; then
            echo -e "${YELLOW}vault.yml exists but is missing mandatory keys: ${missing_keys[*]}${NC}"
            echo "Regenerating vault.yml with all mandatory keys..."
            bash $HOMEDIR/scripts/generate-vault-secrets.sh
        else
            echo -e "${GREEN}vault.yml exists and contains all mandatory keys. Skipping generation...${NC}"
        fi
    fi

    if [ "$purge_inference_cluster" != "purging" ]; then        
        if [[ "$deploy_llm_models" == "yes" || "$deploy_keycloak_apisix" == "yes" || "$deploy_genai_gateway" == "yes" || "$deploy_observability" == "yes" || "$deploy_logging" == "yes" || "$deploy_ceph" == "yes" || "$deploy_istio" == "yes" || "$deploy_finetune_plugin" == "yes" ]]; then
            if [ ! -s "$HOMEDIR/inventory/metadata/vault.yml" ]; then                
                echo -e "${YELLOW}----------------------------------------------------------------------------${NC}"
                echo -e "${YELLOW}|  NOTICE: inventory/metadata/vault.yml is empty!                           |${NC}"
                echo -e "${YELLOW}|  Please refer to docs/configuring-vault-values.md for instructions on     |${NC}"
                echo -e "${YELLOW}|  updating vault.yml                                                       |${NC}"
                echo -e "${YELLOW}----------------------------------------------------------------------------${NC}"
                exit 1
            fi      
        fi          
    fi    
    cp "$HOMEDIR"/inventory/metadata/vault.yml $KUBESPRAYDIR/config/vault.yml            
    mkdir -p "$KUBESPRAYDIR/config/vars" 
    cp -r "$HOMEDIR"/inventory/metadata/vars/* $KUBESPRAYDIR/config/vars/    
    cp "$HOMEDIR"/playbooks/* "$KUBESPRAYDIR"/playbooks/
    echo "Additional files and directories copied to Kubespray directory."
        
    if [[ "$skip_check" != "true" ]]; then
        echo "Performing infrastructure readiness check..."
        if ! run_infrastructure_readiness_check; then
            echo "Infrastructure readiness check failed. Please resolve the issues and try again."
            exit 1
        fi
    else
        echo "Skipping infrastructure readiness check due to --skip-check argument."
    fi
    echo "Infrastructure readiness check completed successfully."    
    gaudi2_values_file_path="$REMOTEDIR/vllm/gaudi-values.yaml"
    gaudi3_values_file_path="$REMOTEDIR/vllm/gaudi3-values.yaml"
    ansible-galaxy collection install community.kubernetes        
}


invoke_prereq_workflows() {
    if [ $prereq_executed -eq 0 ]; then
        read_config_file "$@"
        if [ -z "$cluster_url" ] || [ -z "$cert_file" ] || [ -z "$key_file" ]; then
            echo "Some required arguments are missing. Prompting for input..."
            prompt_for_input
        fi
        setup_initial_env "$@"
        # Set the flag to 1 (executed)
        prereq_executed=1
    else
        echo "Prerequisites have already been executed. Skipping..."
    fi
}

install_ansible_collection() {
    echo "Installing community.general collection..."
    ansible-galaxy collection install community.general
}

# ---------------------------------------------------------------------------
# setup_kernel_and_containerd
#
# Fixes the three kubeadm preflight failures seen on fresh machines:
#   1. IP forwarding disabled  -> enables net.ipv4.ip_forward and bridge-nf
#   2. containerd not running  -> installs, configures SystemdCgroup=true,
#                                 and starts containerd
#   3. br_netfilter module missing -> loaded and persisted
#
# Safe to call on machines where containerd is already running; the function
# is idempotent and skips steps that are already in the desired state.
# ---------------------------------------------------------------------------
setup_kernel_and_containerd() {
    echo "Configuring kernel parameters and containerd for Kubernetes..."

    # ── Load required kernel modules ──────────────────────────────────────────
    sudo modprobe overlay    2>/dev/null || true
    sudo modprobe br_netfilter 2>/dev/null || true

    # Persist modules across reboots
    sudo tee /etc/modules-load.d/kubernetes.conf > /dev/null <<'EOF'
overlay
br_netfilter
EOF

    # ── Enable IP forwarding and bridge netfilter ──────────────────────────────
    sudo tee /etc/sysctl.d/99-kubernetes.conf > /dev/null <<'EOF'
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
    sudo sysctl --system

    echo -e "${GREEN}Kernel parameters applied.${NC}"

    # ── Disable swap (required by kubelet) ────────────────────────────────────
    if swapon --show | grep -q .; then
        echo "Swap is active — disabling..."
        sudo swapoff -a
        echo -e "${GREEN}Swap disabled (runtime).${NC}"
    else
        echo -e "${GREEN}Swap already off.${NC}"
    fi
    # Persist: comment out all swap entries in /etc/fstab
    sudo sed -i.bak -E 's|^([^#].*\s+swap\s+.*)$|# \1|' /etc/fstab
    echo -e "${GREEN}Swap entries disabled in /etc/fstab.${NC}"

    # ── Install and configure containerd if not already running ───────────────
    if systemctl is-active --quiet containerd 2>/dev/null; then
        echo -e "${GREEN}containerd is already running — skipping install.${NC}"
    else
        echo "containerd is not running. Installing and configuring..."
        if command -v apt &>/dev/null; then
            sudo apt update && sudo apt install -y containerd
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y containerd
        else
            echo -e "${RED}ERROR: Cannot install containerd — unknown package manager.${NC}"
            exit 1
        fi

        # Generate default config and enable SystemdCgroup
        sudo mkdir -p /etc/containerd
        containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

        sudo systemctl enable --now containerd
        echo -e "${GREEN}containerd installed and started successfully.${NC}"
    fi
}
