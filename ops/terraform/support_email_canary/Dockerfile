FROM public.ecr.aws/lambda/python:3.12

# Install AWS CLI v2 (not v1). The canary scripts (scripts/lib/test_inbox_helpers.sh,
# scripts/launch/ses_deliverability_evidence.sh) standardize on v2-only flags
# such as `--no-cli-pager`; pip-installed `awscli` is v1 and rejects the
# flag with `Unknown options: --no-cli-pager`, which silently failed every
# `sesv2 send-email` call this canary makes. The Lambda image is arm64
# (see aws_lambda_function.architectures), so pull the aarch64 v2 bundle.
RUN dnf install -y bash jq unzip \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && dnf remove -y unzip \
    && dnf clean all

WORKDIR /opt/fjcloud

COPY scripts/canary/support_email_deliverability.sh /opt/fjcloud/scripts/canary/support_email_deliverability.sh
COPY scripts/validate_inbound_email_roundtrip.sh /opt/fjcloud/scripts/validate_inbound_email_roundtrip.sh
COPY scripts/lib/alert_dispatch.sh /opt/fjcloud/scripts/lib/alert_dispatch.sh
COPY scripts/lib/validation_json.sh /opt/fjcloud/scripts/lib/validation_json.sh
COPY scripts/lib/test_inbox_helpers.sh /opt/fjcloud/scripts/lib/test_inbox_helpers.sh
COPY scripts/lib/parse_inbound_auth_headers.py /opt/fjcloud/scripts/lib/parse_inbound_auth_headers.py
COPY ops/terraform/support_email_canary/lambda_handler.py /var/task/lambda_handler.py

RUN chmod +x /opt/fjcloud/scripts/canary/support_email_deliverability.sh \
    /opt/fjcloud/scripts/validate_inbound_email_roundtrip.sh

CMD ["lambda_handler.handler"]
