# Operator Commit Helper

This folder gives you one simple repo-local command for:

- `git add .`
- `git commit --no-verify`
- `git push`

The helper deliberately reuses git's built-in `--no-verify` path instead of
adding new ratchet-bypass code or any secret/token flow.

## File

- `ship`
  : stages the repo, commits with `--no-verify`, and pushes

## Usage

From anywhere inside this repo:

```bash
./ops/operator_commit/ship whatever message you want here
```

Everything after the command becomes the commit message.

Example:

```bash
./ops/operator_commit/ship mwip fixing merge state before batch land
```

That runs:

```bash
git add .
git commit --no-verify -m "mwip fixing merge state before batch land"
git push
```

## Notes

- there is no setup step
- there is no global secret
- there is no token or extra ratchet integration
- this is intentionally simple and repo-local
