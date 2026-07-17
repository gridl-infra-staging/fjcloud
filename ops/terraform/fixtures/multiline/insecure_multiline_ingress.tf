resource "aws_vpc_security_group_ingress_rule" "fixture_multiline_public" {
  security_group_id = "sg-1234567890"
  cidr_blocks = [
    "0.0.0.0/0",
  ]
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
}
