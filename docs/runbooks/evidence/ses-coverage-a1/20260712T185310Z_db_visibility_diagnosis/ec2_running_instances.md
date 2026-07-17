# Running staging API EC2 targets

Source command: aws ec2 describe-instances filtered to Name=fjcloud-api-staging and running state; SSM ping from aws ssm describe-instance-information.

| instance_id | ssm_ping_status | private_ip | launch_time | name_tag |
| --- | --- | --- | --- | --- |
| i-0fbc6d6bbbc8bdc6d | Online | 10.0.10.178 | 2026-05-21T01:51:19+00:00 | fjcloud-api-staging |

Count: 1. The helper at scripts/launch/ssm_exec_staging.sh:35-40 selects Reservations[0].Instances[0], so count > 1 is selection drift risk.
