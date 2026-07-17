# Stage 4 validation commands

- `bash scripts/tests/validate_customer_quickstart_test.sh`
- `python3 -c "import pathlib,re,sys; bad=[]; docs=[pathlib.Path(p) for p in sys.argv[1:]]; [bad.append(f'{doc}:{target}') for doc in docs for target in [m.group(1).split('#',1)[0] for m in re.finditer(r'\\[[^\\]]+\\]\\(([^)]+)\\)', doc.read_text())] if target and '://' not in target and not target.startswith('mailto:') and not (doc.parent / target).resolve().exists()]; print('\\n'.join(bad)); raise SystemExit(1 if bad else 0)" docs/getting-started/customer-quickstart.md docs/getting-started/migrating_from_algolia.md`
- Corrected external URL probe: `rg --no-filename -o 'https?://[^)" ]+' docs/getting-started/customer-quickstart.md docs/getting-started/migrating_from_algolia.md | sort -u | xargs -n1 curl -fsSI`
- Staging validation setup: load `.secret/.env.secret`, write the generated SSM hydrate env to a temp file, source that file, set `SES_REGION` default `us-east-1`, set inbound roundtrip defaults, then run `bash scripts/validate_customer_quickstart.sh staging`.
- Extra non-mutating guard: `bash scripts/validate_customer_quickstart.sh prod --contract-only`.
