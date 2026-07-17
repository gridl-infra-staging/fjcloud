resource "aws_vpc_security_group_ingress_rule" "flapjack_public_data_plane" {
  security_group_id = "sg-1234567890"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 7700
  to_port           = 7700
  ip_protocol       = "udp"
}
