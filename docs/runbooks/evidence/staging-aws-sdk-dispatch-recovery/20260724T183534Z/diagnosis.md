root_cause=aws_sdk_dispatch_failure_in_live_api_process_not_reproduced_by_cli_or_signup
service_user=fjcloud
instance_id=i-0fbc6d6bbbc8bdc6d
image_id=ami-0df77f1c103ce1be7
deployed_sha=125abd2359de01cc74269ea37619eb2fa105b39f
registration_nonce=stage1aws2026072418415618421
registration_status=201
cleanup_remaining_rows=0

classification=non_green_guard_failed_registration_503_not_reproduced_current_staging

summary:
- The Stage 1 live-failure receipt pinned public run 30113123441 and mirror SHA 125abd2359de01cc74269ea37619eb2fa105b39f with /auth/register returning 503 for verification delivery.
- Current staging is the exact single running EC2 target i-0fbc6d6bbbc8bdc6d, and /version reports mirror_sha=125abd2359de01cc74269ea37619eb2fa105b39f.
- The one allowed fresh public registration returned HTTP 201, not the expected 503. The created test customer was cleaned up through admin soft-delete plus hard-erase, and the post-cleanup matching-row count is 0.
- Therefore the frozen signup failure is not currently reproducible from the public seam, and this diagnosis must not be treated as a green repair receipt.

supported_current_root_cause:
- Live fjcloud-api journal evidence in registration_journal_broader_filtered_redacted.txt shows the running service process still emits AWS SDK SSM GetParameter "dispatch failure" during scheduler work.
- The same EC2 instance role from the exact fjcloud Unix user can resolve DNS, route over IPv4, reach IMDSv2, obtain IAM-role credentials, call STS successfully, and read SSM parameter metadata through AWS CLI; root host context matches.
- This supports a current root cause class of application-process AWS SDK dispatch/runtime behavior, not broken EC2 identity, missing credentials, DNS failure, IPv4 routing failure, proxy configuration, IMDSv2 failure, AWS SSM endpoint outage, or generic host egress failure.

competing_causes_ruled_out:
- identity: remote_identity_service.txt proves SSM target i-0fbc6d6bbbc8bdc6d matches preflight; systemctl shows User=fjcloud, Group=fjcloud, active/running MainPID.
- credentials: remote_service_user_vs_host_probes_concise.txt shows aws debug credential-provider discovery finds fjcloud-instance-role via IMDS, and sts_identity exits 0 in both fjcloud and host contexts.
- DNS: SES, CloudWatch, STS, Discord, and GitHub names resolve for fjcloud and host contexts.
- IPv4 routing: all target IPv4 routes resolve through ens5 for fjcloud and host contexts.
- IPv6 routing: IPv6 is unavailable, but IPv4 succeeds and AWS CLI STS/SSM calls succeed; this is not a generic routing blocker.
- proxy: service process and fjcloud shell proxy boolean sections are empty.
- IMDSv2: token and role-name probes return role_name_present=YES for fjcloud and host contexts.
- AWS service endpoint: AWS CLI STS and SSM metadata calls succeed from the instance role; SES and CloudWatch read probes fail with explicit AccessDenied, not transport dispatch.
- IAM permission: read-only SES account/configuration-set and CloudWatch ListMetrics are not allowed for the instance role, but SSM metadata and STS succeed; the observed live service SSM failure is dispatch-class, not AccessDenied.

evidence_files:
- 00_stage_context.txt
- local_sts_identity_redacted.json
- preflight_instance_redacted.json
- remote_identity_service.txt
- remote_service_user_vs_host_probes_concise.txt
- remote_ssm_known_answer_probe.txt
- remote_without_region_probe.txt
- registration_markers.txt
- register_response_redacted.json
- registration_cleanup_performed.txt
- registration_journal_broader_filtered_redacted.txt
