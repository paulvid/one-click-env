#!/bin/bash
source $(
    cd $(dirname $0)
    pwd -L
)/common.sh

display_usage() {
    echo "
Usage:
    $(basename "$0") <parameter_file> [--help or -h]

Description:
    Creates AWS pre-requisites, CDP environment, data lake and a data hub clusters + tags the instances to the proper Cloudera policies

Arguments:
    parameter_file: location of your parameter json file (template can be found in parameters_template.json)"

}

# check whether user had supplied -h or --help . If yes display usage
if [[ ($1 == "--help") || $1 == "-h" ]]; then
    display_usage
    exit 0
fi

# Check the numbers of arguments
if [ $# -lt 1 ]; then
    echo "Not enough arguments!" >&2
    display_usage
    exit 1
fi

if [ $# -gt 1 ]; then
    echo "Too many arguments!" >&2
    display_usage
    exit 1
fi

# Parsing arguments

# Parsing arguments
parse_parameters ${1}

# Creating environment
echo "⏱  $(date +%H%Mhrs)"
echo ""
echo "Creating Azure CDP environment for $prefix:"
underline="▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
for ((i = 1; i <= $prefix_length; i++)); do
    underline=${underline}"▔"
done
echo ${underline}

# 1. Environment
env_status=$($base_dir/cdp_describe_env.sh $prefix 2>/dev/null | jq -r .environment.status)
if [ ${#env_status} -eq 0 ]; then
    env_status="NOT_FOUND"
fi

if [[ "$env_status" == "AVAILABLE" ]]; then
    printf "\r${ALREADY_DONE}  $prefix: $prefix-cdp-env already available                             "
    echo ""
    echo ""
else
    if [[ "$env_status" == "ENV_STOPPED" ]]; then
        result=$(cdp environments start-environment --environment-name $prefix-cdp-env 2>&1 >/dev/null)
        handle_exception $? $prefix "environment start" "$result"
        env_status=$($base_dir/cdp_describe_env.sh $prefix | jq -r .environment.status)

        spin='🌑🌒🌓🌔🌕🌖🌗🌘'
        while [ "$env_status" != "AVAILABLE" ]; do
            i=$(((i + 1) % 8))
            printf "\r${spin:$i:1}  $prefix: environment status: $env_status                              "
            sleep 2
            env_status=$($base_dir/cdp_describe_env.sh $prefix | jq -r .environment.status)
        done

        printf "\r${CHECK_MARK}  $prefix: environment status: $env_status                                   "
    else
        if [[ "$env_status" == "NOT_FOUND" ]]; then
            if [[ "$use_ccm" == "no" ]]; then
                result=$($base_dir/cdp_create_az_env.sh $prefix $credential "$region" "$key" "$sg_cidr" $create_network 2>&1 >/dev/null)
                handle_exception $? $prefix "environment creation" "$result"
            else
                result=$($base_dir/cdp_create_private_az_env.sh $prefix $credential "$region" "$key" "$sg_cidr" $create_network 2>&1 >/dev/null)
                handle_exception $? $prefix "environment creation" "$result"
            fi
        fi
        # Adding test for when env is not available yet

        env_describe_err=$($base_dir/cdp_describe_env.sh $prefix 2>&1 | grep NOT_FOUND)

        spin='🌑🌒🌓🌔🌕🌖🌗🌘'
        while [[ ${#env_describe_err} > 1 ]]; do
            i=$(((i + 1) % 8))
            printf "\r${spin:$i:1}  $prefix: environment status: WAITING_FOR_API                             "
            sleep 2
            env_describe_err=$($base_dir/cdp_describe_env.sh $prefix 2>&1 | grep NOT_FOUND)
        done

        env_status=$($base_dir/cdp_describe_env.sh $prefix | jq -r .environment.status)

        spin='🌑🌒🌓🌔🌕🌖🌗🌘'
        while [ "$env_status" != "AVAILABLE" ]; do
            i=$(((i + 1) % 8))
            printf "\r${spin:$i:1}  $prefix: environment status: $env_status                             "
            sleep 2
            env_status=$($base_dir/cdp_describe_env.sh $prefix | jq -r .environment.status)

            if [[ "$env_status" == "CREATE_FAILED" ]]; then handle_exception 2 $prefix "environment creation" "Environment creation failed; Check UI for details"; fi

        done

        printf "\r${CHECK_MARK}  $prefix: environment status: $env_status                             "
        echo ""

        # 2. IDBroker mappings
        result=$($base_dir/cdp_az_create_group_iam.sh $base_dir $prefix 2>&1 >/dev/null)

        handle_exception $? $prefix "idbroker mappings creation" "$result"

        echo "${CHECK_MARK}  $prefix: idbroker mappings set"
        echo ""
        echo ""
        echo "CDP environment for $prefix created!"
        echo ""

    fi
fi
# Creating datalake
echo "⏱  $(date +%H%Mhrs)"
echo ""
echo "Creating CDP datalake for $prefix:"
underline="▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
for ((i = 1; i <= $prefix_length; i++)); do
    underline=${underline}"▔"
done
echo ${underline}
echo ""

# 3. Datalake
dl_status=$($base_dir/cdp_describe_dl.sh $prefix 2>/dev/null | jq -r .datalake.status)
if [ ${#dl_status} -eq 0 ]; then
    dl_status="NOT_FOUND"
fi
if [[ "$dl_status" == "RUNNING" ]]; then
    printf "\r${ALREADY_DONE}  $prefix: $prefix-cdp-dl already running                             "
    echo ""
    echo ""
else

    if [[ "$dl_status" == "STOPPED" ]]; then
        dl_status=$($base_dir/cdp_describe_dl.sh $prefix | jq -r .datalake.status)
        if [ "$dl_status" != "RUNNING" ]; then
            result=$(cdp datalake start-datalake --datalake-name $prefix-cdp-dl 2>&1 >/dev/null)
            handle_exception $? $prefix "datalake start" "$result"
        fi
        dl_status=$($base_dir/cdp_describe_dl.sh $prefix | jq -r .datalake.status)

        spin='🌑🌒🌓🌔🌕🌖🌗🌘'
        while [ "$dl_status" != "RUNNING" ]; do
            i=$(((i + 1) % 8))
            printf "\r${spin:$i:1}  $prefix: datalake status: $dl_status                              "
            sleep 2
            dl_status=$($base_dir/cdp_describe_dl.sh $prefix | jq -r .datalake.status)
        done

        printf "\r${CHECK_MARK}  $prefix: datalake status: $dl_status                                 "
    else
        if [[ "$dl_status" == "NOT_FOUND" ]]; then
            result=$($base_dir/cdp_create_az_datalake.sh $prefix $RDS_HA 2>&1 >/dev/null)
            handle_exception $? $prefix "datalake creation" "$result"
        fi
        dl_status=$($base_dir/cdp_describe_dl.sh $prefix | jq -r .datalake.status)

        spin='🌑🌒🌓🌔🌕🌖🌗🌘'
        while [ "$dl_status" != "RUNNING" ]; do
            i=$(((i + 1) % 8))
            printf "\r${spin:$i:1}  $prefix: datalake status: $dl_status                              "
            sleep 2
            dl_status=$($base_dir/cdp_describe_dl.sh $prefix | jq -r .datalake.status)
            if [[ "$dl_status" == "CREATE_FAILED" ]]; then handle_exception 2 $prefix "Datalake creation" "Datalake creation failed; Check UI for details"; fi
        done

        printf "\r${CHECK_MARK}  $prefix: datalake status: $dl_status                             "
    fi

fi

# 4. Creating user workload password
result=$($base_dir/cdp_set_workload_pwd.sh ${workload_pwd} 2>&1 >/dev/null)
handle_exception $? $prefix "workload password setup" "$result"

echo ""
echo "${CHECK_MARK}  $prefix: workload password setup "
sleep $sleep_duration

# 5. Syncing users
if [[ "$SYNC_USERS" == 1 ]]; then
    $base_dir/cdp_sync_users.sh $prefix
fi

echo ""
echo ""
echo "CDP datalake for $prefix created!"
echo ""
