provider "aws" {
  region  = "eu-central-1"
}

resource "aws_lightsail_instance" "odin_playground" {
  name = "odin_playground"
  availability_zone = "eu-central-1a"
  blueprint_id = "ubuntu_22_04"
  bundle_id = "micro_2_0"
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
