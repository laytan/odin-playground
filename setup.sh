#!/bin/sh

# Script to setup the ubuntu VM from scratch, to being able to deploy.

# Install dependencies for installing docker.
sudo apt-get update
sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg

# Install docker apt repository.
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=\"$(dpkg --print-architecture)\" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \"$(. /etc/os-release && echo \"$VERSION_CODENAME\")\" stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install docker, odin and playground dependencies.
sudo apt-get update
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin make clang llvm-14 llvm-14-dev supervisor libmysqlclient-dev

# Install gvisor/runsc docker runtime.
curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null
sudo apt-get update
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y runsc

# Add the ubuntu user to the docker user group.
sudo usermod -aG docker ubuntu
sudo su ubuntu
newgrp

# Clone and compile Odin.
git clone --depth=1 https://github.com/odin-lang/Odin /home/ubuntu/odin
cd /home/ubuntu/odin
make

# Clone playground and build docker image.
git clone --depth=1 --recurse-submodules https://github.com/laytan/odin-playground /home/ubuntu/odin-playground
cd /home/ubuntu/odin-playground
docker build -t odin-playground:latest .
