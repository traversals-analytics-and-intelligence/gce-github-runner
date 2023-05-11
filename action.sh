#!/usr/bin/env bash

# shellcheck disable=SC2016
# shellcheck disable=SC2002

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
  echo "✅ Startup script will install all necessary packages"
  startup_script="
    ${startup_script}
    apt-get update
    apt-get install -y ${additional_packages}
    echo 'Packages successfully installed'
  "

  # Create dedicated user
  echo "✅ Startup script will create a dedicated user for runner"
  startup_script="
    ${startup_script}
    useradd -s /bin/bash -m -d ${runner_dir} -G sudo ${runner_user}
    echo '${runner_user} ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
    echo 'User successfully created'
    "

  # Install docker if desired
  if $install_docker; then
    echo "✅ Startup script will install and configure Docker"

    install_docker_packages='
    if [[ $(grep -Ei "debian|ubuntu" /etc/*release) ]]; then
      if [ -x $(command -v docker) ]; then
        echo "Docker is already installed. Skipping installation..."
      else
        apt-get install -y ca-certificates curl gnupg

        docker_url=
        docker_url_gpg=

        if [[ $(grep -Ei "ID=debian" /etc/*release) ]]; then
          # Debian OS
          docker_url=https://download.docker.com/linux/debian
          docker_url_gpg=https://download.docker.com/linux/debian/gpg
        elif [[ $(grep -Ei "ID=ubuntu" /etc/*release) ]]; then
          # Ubuntu OS
          docker_url=https://download.docker.com/linux/ubuntu
          docker_url_gpg=https://download.docker.com/linux/ubuntu/gpg
        fi

        docker_packages="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

        echo "Docker is not installed. Installing Docker daemon..."
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL $docker_url_gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $docker_url $(source /etc/os-release && echo $VERSION_CODENAME) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update
        apt-get install -y $docker_packages
        echo "Docker successfully installed"

        # Enable docker.service
        systemctl is-active --quiet docker.service || systemctl start docker.service
        systemctl is-enabled --quiet docker.service || systemctl enable docker.service

        # Docker daemon takes time to come up after installing
        sleep 5
        docker info
        echo "Docker successfully installed and configured"
      fi
      '"
      echo 'Configuring runner user for Docker daemon...'
      usermod -aG docker ${runner_user}
      systemctl restart docker.service
      echo 'User successfully added to Docker group'
      "'
    else
      echo "For Docker, please use an image based on Debian. Terminating..."
      exit 1
    fi
    '

    startup_script="
    ${startup_script}
    ${install_docker_packages}
    "
  else
    echo "✅ Startup script won't install Docker daemon"
  fi

  # Install GitHub actions if desired
  if $actions_preinstalled; then
    echo "✅ Startup script won't install GitHub Actions (pre-installed)"
    startup_script="
    ${startup_script}
    cd ${runner_dir}/actions-runner
    "
  else
    echo "✅ Startup script will install GitHub Actions"
    startup_script="
    ${startup_script}
    mkdir -p ${runner_dir}/actions-runner
    cd ${runner_dir}/actions-runner
    curl -o actions-runner-linux-x64-${runner_ver}.tar.gz -L https://github.com/actions/runner/releases/download/v${runner_ver}/actions-runner-linux-x64-${runner_ver}.tar.gz
    tar xzf ./actions-runner-linux-x64-${runner_ver}.tar.gz
    ./bin/installdependencies.sh
    "
  fi

  # Install GPU drivers if accelerator option is set
  if [[ -n ${accelerator} ]]; then
    # define allowed image projects
    dl_image_project="deeplearning-platform-release"
    base_image_projects=("debian-cloud" "ubuntu-os-cloud")

    if [[ -n ${image_project} ]] && [ ${image_project} = ${dl_image_project} ]; then
      echo "✅ Startup script will install GPU drivers on Deep Learning VM"
      metadata="install-nvidia-driver=True"
    elif [[ -n ${image_project} ]] && [[ $(echo "${base_image_projects[@]}" | grep -ow "${image_project}" | wc -w) != 0 ]]; then
      echo "✅ Startup script will install GPU drivers on a base VM"
      install_gpu_drivers='
      if [[ $(grep -Ei "debian|ubuntu" /etc/*release) ]]; then
        if [ -x $(command -v nvidia-smi) ]; then
          echo "GPU drivers are already installed. Skipping installation..."
        else
          apt-get install -y linux-headers-$(uname -r) dkms

          distro=

          if [[ $(grep -Ei "ID=debian" /etc/*release) ]]; then
            # Debian OS
            apt-get install -y software-properties-common
            add-apt-repository contrib
            apt-key del 7fa2af80

            source /etc/os-release
            distro=$ID$VERSION_ID

          elif [[ $(grep -Ei "ID=ubuntu" /etc/*release) ]]; then
            # Ubuntu OS
            apt-key del 7fa2af80

            source /etc/os-release
            version=echo $VERSION_ID | sed -e "s/\.//g"
            distro=$ID$version
          fi

          echo "Installing GPU drivers for Linux distribution $distro"

          curl -fsSL -O https://developer.download.nvidia.com/compute/cuda/repos/${distro}/x86_64/cuda-keyring_1.0-1_all.deb
          dpkg -i cuda-keyring_1.0-1_all.deb

          apt-get update
          DEBIAN_FRONTEND=noninteractive apt-get install -y cuda

          export PATH=/usr/local/cuda/bin${PATH:+:${PATH}}
        fi
      else
        echo "For GPU drivers, please use an image based on Debian. Terminating..."
        exit 1
      fi
      '

      startup_script="
      ${startup_script}
      ${install_gpu_drivers}
      "
    else
      echo "❌ Accelerators should only be used with Deep Learning images from project ${dl_image_project} or
      with base images from a project in [${base_image_projects[*]}]. Terminating..."
      exit 1
    fi

    check_driver_status='
    GPU_READY=0
    while (( i++ < 30)); do
      gpu_status=$(command -v nvidia-smi && nvidia-smi)
      gpu_retval=$?

      if [[ $gpu_retval == 0 ]]; then
        GPU_READY=1
        break
      fi

      echo "GPU driver not ready yet, waiting for 10 seconds..."
      sleep 10
    done
    if [[ $GPU_READY == 1 ]]; then
      echo "GPU driver is ready..."
    else
      echo "Waited 5 minutes for the GPU driver to be ready without luck. Terminating..."
      exit 1
    fi
    '

    startup_script="
    ${startup_script}
    ${check_driver_status}
    "

  else
    echo "✅ Startup script won't install GPU drivers as there are no accelerators configured"
  fi

  # Run service
  startup_script="
    ${startup_script}
    gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=0
    sudo -u ${runner_user} ./config.sh --url https://github.com/${GITHUB_REPOSITORY} --token ${RUNNER_TOKEN} --labels ${VM_ID} --unattended ${ephemeral_flag} --disableupdate
    sudo -u ${runner_user} sudo ./svc.sh install
    sudo -u ${runner_user} sudo ./svc.sh start
    sudo rm -rf _diag _work

    gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=1
    # 3 days represents the max workflow runtime. This will shutdown the instance if everything else fails.
    echo \"gcloud --quiet compute instances delete ${VM_ID} --zone=${machine_zone} --project=${project_id}\" | at now + 3 days
    "

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

  # print startup script (only for temporary testing)
  echo "ℹ️ Startup script:"
  cat ${startup_script_path} | head -n 15

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
    echo "label=${VM_ID}" >>$GITHUB_OUTPUT

  safety_off
  while ((i++ < 60)); do
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
    echo "Waited 10 minutes for ${VM_ID}, without luck, deleting ${VM_ID} ..."
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
