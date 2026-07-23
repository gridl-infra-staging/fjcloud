#!/usr/bin/env bash
#
# probe_fleet_dataplane.sh -- ADR and pure-classifier boundary
#
# Purpose
# -------
# This file is the ADR of record and executable deterministic classifier for
# the managed EC2 fleet/data-plane live-state row. It performs classification
# and token emission from one supplied evidence file, but deliberately performs
# no collection or AWS/API call.
#
# Required environments are staging and prod. A green result means more than
# "an instance exists": every required read completed, the attributed managed
# fleet is non-empty and current, every observed instance is running with a
# fresh SSM signal, and each environment returned a known object from a real
# authenticated search through fjcloud's API-to-Flapjack proxy.
#
# Ownership boundaries
# --------------------
# * scripts/probe_live_state.sh remains the only owner of SUMMARY rows,
#   add_row, raw-manifest registration, and integrated-run credential
#   resolution. Its AWS_ACCOUNT_ID/AWS_OK probe is performed once before the
#   existing aws_sns_${env} and aws_ssm_${env} loops. The fleet section
#   must reuse that decision, collect one normalized evidence document,
#   register that raw document, invoke this classifier once, and map its one
#   token to the row. It must not run STS again or classify fleet facts inline.
# * This file owns only deterministic normalization/disposition of the
#   supplied evidence. It must never resolve credentials, call AWS or HTTP,
#   write a SUMMARY row, or register a raw artifact.
# * Live and fixture execution use the same normalized evidence schema. There
#   is no alternate fixture parser and no second fleet-normalization owner.
#
# Repository evidence for those owners:
# * ROADMAP.md, "Live-state probe suite has no data-plane or fleet probe",
#   requires live VM engine reachability plus a real search response and says
#   indeterminate evidence is ACTION_REQUIRED, never SKIP_NO_CREDS.
# * scripts/probe_live_state.sh owns add_row/register_raw, resolves AWS identity
#   at AWS_ACCOUNT_ID/AWS_OK, reuses it in aws_sns_${env}/aws_ssm_${env}, and
#   ranks ACTION_REQUIRED above PROBE_ERROR in
#   flapjack_build_identity_status_rank.
#
# Fleet identity and state
# ------------------------
# infra/api/src/provisioner/aws.rs is canonical. AwsVmProvisioner::build_tags
# writes Name=fj-{hostname}, customer_id, node_id, and managed-by=fjcloud.
# AwsProvisionerConfig::from_env reads AWS_AMI_ID, AWS_SECURITY_GROUP_IDS,
# AWS_SUBNET_ID, AWS_KEY_PAIR_NAME, and optional AWS_INSTANCE_PROFILE_NAME; it
# has no region or environment field. Provider construction supplies the
# region-specific EC2 client. create_vm uses the configured AMI and subnet.
# There is no EC2 environment tag; ops/terraform/compute/main.tf's Env tag
# belongs to the API host, not to provisioned customer VMs, and must not be
# used here. cloud_init.rs renders guest runtime configuration but establishes
# no EC2 environment identity.
#
# Collection starts with the exact EC2 filter
# Name=tag:managed-by,Values=fjcloud and retains the complete paginated
# Reservations[].Instances[] response needed for InstanceId, State.Name,
# ImageId, SubnetId, and the four canonical tags. It intentionally applies no
# state filter: terminal/transitional records that EC2 still returns are health
# evidence. Name must have the fj- prefix and customer_id/node_id must be
# non-empty; a well-formed managed record missing those facts is identity DRIFT.
# This is intentionally broader than describe_running_managed_vm_by_hostname,
# whose provisioning lookup also filters one Name, running state, configured
# subnet, and configured image; using that lookup would hide the drift/stale
# records this classifier exists to report.
#
# aws.rs::map_ec2_state establishes the vocabulary: pending -> Pending,
# running -> Running, stopping/stopped -> Stopped,
# shutting-down/terminated -> Terminated, and missing/unrecognized -> Unknown.
# Only Running is healthy. Pending, stopping, stopped, shutting-down,
# terminated, unknown, and a structurally allowed missing/null State.Name are
# non-running and therefore STALE. Mixed running/non-running and all
# non-running fleets are both STALE unless a higher-precedence finding exists.
#
# Existing inventory-reconciliation seam
# --------------------------------------
# scripts/reliability/validate_vm_inventory_ec2_consistency.sh already owns DB
# reconciliation. Reuse its managed-by filter, AWS
# Reservations[].Instances[] fixture shape, temp-directory isolation, and
# explicit injected-time pattern. Do not copy its embedded Python DB matching,
# provider-ID/hostname reconciliation, retry-window rules, or terminal-record
# hiding: those are deliberately out of scope for this health classifier, and
# its live query is single-region and omits ImageId/SubnetId. The narrow new
# seam is health normalization across explicit regions; it must not become a
# parallel DB-reconciliation implementation.
#
# Region scope
# ------------
# infra/api/src/provisioner/region_map.rs::RegionConfig::from_env loads
# REGION_CONFIG (or defaults), and provisioner/mod.rs::effective_region_config
# filters it to constructed providers. The runtime-effective enabled set is
# therefore environment-specific; the two built-in AWS defaults are not a
# live/account-wide oracle.
#
# For each environment, the collector reads that environment's existing
# unauthenticated GET /public/infrastructure owner and selects available rows
# whose provider is "aws". Each row's provider_location, not an assumed region
# or merely its display ID, is the EC2/SSM region. The sweep is the de-duplicated
# union of staging and prod provider_location values, while evidence retains
# each environment-to-region membership. A physical region is read once and
# joined back to every environment that enabled it. Empty/missing environment
# configuration is ACTION_REQUIRED; a request, status, JSON, or repository
# failure after collection starts is a failed required read and PROBE_ERROR.
# Every union region must complete EC2 and adopted SSM enumeration. No result
# from one region may stand in for another, and no single-region result may be
# described as account-wide coverage.
#
# adr-decision: region_scope => discover staging and prod runtime-enabled AWS provider_location values via each environment's GET /public/infrastructure, sweep their de-duplicated union explicitly, retain per-environment membership, and fail closed if discovery or any required regional read is not complete
#
# Environment attribution
# -----------------------
# ops/terraform/runtime_params/main.tf publishes region-local String parameters
# /fjcloud/${env}/aws_subnet_id and /fjcloud/${env}/aws_ami_id. For every
# environment/region pair returned above, collect both pointers from that same
# physical region. Attribute a managed instance only by its SubnetId matching
# exactly one enabled environment's same-region subnet pointer. AMI is a
# currency oracle after attribution, never an environment discriminator.
#
# Equal staging/prod subnet pointers in one shared region make attribution
# ambiguous and ACTION_REQUIRED. A missing/empty/ParameterNotFound subnet
# pointer is an unreadable attribution oracle and ACTION_REQUIRED; a transport,
# authorization, command, or parse failure is PROBE_ERROR. A subnet matching
# neither enabled environment is DRIFT. Never fall back to another region's
# pointer. Different subnet or AMI values across regions are expected and are
# compared only within their region. No EC2 `environment` tag is invented.
# scripts/probe_live_state.sh's existing aws_ssm_${env} loop already captures
# /fjcloud/${env}/aws_ami_id in its configured/default region. The integrated
# collector must reuse that successful same-region result when it covers a
# required region and only add reads for uncovered regions; it must not fetch
# the identical pointer twice merely to populate the new evidence document.
#
# adr-decision: environment_attribution => match each instance SubnetId to exactly one enabled environment's same-region /fjcloud/${env}/aws_subnet_id; equal or semantically unreadable subnet pointers are ACTION_REQUIRED, no match is DRIFT, and AMI or an invented environment tag must never choose the environment
#
# AMI currency
# ------------
# After subnet attribution, compare ImageId to the attributed environment's
# same-region /fjcloud/${env}/aws_ami_id. Equal staging/prod AMI pointers are
# valid: both environments can intentionally share the current image. One or
# both missing, empty, or ParameterNotFound AMI pointers make the oracle
# unreadable and ACTION_REQUIRED even if the fleet is degraded; command,
# transport, authorization, or malformed-response failures are PROBE_ERROR.
# A readable pointer that differs from the instance ImageId is DRIFT. Pointers
# never cross region boundaries, and all required pointers are read even in a
# region that currently has no managed instances.
#
# adr-decision: ami_oracle => compare ImageId only with the subnet-attributed environment's same-region /fjcloud/${env}/aws_ami_id; equal env pointers are allowed, semantic absence is ACTION_REQUIRED, failed reads are PROBE_ERROR, and readable mismatch is DRIFT
#
# Real data-plane evidence
# ------------------------
# EC2 state, tags, AMI, and SSM ping evidence are fleet/control-plane facts.
# They can never prove the ROADMAP's engine/search exit. Likewise,
# scripts/security/probe_engine_exposure.sh proves that public :7700 exposure
# is absent; it is a security posture probe, must not be duplicated here, and
# public unauthenticated engine access must not become a health prerequisite.
#
# The selected data path is fjcloud's existing authenticated API browse proxy:
# POST /indexes/:name/browse in infra/api/src/router/route_assembly.rs routes
# through routes/indexes/documents.rs and services/flapjack_proxy/documents.rs,
# which obtains the node key and calls the engine browse endpoint. This avoids
# the search route's quota/access side effects while still proving API
# authentication, routing, engine reachability, and a non-vacuous document
# response without exposing :7700.
#
# The read identity contract for each environment is:
# * resolve an active customer by canonical name demo-shared-free (or email
#   demo-shared-free@synthetic-seed.invalid) using GET /admin/tenants;
# * mint a 60-second tenant JWT through POST /admin/tokens with purpose "admin"
#   (not "impersonation"). routes/admin/tokens.rs confirms this signs a token
#   but writes no audit row;
# * POST /indexes/demo-shared-free/browse using that JWT with a projected,
#   bounded read body; and
# * require HTTP 200 and an object whose objectID is "doc-0".
#
# scripts/launch/seed_synthetic_traffic.sh and
# scripts/lib/deterministic_batch_payload.sh own the staging identity, seed 42,
# objectID doc-0, and deterministic body derivation. Reuse the exact-object
# readback seam;
# do not use the helper's direct-node fallback. Reuse
# scripts/validate_customer_quickstart.sh::search_response_has_hit semantics so
# an empty hits array, unrelated hit, count-only response, or status-only probe
# is never positive evidence.
#
# Open operational prerequisite: the repository defines and can provision this
# identity only for staging; it does not prove that the active tenant/index/doc
# and an environment-specific API_URL/ADMIN_KEY exist in both staging and prod.
# Later collection must receive those existing credentials without serializing
# them and must verify the identity read-only. Until the identity is provisioned
# and resolvable in each required environment, search evidence is indeterminate
# and the overall result is ACTION_REQUIRED. The probe must not create a tenant,
# index, or document to repair the prerequisite.
#
# adr-decision: data_plane_evidence => for each environment use its existing admin credential only to resolve demo-shared-free, mint a non-persistent 60-second purpose=admin tenant JWT, and require POST /indexes/demo-shared-free/browse to return objectID doc-0; missing identity or credential is ACTION_REQUIRED and EC2/SSM/direct-public-port evidence is never a substitute
#
# Supplemental SSM freshness
# --------------------------
# Adopt aws ssm describe-instance-information in every covered physical region,
# joined to EC2 by exact InstanceId. AWS documents LastPingDateTime and
# PingStatus on InstanceInformation, notes the call is region-scoped, and says
# the agent sends a health signal every five minutes. Sources:
# https://docs.aws.amazon.com/cli/latest/reference/ssm/describe-instance-information.html
# https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_InstanceInformation.html
# https://docs.aws.amazon.com/systems-manager/latest/userguide/fleet-manager-troubleshooting-managed-nodes.html
#
# Normalize LastPingDateTime to an integer UTC Unix epoch in the collector and
# inject one observed_at_epoch into the evidence. For every enumerated managed
# instance, freshness is healthy only when PingStatus is exactly Online and
# age=observed_at_epoch-last_ping_epoch satisfies 0 <= age <= 600 seconds.
# Equality at 600 is fresh. A missing SSM row, absent/unparseable timestamp,
# ConnectionLost/Inactive/unknown status, or last ping in the future is STALE;
# future time is treated as clock skew, not silently clamped. A failed regional
# describe-instance-information read is PROBE_ERROR. SSM is supplemental
# control-plane evidence only and never changes the search requirement.
#
# adr-decision: freshness_contract => join regional SSM InstanceInformation by InstanceId and require PingStatus=Online with integer UTC age in the inclusive range 0..600 using injected observed_at_epoch; missing/unparseable/future timestamps, missing rows, or non-Online status are STALE, while a failed regional read is PROBE_ERROR
#
# One evidence contract for live collection and fixtures
# ------------------------------------------------------
# The classifier accepts exactly one local evidence file (the integrated
# interface is `--evidence <path>`). Live collection and tests must populate the
# same schema_version=1 JSON; fixtures must not gain test-only classification
# fields. Required shape:
#
# {
#   "schema_version": 1,
#   "observed_at_epoch": <integer UTC seconds>,
#   "credential_state": "available" | "missing",
#   "environments": [{
#     "name": "staging" | "prod",
#     "region_discovery": {
#       "outcome": "ok" | "missing" | "failed",
#       "aws_regions": [{"id": <logical id>, "aws_region": <provider_location>}]
#     },
#     "pointers": [{
#       "aws_region": <string>,
#       "subnet": {"outcome": "ok" | "missing" | "failed", "value": <string|null>},
#       "ami": {"outcome": "ok" | "missing" | "failed", "value": <string|null>}
#     }],
#     "data_plane": {
#       "identity_outcome": "ok" | "missing" | "failed",
#       "request_outcome": "ok" | "indeterminate" | "failed",
#       "http_status": <integer|null>,
#       "matching_object_count": <integer|null>
#     }
#   }],
#   "regions": [{
#     "aws_region": <string>,
#     "ec2": {"outcome": "ok" | "failed", "instances": [{
#       "instance_id": <string>, "state": <string|null>,
#       "image_id": <string|null>, "subnet_id": <string|null>,
#       "tags": {"Name": <string|null>, "customer_id": <string|null>,
#                "node_id": <string|null>, "managed-by": "fjcloud"}
#     }]},
#     "ssm": {"outcome": "ok" | "failed", "instances": [{
#       "instance_id": <string>, "ping_status": <string|null>,
#       "last_ping_epoch": <integer|null>
#     }]}
#   }]
# }
#
# Empty input, invalid JSON, wrong types, unsupported schema_version, duplicate
# environment/region/instance identities, or absent required structural fields
# are malformed evidence and PROBE_ERROR. State, image, subnet, tag, and SSM
# value nullability shown above is intentional domain evidence: missing state
# becomes Unknown/STALE, missing identity/currency values become DRIFT or the
# oracle outcomes above, and missing freshness becomes STALE.
#
# Secret material is forbidden in this evidence. AWS secret/session values,
# ADMIN_KEY, JWTs, node admin keys, Authorization headers, raw request bodies,
# and local absolute paths must never be serialized or printed. As established
# by scripts/security/tests_probe_engine_exposure.sh and
# scripts/tests/probe_flapjack_build_identity_test.sh, Stage 2/3 tests must use
# isolated temp fixtures, injected time, exact stdout/stderr/exit assertions,
# and sentinel secrets/paths that prove no leak. The implemented classifier
# emits exactly one structured token on stdout and diagnostic context without
# secrets or paths on stderr.
#
# adr-decision: evidence_ownership => probe_live_state.sh resolves credentials once and performs all region, EC2, SSM, pointer, tenant-token, and search reads into one schema_version=1 raw evidence file; probe_fleet_dataplane.sh only classifies that same live-or-fixture file and returns one token, with no independent STS, AWS, HTTP, SUMMARY, or manifest ownership
#
# Read-only-effect allowlist
# --------------------------
# The integrated collector may perform only these network operations:
# * its existing single aws sts get-caller-identity credential probe;
# * complete paginated aws ec2 describe-instances per union region with only
#   Name=tag:managed-by,Values=fjcloud;
# * aws ssm get-parameter (without decryption) for the two String pointers and
#   aws ssm describe-instance-information per required region;
# * GET /public/infrastructure and GET /admin/tenants per environment;
# * POST /admin/tokens solely with purpose=admin and 60-second expiry; and
# * POST /indexes/demo-shared-free/browse solely for the bounded doc-0 read.
#
# The two POST endpoints are allowlisted because routine admin token signing
# does not persist an audit row and browse is the API's existing non-mutating
# document-read proxy. Reject every EC2/SSM mutation, send-command,
# start-session, SSH, direct node access, application data write,
# tenant/index/document provisioning, search quota/access routes, and
# exposure-probe duplication. This ADR does not authorize live calls in Stage 1.
#
# Total disposition, token, and exit contract
# -------------------------------------------
# The stdout vocabulary is exactly one line:
# FLEET_STATUS: OK|STALE|DRIFT|ACTION_REQUIRED|PROBE_ERROR reason=<reason_code>
# `SKIP_NO_CREDS` is unreachable for this overall row.
#
# Status precedence is total and follows the existing live-state bias that a
# known operator prerequisite outranks a probe failure:
# ACTION_REQUIRED > PROBE_ERROR > DRIFT > STALE > OK.
# Thus DRIFT+STALE => DRIFT; an unreadable oracle+degraded instance =>
# ACTION_REQUIRED; a failed required read+degraded/DRIFT instance =>
# PROBE_ERROR; and any known ACTION_REQUIRED finding dominates every other
# finding. Within one status, the reason tie-break order is the order below:
# missing_credentials, region_scope_unavailable,
# environment_attribution_ambiguous, ami_oracle_unreadable,
# search_evidence_indeterminate, zero_managed_instances, malformed_evidence,
# required_read_failed, identity_or_environment_drift, ami_mismatch,
# non_running_instance, freshness_missing_or_stale, healthy_nonempty_fleet.
#
# status-mapping: missing_credentials => ACTION_REQUIRED; never SKIP_NO_CREDS, and no second STS probe is allowed
# status-mapping: zero_managed_instances => ACTION_REQUIRED when no managed instance exists across all covered regions or either required environment has no attributed managed instance
# status-mapping: required_read_failed => PROBE_ERROR for attempted region discovery, EC2, SSM, or pointer collection that fails by command, transport, authorization, pagination, repository, or response-parse error; search failures use search_evidence_indeterminate instead
# status-mapping: malformed_evidence => PROBE_ERROR for empty input, invalid JSON, unsupported schema, wrong types, duplicate identities, or absent required structural fields
# status-mapping: ami_oracle_unreadable => ACTION_REQUIRED when any required same-region AMI pointer is missing, empty, or ParameterNotFound; a failed read remains required_read_failed
# status-mapping: ami_mismatch => DRIFT when an attributed instance ImageId differs from its readable same-region environment AMI pointer
# status-mapping: non_running_instance => STALE for any pending, stopping, stopped, shutting-down, terminated, unknown, or missing/null state, including all-non-running and mixed running/non-running fleets
# status-mapping: freshness_missing_or_stale => STALE for any missing SSM row/timestamp, non-Online ping, age over 600 seconds, or future timestamp; equality at 600 seconds is fresh
# status-mapping: search_evidence_indeterminate => ACTION_REQUIRED when either environment lacks its active identity/API/admin credential, search is unauthorized/unreachable/non-200, hits are absent/empty, or doc-0 is not present
# status-mapping: healthy_nonempty_fleet => OK only when both environments and every required region/read are covered, the attributed fleet is non-empty per environment, all managed instances have canonical tags/current same-region AMI/running state/fresh SSM evidence, and both exact-object API searches are positive
# status-mapping: mixed_status_precedence => ACTION_REQUIRED > PROBE_ERROR > DRIFT > STALE > OK, with the fixed same-status reason order above; specifically DRIFT+STALE is DRIFT and unreadable-oracle+degraded is ACTION_REQUIRED
# status-mapping: exit_codes => 0 only for a valid OK token; 1 for any valid recognized STALE, DRIFT, ACTION_REQUIRED, or PROBE_ERROR token; 2 for CLI usage or internal classifier failure that prevents emission of exactly one valid token
#
# Additional dispositions needed to make the mapping closed:
# * missing/empty environment region configuration is
#   ACTION_REQUIRED/region_scope_unavailable; an attempted discovery failure is
#   PROBE_ERROR/required_read_failed.
# * equal same-region subnet pointers are
#   ACTION_REQUIRED/environment_attribution_ambiguous; an instance matching no
#   environment subnet or missing canonical tags is
#   DRIFT/identity_or_environment_drift.
# * successful regional reads with zero instances are valid coverage, but the
#   final fleet must contain at least one attributed instance per required
#   environment before OK is possible.

