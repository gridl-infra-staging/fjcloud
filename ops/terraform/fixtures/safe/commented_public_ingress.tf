resource "aws_vpc_security_group_ingress_rule" "comment_only" {
  security_group_id = "sg-1234567890"
  # cidr_ipv4         = "0.0.0.0/0"
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
}
