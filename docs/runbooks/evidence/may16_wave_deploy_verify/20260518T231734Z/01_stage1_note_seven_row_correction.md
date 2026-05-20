# Stage 1 Note: Six-Row Draft Corrected To Seven Rows

The older lane draft still contains a six-row matrix guard:

- `chats/icg/may18_pm_1_may16_wave_deploy_verify_sweep.md` lines 150-151:
  - `# Confirm matrix file exists with all 6 lanes`
  - `grep -c "^| may16_" "${EVIDENCE_DIR}/00_matrix.md" | grep -q "^6$"`

Stage 1 intentionally corrects this baseline to seven rows by splitting `may16_9pm_4` into two distinct verification targets: `run-a` and `run-b`.