usage() {
  printf 'usage: %s --evidence <path>\n' "$(basename "$0")" >&2
}

if [ "$#" -ne 2 ] || [ "${1:-}" != "--evidence" ] || [ -z "${2:-}" ]; then
  usage
  exit 2
fi

python3 - "$2" <<'PY'
import json
import sys

REASONS = [
    "missing_credentials",
    "region_scope_unavailable",
    "environment_attribution_ambiguous",
    "ami_oracle_unreadable",
    "search_evidence_indeterminate",
    "zero_managed_instances",
    "malformed_evidence",
    "required_read_failed",
    "identity_or_environment_drift",
    "ami_mismatch",
    "non_running_instance",
    "freshness_missing_or_stale",
    "healthy_nonempty_fleet",
]
STATUS_RANK = {"OK": 0, "STALE": 1, "DRIFT": 2, "PROBE_ERROR": 3, "ACTION_REQUIRED": 4}
VALID_STATUS = set(STATUS_RANK)
VALID_ENVS = {"staging", "prod"}


class Malformed(Exception):
    pass


def emit(status, reason):
    print(f"FLEET_STATUS: {status} reason={reason}")
    return 0 if status == "OK" else 1


def malformed():
    return emit("PROBE_ERROR", "malformed_evidence")


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        raise Malformed("unreadable evidence") from exc
    if not raw.strip():
        raise Malformed("empty evidence")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise Malformed("invalid json") from exc


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def req_dict(obj, key):
    value = obj.get(key) if isinstance(obj, dict) else None
    if not isinstance(value, dict):
        raise Malformed(f"missing dict {key}")
    return value


