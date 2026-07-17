# Reporter path sanitization

- reason: Playwright JSON reporter included workspace-absolute paths in failure metadata and attachment paths.
- action: copied Lane F attachments into `lane_F_artifacts/` and rewrote reporter path strings to repo-relative paths.
- json_valid_after_sanitization: yes
