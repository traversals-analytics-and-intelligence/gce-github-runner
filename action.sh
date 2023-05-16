#!/usr/bin/env bash

# shellcheck disable=SC2016
# shellcheck disable=SC2002
# shellcheck disable=SC2046

ACTION_DIR="$(cd $(dirname "${BASH_SOURCE[0]}") >/dev/null 2>&1 && pwd)"

function usage {
  echo "Usage: ${0} --command=[start|stop] <arguments>"
}

function safety_on {
  set -o errexit -o pipefail -o noclobber -o nounset
}

function safety_off {
  set +o errexit +o pipefail +o noclobber +o nounset
}

source "${ACTION_DIR}/vendor/getopts_long.sh"
source "${ACTION_DIR}/vendor/workflow.sh"

command=
token=
project_id=
service_account_key=
runner_ver=
machine_zone=
machine_type=
disk_size=
runner_service_account=
image_project=
image=
image_family=
scopes=
shutdown_timeout=
preemptible=
ephemeral=
actions_preinstalled=
name_prefix=
install_docker=
accelerator_type=
accelerator_count=
additional_packages="at"

OPTLIND=1
while getopts_long :h opt \
  command required_argument \
  token required_argument \
  project_id required_argument \
  service_account_key required_argument \
  runner_ver required_argument \
  machine_zone required_argument \
  machine_type required_argument \
  disk_size optional_argument \
  runner_service_account optional_argument \
  image_project optional_argument \
  image optional_argument \
  image_family optional_argument \
  scopes required_argument \
  shutdown_timeout required_argument \
  preemptible required_argument \
  ephemeral required_argument \
  actions_preinstalled required_argument \
  name_prefix optional_argument \
  install_docker optional_argument \
  accelerator_type optional_argument \
  accelerator_count optional_argument \
  help no_argument "" "$@"; do
  case "$opt" in
  command)
    command=$OPTLARG
    ;;
  token)
    token=$OPTLARG
    ;;
  project_id)
    project_id=$OPTLARG
    ;;
  service_account_key)
    service_account_key="$OPTLARG"
    ;;
  runner_ver)
    runner_ver=$OPTLARG
    ;;
  machine_zone)
    machine_zone=$OPTLARG
    ;;
  machine_type)
    machine_type=$OPTLARG
    ;;
  disk_size)
    disk_size=${OPTLARG-$disk_size}
    ;;
  runner_service_account)
    runner_service_account=${OPTLARG-$runner_service_account}
    ;;
  image_project)
    image_project=${OPTLARG-$image_project}
    ;;
  image)
    image=${OPTLARG-$image}
    ;;
  image_family)
    image_family=${OPTLARG-$image_family}
    ;;
  scopes)
    scopes=$OPTLARG
    ;;
  shutdown_timeout)
    shutdown_timeout=$OPTLARG
    ;;
  preemptible)
    preemptible=$OPTLARG
    ;;
  ephemeral)
    ephemeral=$OPTLARG
    ;;
  actions_preinstalled)
    actions_preinstalled=$OPTLARG
    ;;
  name_prefix)
    name_prefix=${OPTLARG-$name_prefix}
    ;;
  install_docker)
    install_docker=$OPTLARG
    ;;
  accelerator_type)
    accelerator_type=$OPTLARG
    ;;
  accelerator_count)
    accelerator_count=$OPTLARG
    ;;
  h | help)
    usage
    exit 0
    ;;
  :)
    printf >&2 '%s: %s\n' "${0##*/}" "$OPTLERR"
    usage
    exit 1
    ;;
  esac
done

function gcloud_auth {
  # NOTE: when --project is specified, it updates the config
  echo ${service_account_key} | gcloud --project ${project_id} --quiet auth activate-service-account --key-file - &>/dev/null
  echo "✅ Successfully configured gcloud."
}