def req_list(obj, key):
    value = obj.get(key) if isinstance(obj, dict) else None
    if not isinstance(value, list):
        raise Malformed(f"missing list {key}")
    return value


def req_str(obj, key):
    value = obj.get(key) if isinstance(obj, dict) else None
    if not isinstance(value, str) or value == "":
        raise Malformed(f"missing string {key}")
    return value


def nullable_str(obj, key):
    value = obj.get(key) if isinstance(obj, dict) else None
    if value is not None and not isinstance(value, str):
        raise Malformed(f"wrong nullable string {key}")
    return value


def add(findings, status, reason):
    if status not in VALID_STATUS or reason not in REASONS:
        raise RuntimeError("invalid finding")
    findings.append((status, reason))


def best(findings):
    if not findings:
        return "OK", "healthy_nonempty_fleet"
    max_rank = max(STATUS_RANK[status] for status, _ in findings)
    status_findings = [(status, reason) for status, reason in findings if STATUS_RANK[status] == max_rank]
    return min(status_findings, key=lambda item: REASONS.index(item[1]))


def require_outcome(value, allowed):
    if value not in allowed:
        raise Malformed("unsupported outcome")
    return value


def pointer_values(pointer):
    subnet = req_dict(pointer, "subnet")
    ami = req_dict(pointer, "ami")
    subnet_outcome = require_outcome(subnet.get("outcome"), {"ok", "missing", "failed"})
    ami_outcome = require_outcome(ami.get("outcome"), {"ok", "missing", "failed"})
    subnet_value = nullable_str(subnet, "value")
    ami_value = nullable_str(ami, "value")
    return subnet_outcome, subnet_value, ami_outcome, ami_value


