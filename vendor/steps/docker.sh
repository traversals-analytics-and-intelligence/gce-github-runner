#!/usr/bin/env bash

# shellcheck disable=SC2016

docker_manual_install() {
  if [ -z "$1" ]; then
    echo "❌ No argument supplied to Docker installation. Terminating..."
    exit 1
  fi

  runner_user=$1

  echo '
  if [[ $(grep -Ei "debian|ubuntu" /etc/*release) ]]; then
    if [ $(command -v docker) ]; then
      echo "✅ Docker is already installed. Skipping installation..."
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
      echo "✅ Docker successfully installed"

      # Enable docker.service
      systemctl is-active --quiet docker.service || systemctl start docker.service
      systemctl is-enabled --quiet docker.service || systemctl enable docker.service

      # Docker daemon takes time to come up after installing
      sleep 5
      docker info
      echo "✅ Docker successfully configured"
    fi

    echo "Configuring runner user for Docker daemon..."
    usermod -aG docker '"${runner_user}"'
    systemctl restart docker.service
    echo "✅ User successfully added to Docker group"
  else
    echo "❌ For Docker, please use an image based on Debian. Terminating..."
    exit 1
  fi
  '
}