# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

update_drivers_and_firmware() {    
    echo "-------------------------------------------------"
    echo "|        Update Drivers and Firmware             |"
    echo "|------------------------------------------------|"
    echo "| 1) Update Drivers                              |"
    echo "| 2) Update Firmware                             |"
    echo "| 3) Update Both Drivers and Firmware            |"
    echo "|------------------------------------------------|"
    echo "Please choose an option (1, 2, or 3):"
    read -p "> " update_choice
    case $update_choice in
        1)
            update_gaudi_drivers
            ;;
        2)
            update_gaudi_firmware
            ;;
        3)
            update_gaudi_driver_and_firmware_both
            ;;
        *)
            echo "Invalid option. Please enter 1, 2, or 3."
            update_drivers_and_firmware
            ;;
    esac
}



manage_worker_nodes() {
    echo "-------------------------------------------------"
    echo "| Manage Worker Nodes                            |"
    echo "|------------------------------------------------|"
    echo "| 1) Add Worker Node                             |"
    echo "| 2) Remove Worker Node                          |"
    echo "|------------------------------------------------|"
    echo "Please choose an option (1 or 2):"
    read -p "> " worker_choice
    case $worker_choice in
        1)
            add_worker_node "$@"
            ;;
        2)
            remove_worker_node "$@"
            ;;
        *)
            echo "Invalid option. Please enter 1 or 2."
            manage_worker_nodes
            ;;
    esac
}



switch_coding_agent_model() {
    local cfg="${SCRIPT_DIR}/inventory/agentic-config.cfg"
    if [[ ! -f "${cfg}" ]]; then
        echo "ERROR: Config file not found at ${cfg}"
        return 1
    fi

    local current_model_key
    current_model_key="$(grep '^models=' "${cfg}" | cut -d= -f2 | cut -d, -f1 | tr -d '[:space:]')"
    local hf_model_name
    hf_model_name="$(_coding_agent_model_hf_name "${current_model_key}")"

    echo "-------------------------------------------------"
    echo "|     Switch Coding Agent Model                  |"
    echo "|------------------------------------------------|"
    echo "  Config model : ${current_model_key}"
    echo "  HuggingFace  : ${hf_model_name}"
    echo "-------------------------------------------------"
    echo -en "Apply this model to the Coding Agent now? (y/n) "
    read -r confirm
    if [[ ! "${confirm,,}" =~ ^(y|yes)$ ]]; then
        echo "Cancelled."
        return 0
    fi

    echo "Updating coding-agent configmap..."
    kubectl patch configmap coding-agent-config -n coding-agent --type merge \
        -p "{\"data\":{\"MODEL_NAME\":\"${hf_model_name}\",\"OPENAI_MODEL\":\"${hf_model_name}\",\"OPENAI_CHAT_COMPLETION_MODEL\":\"${hf_model_name}\"}}" \
    && echo "Restarting coding-agent pod..." \
    && kubectl rollout restart deployment/coding-agent -n coding-agent \
    && kubectl rollout status deployment/coding-agent -n coding-agent --timeout=120s \
    && echo "Coding Agent is now using: ${hf_model_name}" \
    || echo "ERROR: Failed to switch model. Check kubectl access and pod status."
}

manage_models() {
    echo "-------------------------------------------------"
    echo "| Manage LLM Models                               "
    echo "|------------------------------------------------|"
    echo "| 1) Deploy Model                                |"
    echo "| 2) Undeploy Model                              |"
    echo "| 3) List Installed Models                       |"
    echo "| 4) Deploy Model from Hugging Face              |"
    echo "| 5) Remove Model using deployment name          |"
    echo "| 6) Switch Coding Agent to Current Model        |"
    echo "|------------------------------------------------|"
    echo "Please choose an option (1, 2, 3, 4, 5 or 6):"
    read -p "> " model_choice
    case $model_choice in
        1)
            add_model "$@"
            ;;
        2)
            remove_model "$@"
            ;;
        3)
            list_models "$@"
            ;;
        4)
            deploy_from_huggingface "$@"
            ;;
        5)
            remove_model_deployed_via_huggingface "$@"
            ;;
        6)
            switch_coding_agent_model "$@"
            ;;
        *)
            echo "Invalid option. Please enter 1, 2, 3, 4, 5 or 6."
            manage_models
            ;;
    esac
}
