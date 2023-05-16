#!/usr/bin/env bash

# shellcheck disable=SC2034

source "$(dirname "${BASH_SOURCE[0]}")/steps/docker.sh"
source "$(dirname "${BASH_SOURCE[0]}")/steps/gpu.sh"

function install_additional_packages {
  if [ "$#" -ne 2 ]; then
    echo "❌ Illegal number of arguments supplied to function. Terminating..."
    exit 1
  fi

  if [ -z "$1" ]; then
    echo "❌ Invalid arguments supplied to function. Terminating..."
    exit 1
  fi

  local -n script=$1
  local additional_packages=$2

  if [[ -n "${additional_packages}" ]]; then
    echo "✅ Startup script will install all additional packages"
    script="
    ${script}
    apt-get update
    apt-get install -y ${additional_packages}
    echo 'Packages successfully installed'
    "
  fi
}

function create_runner_user {
  if [ "$#" -ne 3 ]; then
    echo "❌ Illegal number of arguments supplied to function. Terminating..."
    exit 1
  fi

  local -n script=$1
  local runner_user=$2
  local runner_dir=$3

  echo "✅ Startup script will create a dedicated user for runner"
  script="
  ${script}
  useradd -s /bin/bash -m -d ${runner_dir} -G sudo ${runner_user}
  echo '${runner_user} ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
  echo 'User successfully created'
  "
}

function install_docker_package {
  if [ "$#" -ne 3 ]; then
    echo "❌ Illegal number of arguments supplied to function. Terminating..."
    exit 1
  fi

  local -n script=$1
  local install_docker=$2
  local runner_user=$3

  if ${install_docker}; then
    echo "✅ Startup script will install and configure Docker"

    local install_docker_packages
    install_docker_packages="$(docker_manual_install ${runner_user})"

    script="
    ${script}
    ${install_docker_packages}
    "
  else
    echo "✅ Startup script won't install Docker daemon"
  fi
}

function install_github_runner {
  if [ "$#" -ne 4 ]; then
    echo "❌ Illegal number of arguments supplied to function. Terminating..."
    exit 1
  fi

  local -n script=$1
  local actions_preinstalled=$2
  local runner_dir=$3
  local runner_ver=$4

  if ${actions_preinstalled}; then
    echo "✅ Startup script won't install GitHub Actions (pre-installed)"
    script="
    ${script}
    cd ${runner_dir}/actions-runner
    "
  else
    echo "✅ Startup script will install GitHub Actions"
    script="
    ${script}
    mkdir -p ${runner_dir}/actions-runner
    cd ${runner_dir}/actions-runner
    curl -o actions-runner-linux-x64-${runner_ver}.tar.gz -L https://github.com/actions/runner/releases/download/v${runner_ver}/actions-runner-linux-x64-${runner_ver}.tar.gz
    tar xzf ./actions-runner-linux-x64-${runner_ver}.tar.gz
    ./bin/installdependencies.sh
    "
  fi
}

function install_gpu_driver {
  if [ "$#" -ne 5 ]; then
    echo "❌ Illegal number of arguments supplied to function. Terminating..."
    exit 1
  fi

  local -n script=$1
  local -n runner_metadata=$2
  local accelerator=$3
  local runner_user=$4
  local image_project=$5

  if [[ -n ${accelerator} ]]; then
    # define allowed image projects
    local dl_image_project="deeplearning-platform-release"
    local base_image_projects=("debian-cloud" "ubuntu-os-cloud")

    if [[ -n ${image_project} ]] && [ ${image_project} = ${dl_image_project} ]; then
      echo "✅ Startup script will install GPU drivers on Deep Learning VM"
      runner_metadata="install-nvidia-driver=True"
    elif [[ -n ${image_project} ]] && [[ $(echo "${base_image_projects[@]}" | grep -ow "${image_project}" | wc -w) != 0 ]]; then
      echo "✅ Startup script will install GPU drivers on a base VM"
      local install_gpu_drivers
      install_gpu_drivers="$(cuda_manual_install ${runner_user})"

      script="
      ${script}
      ${install_gpu_drivers}
      "
    else
      echo "❌ Accelerators should only be used with Deep Learning images from project ${dl_image_project} or
      with base images from a project in [${base_image_projects[*]}]. Terminating..."
      exit 1
    fi

    local check_driver_status
    check_driver_status="$(check_gpu_driver)"

    script="
    ${script}
    ${check_driver_status}
    "
  else
    echo "✅ Startup script won't install GPU drivers as there are no accelerators configured"
  fi
}

function start_runner {
  if [ "$#" -ne 7 ]; then
    echo "❌ Illegal number of arguments supplied to function. Terminating..."
    exit 1
  fi

  local -n script=$1
  local vm_id=$2
  local runner_token=$3
  local runner_user=$4
  local ephemeral_flag=$5
  local machine_zone=$6
  local project_id=$7

  script="
  ${script}
  gcloud compute instances add-labels ${vm_id} --zone=${machine_zone} --labels=gh_ready=0
  sudo -u ${runner_user} ./config.sh --url https://github.com/${GITHUB_REPOSITORY} --token ${runner_token} --labels ${vm_id} --unattended ${ephemeral_flag} --disableupdate
  sudo -u ${runner_user} sudo ./svc.sh install
  sudo -u ${runner_user} sudo ./svc.sh start
  sudo rm -rf _diag _work

  gcloud compute instances add-labels ${vm_id} --zone=${machine_zone} --labels=gh_ready=1
  # 3 days represents the max workflow runtime. This will shutdown the instance if everything else fails.
  echo \"gcloud --quiet compute instances delete ${vm_id} --zone=${machine_zone} --project=${project_id}\" | at now + 3 days
  "
}