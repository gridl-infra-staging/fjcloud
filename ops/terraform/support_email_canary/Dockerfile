FROM public.ecr.aws/lambda/python:3.12

RUN dnf install -y bash jq \
    && pip3 install --no-cache-dir awscli \
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
