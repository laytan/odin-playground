provider "aws" {
  region  = "eu-central-1"
}

# You probably need to attach the static IP in the lightsail interface, this doesn't happen automatically most of the time.
resource "aws_lightsail_instance" "odin_playground" {
  name = "odin_playground"
  availability_zone = "eu-central-1a"
  blueprint_id = "ubuntu_22_04"
  bundle_id = "micro_2_0"
  # Runs the following commands to set up the instance, ready for deploys from the GitHub workflow.
  # Give it some time after the instance is created because this takes time, progress can't be seen easily.
  # This does the following:
  # - install installation dependencies for docker: ca-certificates curl gnupg
  # - install a recent apt list for docker
  # - install docker and odin dependencies
  # - install gvisor and set it as the docker runtime
  # - add ubuntu to the docker group
  # - clone odin and compile it
  # - clone playground and build the "sandbox" dockerfile
  # TODO: This is fucking disgusting.
  user_data = "sudo apt-get update && sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg && sudo install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg && sudo chmod a+r /etc/apt/keyrings/docker.gpg && echo \"deb [arch=\"$(dpkg --print-architecture)\" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \"$(. /etc/os-release && echo \"$VERSION_CODENAME\")\" stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && sudo apt-get update && DEBIAN_FRONTEND=noninteractive sudo apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin make clang llvm-14 llvm-14-dev supervisor libmysqlclient-dev && curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main\" | sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null && DEBIAN_FRONTEND=noninteractive sudo apt-get update && sudo apt-get install -y runsc && sudo usermod -aG docker ubuntu && sudo su ubuntu && newgrp && git clone --depth=1 https://github.com/odin-lang/Odin /home/ubuntu/odin && cd /home/ubuntu/odin && make && git clone --depth=1 --recurse-submodules https://github.com/laytan/odin-playground /home/ubuntu/odin-playground && cd /home/ubuntu/odin-playground && sudo docker build -t odin-playground:latest ."
}

resource "aws_lightsail_instance_public_ports" "odin_playground" {
  instance_name = aws_lightsail_instance.odin_playground.name

  port_info {
    protocol = "tcp"
    from_port = 80
    to_port = 80
  }

  port_info {
    protocol = "tcp"
    from_port = 443
    to_port = 443
  }

  port_info {
    protocol = "tcp"
    from_port = 22
    to_port = 22
  }
}

resource "aws_lightsail_static_ip" "odin_playground" {
  name = "odin_playground_static_ip"
}

resource "aws_lightsail_static_ip_attachment" "odin_playground" {
  static_ip_name = aws_lightsail_static_ip.odin_playground.name
  instance_name = aws_lightsail_instance.odin_playground.name
}
