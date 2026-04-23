resource "aws_security_group" "fixture_inline_sg" {
  name        = "fixture-inline-sg"
  description = "Fixture SG with insecure inline ingress"
  vpc_id      = "vpc-1234567890"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