def validate_top(data):
    if not isinstance(data, dict):
        raise Malformed("top-level evidence must be an object")
    if data.get("schema_version") != 1:
        raise Malformed("unsupported schema")
    if not is_int(data.get("observed_at_epoch")):
        raise Malformed("observed_at_epoch must be integer")
    if data.get("credential_state") not in {"available", "missing"}:
        raise Malformed("unsupported credential_state")
    req_list(data, "environments")
    req_list(data, "regions")


def collect_environment_context(data, findings):
    envs = {}
    required_regions = {}
    pointer_by_env_region = {}
    failed_discovery_envs = set()

    for env in req_list(data, "environments"):
        if not isinstance(env, dict):
            raise Malformed("environment must be object")
        name = req_str(env, "name")
        if name not in VALID_ENVS or name in envs:
            raise Malformed("duplicate or unsupported environment")
        envs[name] = env

        discovery = req_dict(env, "region_discovery")
        outcome = require_outcome(discovery.get("outcome"), {"ok", "missing", "failed"})
        regions = req_list(discovery, "aws_regions")
        region_ids = set()
        env_regions = []
        for region in regions:
            if not isinstance(region, dict):
                raise Malformed("region discovery row must be object")
            logical_id = req_str(region, "id")
            aws_region = req_str(region, "aws_region")
            if logical_id in region_ids:
                raise Malformed("duplicate environment region identity")
            region_ids.add(logical_id)
            env_regions.append(aws_region)
        if outcome == "failed":
            add(findings, "PROBE_ERROR", "required_read_failed")
            failed_discovery_envs.add(name)
            required_regions[name] = []
        elif outcome == "missing" or not env_regions:
            add(findings, "ACTION_REQUIRED", "region_scope_unavailable")
            required_regions[name] = []
        else:
            required_regions[name] = env_regions

        seen_pointers = set()
        for pointer in req_list(env, "pointers"):
            if not isinstance(pointer, dict):
                raise Malformed("pointer row must be object")
            aws_region = req_str(pointer, "aws_region")
            if aws_region in seen_pointers:
                raise Malformed("duplicate pointer identity")
            seen_pointers.add(aws_region)
            pointer_values(pointer)
            pointer_by_env_region[(name, aws_region)] = pointer

        data_plane = env.get("data_plane")
        if not isinstance(data_plane, dict):
            raise Malformed("missing data_plane")
        identity = require_outcome(data_plane.get("identity_outcome"), {"ok", "missing", "failed"})
        request = require_outcome(data_plane.get("request_outcome"), {"ok", "indeterminate", "failed"})
        http_status = data_plane.get("http_status")
        match_count = data_plane.get("matching_object_count")
        if http_status is not None and not is_int(http_status):
            raise Malformed("invalid data_plane http_status")
        if match_count is not None and not is_int(match_count):
            raise Malformed("invalid data_plane matching_object_count")
        if identity != "ok" or request != "ok" or http_status != 200 or match_count is None or match_count <= 0:
            add(findings, "ACTION_REQUIRED", "search_evidence_indeterminate")

    for required_env in VALID_ENVS - set(envs):
        required_regions[required_env] = []
        add(findings, "ACTION_REQUIRED", "region_scope_unavailable")

    return required_regions, pointer_by_env_region, failed_discovery_envs


