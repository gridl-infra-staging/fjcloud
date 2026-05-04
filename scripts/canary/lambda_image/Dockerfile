# Customer-loop canary Lambda image packaging owner.
# This image intentionally delegates runtime behavior to
# scripts/canary/customer_loop_synthetic.sh.

FROM public.ecr.aws/lambda/provided:al2023

# why: lambda/provided:al2023 ships curl-minimal; installing full `curl`
# triggers a package conflict that breaks the build. curl-minimal already
# provides the curl binary the canary script invokes. If a future script
# needs a feature curl-minimal lacks, swap to `--allowerasing curl`.
RUN dnf install -y awscli bash python3 \
    && dnf clean all \
    && rm -rf /var/cache/dnf

WORKDIR /workspace

COPY scripts/ ./scripts/
COPY scripts/canary/lambda_image/bootstrap /var/runtime/bootstrap

RUN chmod 0755 /var/runtime/bootstrap ./scripts/canary/customer_loop_synthetic.sh
