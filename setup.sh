#!/bin/sh

# Set-up steps for the project on a fresh ubuntu lightsail instance.

git clone --depth=1 --recurse-submodules https://github.com/laytan/odin-playground
sudo snap install docker
docker build -t odin-playground:latest .

git clone --depth=1 https://github.com/odin-lang/Odin ~/odin

sudo apt-get update
sudo apt-get install -y --no-install-recommends make clang llvm-14 llvm-14-dev supervisor libmysqlclient-dev
sudo rm -rf /var/lib/apt/lists/*

cd ~/odin
make

cd ~/odin-playground

~/odin/odin build . -o:speed -define:DB_HOST= -define:DB_USERNAME= -define:DB_PASSWORD= -define:DB_NAME=- -define:PORT=80

sudo supervisord -c supervisord.conf
