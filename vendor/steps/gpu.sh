#!/usr/bin/env bash

# shellcheck disable=SC2016

cuda_manual_install() {
  if [ -z "$1" ]; then
    echo "❌ No argument supplied to CUDA installation. Terminating..."
    exit 1
  fi

  runner_user=$1

  echo '
  if [[ $(grep -Ei "debian|ubuntu" /etc/*release) ]]; then
    if [ $(command -v nvidia-smi) ]; then
      echo "✅ GPU drivers are already installed. Skipping installation..."
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
        version=$(echo $VERSION_ID | sed -e "s/\.//g")
        distro=$ID$version
      fi

      echo "Installing GPU drivers for Linux distribution $distro"

      curl -fsSL -O https://developer.download.nvidia.com/compute/cuda/repos/$distro/x86_64/cuda-keyring_1.0-1_all.deb
      dpkg -i cuda-keyring_1.0-1_all.deb

      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y cuda

      echo "✅ GPU drivers successfully installed"
      sudo -u '"${runner_user}"' export PATH=/usr/local/cuda/bin${PATH:+:${PATH}}
      echo "✅ GPU drivers successfully configured"
    fi
  else
    echo "❌ For GPU drivers, please use an image based on Debian. Terminating..."
    exit 1
  fi
  '
}

check_gpu_driver() {
  echo '
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
    echo "✅ GPU driver is ready..."
  else
    echo "❌ Waited 5 minutes for the GPU driver to be ready without luck. Terminating..."
    exit 1
  fi
  '
}