def collect_region_context(data, findings):
    region_by_name = {}
    instances_by_region = {}
    ssm_by_region = {}
    failed_ec2_regions = set()
    seen_instances = set()

    for region in req_list(data, "regions"):
        if not isinstance(region, dict):
            raise Malformed("region row must be object")
        aws_region = req_str(region, "aws_region")
        if aws_region in region_by_name:
            raise Malformed("duplicate region identity")
        region_by_name[aws_region] = region

        ec2 = req_dict(region, "ec2")
        if require_outcome(ec2.get("outcome"), {"ok", "failed"}) == "failed":
            add(findings, "PROBE_ERROR", "required_read_failed")
            failed_ec2_regions.add(aws_region)
            instances_by_region[aws_region] = []
        else:
            rows = []
            for instance in req_list(ec2, "instances"):
                if not isinstance(instance, dict):
                    raise Malformed("instance row must be object")
                instance_id = req_str(instance, "instance_id")
                if instance_id in seen_instances:
                    raise Malformed("duplicate instance identity")
                seen_instances.add(instance_id)
                nullable_str(instance, "state")
                nullable_str(instance, "image_id")
                nullable_str(instance, "subnet_id")
                tags = req_dict(instance, "tags")
                for tag_name in ("Name", "customer_id", "node_id", "managed-by"):
                    nullable_str(tags, tag_name)
                rows.append(instance)
            instances_by_region[aws_region] = rows

        ssm = req_dict(region, "ssm")
        ssm_rows = {}
        if require_outcome(ssm.get("outcome"), {"ok", "failed"}) == "failed":
            add(findings, "PROBE_ERROR", "required_read_failed")
        else:
            for row in req_list(ssm, "instances"):
                if not isinstance(row, dict):
                    raise Malformed("ssm row must be object")
                instance_id = req_str(row, "instance_id")
                if instance_id in ssm_rows:
                    raise Malformed("duplicate ssm identity")
                nullable_str(row, "ping_status")
                last_ping = row.get("last_ping_epoch")
                if last_ping is not None and not is_int(last_ping):
                    raise Malformed("invalid ssm timestamp")
                ssm_rows[instance_id] = row
        ssm_by_region[aws_region] = ssm_rows

    return region_by_name, instances_by_region, ssm_by_region, failed_ec2_regions


