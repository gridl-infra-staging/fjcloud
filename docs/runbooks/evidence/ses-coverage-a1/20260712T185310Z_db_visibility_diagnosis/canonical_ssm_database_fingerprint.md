# Canonical SSM database fingerprint

Source: aws ssm get-parameter --name /fjcloud/staging/database_url --with-decryption.
Expected env mapping is ops/scripts/lib/generate_ssm_env.sh:45-50; API service consumes ops/systemd/fjcloud-api.service:1-20.

- endpoint: fjcloud-staging.cabwlew6jcjl.us-east-1.rds.amazonaws.com:5432/fjcloud
- sha256_16: a377bb0163e33e75
