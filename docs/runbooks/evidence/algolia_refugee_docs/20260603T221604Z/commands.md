# Stage 4 validation commands

- `bash scripts/check-sizes.sh`
- `bash scripts/tests/validate_customer_quickstart_test.sh`
- `python3 -c "import pathlib,re,sys; bad=[]; docs=[pathlib.Path(p) for p in sys.argv[1:]]; [bad.append(f'{doc}:{target}') for doc in docs for target in [m.group(1).split('#',1)[0] for m in re.finditer(r'\[[^\]]+\]\(([^)]+)\)', doc.read_text())] if target and '://' not in target and not target.startswith('mailto:') and not (doc.parent / target).resolve().exists()]; print('\n'.join(bad)); raise SystemExit(1 if bad else 0)" docs/getting-started/customer-quickstart.md docs/getting-started/migrating_from_algolia.md`
- Corrected external URL probe: `rg --no-filename -o 'https?://[^)" ]+' docs/getting-started/customer-quickstart.md docs/getting-started/migrating_from_algolia.md | sort -u | xargs -n1 curl -fsSI`
- Non-mutating prod verb contract: `bash scripts/validate_customer_quickstart.sh prod --contract-only`
- Hydrated staging setup: `set -a; source .secret/.env.secret; set +a; source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging); export SES_REGION=us-east-1 INBOUND_ROUNDTRIP_S3_URI=s3://flapjack-cloud-releases/e2e-emails/ INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN=test.flapjack.foo; bash scripts/validate_customer_quickstart.sh staging`