def evaluate_pointers(required_regions, pointer_by_env_region, findings):
    subnet_by_env_region = {}
    ami_by_env_region = {}
    failed_pointer_envs = set()
    for env_name, regions in required_regions.items():
        for aws_region in regions:
            pointer = pointer_by_env_region.get((env_name, aws_region))
            if pointer is None:
                add(findings, "ACTION_REQUIRED", "environment_attribution_ambiguous")
                add(findings, "ACTION_REQUIRED", "ami_oracle_unreadable")
                continue
            subnet_outcome, subnet_value, ami_outcome, ami_value = pointer_values(pointer)
            if subnet_outcome == "failed":
                add(findings, "PROBE_ERROR", "required_read_failed")
                failed_pointer_envs.add(env_name)
            elif subnet_outcome != "ok" or not subnet_value:
                add(findings, "ACTION_REQUIRED", "environment_attribution_ambiguous")
            else:
                subnet_by_env_region[(env_name, aws_region)] = subnet_value
            if ami_outcome == "failed":
                add(findings, "PROBE_ERROR", "required_read_failed")
            elif ami_outcome != "ok" or not ami_value:
                add(findings, "ACTION_REQUIRED", "ami_oracle_unreadable")
            else:
                ami_by_env_region[(env_name, aws_region)] = ami_value

    for aws_region in {region for _, region in subnet_by_env_region}:
        values = [(env, subnet) for (env, region), subnet in subnet_by_env_region.items() if region == aws_region]
        if len(values) != len({subnet for _, subnet in values}):
            add(findings, "ACTION_REQUIRED", "environment_attribution_ambiguous")

    return subnet_by_env_region, ami_by_env_region, failed_pointer_envs


