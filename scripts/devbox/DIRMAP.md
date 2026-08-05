<!-- [scrai:start] -->
## devbox

| File | Summary |
| --- | --- |
| cloud_init.yaml | First-boot provisioning payload for the LOCAL-phase devbox. Installs docker, the Rust/Node toolchains and Playwright's headless Chromium system dependencies. Deliberately installs no cloud provider CLI and carries no secrets: it ships as EC2 user-data and to the public mirror. |
| provision_devbox.sh | Provisions/terminates the ephemeral Linux devbox that runs the browser suite and `scripts/local-ci.sh --fast` off the operator's Mac, removing the repo-wide fast-lock contention. Refuses world-open SSH CIDRs and never attaches an IAM instance profile, so the box holds no AWS credentials. |
<!-- [scrai:end] -->