function start_vm {
  echo "Starting GCE VM ..."
  if [[ -z "${service_account_key}" ]] || [[ -z "${project_id}" ]]; then
    echo "Won't authenticate gcloud. If you wish to authenticate gcloud provide both service_account_key and project_id."
  else
    echo "Will authenticate gcloud."
    gcloud_auth
  fi

  RUNNER_TOKEN=$(curl -S -s -XPOST \
    -H "authorization: Bearer ${token}" \
    https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runners/registration-token |
    jq -r .token)
  echo "✅ Successfully got the GitHub Runner registration token"

  VM_ID="gce-gh-runner-${name_prefix}-${GITHUB_RUN_ID}-${RANDOM}"
  service_account_flag=$([[ -z "${runner_service_account}" ]] || echo "--service-account=${runner_service_account}")
  image_project_flag=$([[ -z "${image_project}" ]] || echo "--image-project=${image_project}")
  image_flag=$([[ -z "${image}" ]] || echo "--image=${image}")
  image_family_flag=$([[ -z "${image_family}" ]] || echo "--image-family=${image_family}")
  disk_size_flag=$([[ -z "${disk_size}" ]] || echo "--boot-disk-size=${disk_size}")
  preemptible_flag=$([[ "${preemptible}" == "true" ]] && echo "--preemptible" || echo "")
  ephemeral_flag=$([[ "${ephemeral}" == "true" ]] && echo "--ephemeral" || echo "")
  accelerator=$([[ -n "${accelerator_type}" ]] &&
    echo "--accelerator type=${accelerator_type},count=${accelerator_count} --maintenance-policy=TERMINATE" ||
    echo "")

  echo "The new GCE VM will be ${VM_ID}"

  startup_script="#!/bin/bash"
  runner_user="runner"
  runner_dir="/home/${runner_user}"

  metadata=""

  # Install mandatory packages
  install_additional_packages startup_script ${additional_packages}

  # Create dedicated user
  create_runner_user startup_script ${runner_user} ${runner_dir}

  # Install docker if desired
  install_docker_package startup_script ${install_docker} ${runner_user}

  # Install GitHub actions if desired
  install_github_runner startup_script ${actions_preinstalled} ${runner_dir} ${runner_ver}

  # Install GPU drivers if accelerator option is set
  install_gpu_driver startup_script ${accelerator} ${runner_user} metadata ${image_project}

  # Run service
  start_runner \
    startup_script \
    ${VM_ID} \
    ${RUNNER_TOKEN} \
    ${runner_user} \
    ${ephemeral_flag} \
    ${machine_zone} \
    ${project_id}

  # Write startup script to a file
  startup_script_path=/tmp/startup-script.sh
  if [[ -n ${startup_script} ]]; then
    printf "%s\n" "${startup_script}" > ${startup_script_path}
    metadata_from_file="startup-script=${startup_script_path}"
  fi

  # Prepare metadata
  if [[ -n ${metadata} ]]; then
    metadata=$(echo "--metadata=${metadata}")
  fi

  # Prepare metadata from file
  if [[ -n ${startup_script} ]]; then
    metadata_from_file=$(echo "--metadata-from-file=${metadata_from_file}")
  fi

  echo "ℹ️ Metadata:"
  echo "${metadata}"

  echo "ℹ️ Metadata from file:"
  echo "${metadata_from_file}"

  gcloud compute instances create ${VM_ID} \
    --zone=${machine_zone} \
    ${disk_size_flag} \
    --machine-type=${machine_type} \
    --scopes=${scopes} \
    ${service_account_flag} \
    ${image_project_flag} \
    ${image_flag} \
    ${image_family_flag} \
    ${preemptible_flag} \
    ${accelerator} \
    ${metadata} \
    ${metadata_from_file} \
    --labels=gh_ready=0 &&
    echo "label=${VM_ID}" >> $GITHUB_OUTPUT

  safety_off
  while ((i++ < 90)); do
    GH_READY=$(gcloud compute instances describe ${VM_ID} --zone=${machine_zone} --format='json(labels)' | jq -r .labels.gh_ready)
    if [[ $GH_READY == 1 ]]; then
      break
    fi
    echo "${VM_ID} not ready yet, waiting 10 secs ..."
    sleep 10
  done
  if [[ $GH_READY == 1 ]]; then
    echo "✅ ${VM_ID} ready ..."
  else
    echo "❌ Waited 15 minutes for ${VM_ID}, without luck, deleting ${VM_ID} ..."
    gcloud --quiet compute instances delete ${VM_ID} --zone=${machine_zone} --project=${project_id}
    exit 1
  fi
}

function stop_vm {
  # NOTE: this function runs on the GCE VM
  echo "Stopping GCE VM ..."

  if [[ -z "${service_account_key}" ]] || [[ -z "${project_id}" ]]; then
    echo "Won't authenticate gcloud. If you wish to authenticate gcloud provide both service_account_key and project_id."
  else
    echo "Will authenticate gcloud."
    gcloud_auth
  fi

  NAME=$(curl -S -s -X GET http://metadata.google.internal/computeMetadata/v1/instance/name -H 'Metadata-Flavor: Google')
  ZONE=$(curl -S -s -X GET http://metadata.google.internal/computeMetadata/v1/instance/zone -H 'Metadata-Flavor: Google')
  echo "✅ Self deleting $NAME in $ZONE in ${shutdown_timeout} seconds ..."
  echo "sleep ${shutdown_timeout}; gcloud --quiet compute instances delete $NAME --zone=$ZONE --project=${project_id}" | env at now
}

safety_on
case "$command" in
start)
  start_vm
  ;;
stop)
  stop_vm
  ;;
*)
  echo "Invalid command: \`${command}\`, valid values: start|stop" >&2
  usage
  exit 1
  ;;
esac