def blocked_fleet_envs(required_regions, failed_discovery_envs, failed_pointer_envs, region_by_name, failed_ec2_regions, findings):
    blocked = set(failed_discovery_envs) | set(failed_pointer_envs)
    for env_name, env_regions in required_regions.items():
        for aws_region in env_regions:
            if aws_region not in region_by_name:
                add(findings, "PROBE_ERROR", "required_read_failed")
                blocked.add(env_name)
            elif aws_region in failed_ec2_regions:
                blocked.add(env_name)
    return blocked


def evaluate_instances(data, instances_by_region, ssm_by_region, subnet_by_env_region, ami_by_env_region, blocked_envs, findings):
    observed_at = data["observed_at_epoch"]
    attributed_counts = {env: 0 for env in VALID_ENVS}

    for aws_region, instances in instances_by_region.items():
        for instance in instances:
            tags = instance["tags"]
            if (
                tags.get("managed-by") != "fjcloud"
                or not (tags.get("Name") or "").startswith("fj-")
                or not tags.get("customer_id")
                or not tags.get("node_id")
            ):
                add(findings, "DRIFT", "identity_or_environment_drift")

            subnet_id = instance.get("subnet_id")
            matches = [
                env
                for (env, region), subnet in subnet_by_env_region.items()
                if region == aws_region and subnet == subnet_id
            ]
            if len(matches) != 1:
                add(findings, "DRIFT", "identity_or_environment_drift")
                attributed_env = None
            else:
                attributed_env = matches[0]
                attributed_counts[attributed_env] += 1

            if attributed_env is not None:
                expected_ami = ami_by_env_region.get((attributed_env, aws_region))
                if expected_ami and instance.get("image_id") != expected_ami:
                    add(findings, "DRIFT", "ami_mismatch")

            if (instance.get("state") or "").lower() != "running":
                add(findings, "STALE", "non_running_instance")

            ssm_row = ssm_by_region.get(aws_region, {}).get(instance["instance_id"])
            if not ssm_row:
                add(findings, "STALE", "freshness_missing_or_stale")
                continue
            last_ping = ssm_row.get("last_ping_epoch")
            age = None if last_ping is None else observed_at - last_ping
            if ssm_row.get("ping_status") != "Online" or age is None or age < 0 or age > 600:
                add(findings, "STALE", "freshness_missing_or_stale")

    if any(attributed_counts[env] == 0 for env in VALID_ENVS if env not in blocked_envs):
        add(findings, "ACTION_REQUIRED", "zero_managed_instances")


def classify(data):
    findings = []
    validate_top(data)
    required_regions, pointer_by_env_region, failed_discovery_envs = collect_environment_context(data, findings)
    region_by_name, instances_by_region, ssm_by_region, failed_ec2_regions = collect_region_context(data, findings)
    subnet_by_env_region, ami_by_env_region, failed_pointer_envs = evaluate_pointers(required_regions, pointer_by_env_region, findings)
    if data["credential_state"] == "missing":
        return "ACTION_REQUIRED", "missing_credentials"

    blocked_envs = blocked_fleet_envs(
        required_regions,
        failed_discovery_envs,
        failed_pointer_envs,
        region_by_name,
        failed_ec2_regions,
        findings,
    )
    evaluate_instances(
        data,
        instances_by_region,
        ssm_by_region,
        subnet_by_env_region,
        ami_by_env_region,
        blocked_envs,
        findings,
    )
    return best(findings)


try:
    status, reason = classify(read_json(sys.argv[1]))
except Malformed:
    sys.exit(malformed())

sys.exit(emit(status, reason))
PY
