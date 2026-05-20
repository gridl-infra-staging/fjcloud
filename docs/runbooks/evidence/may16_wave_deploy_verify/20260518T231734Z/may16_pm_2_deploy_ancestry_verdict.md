# may16_pm_2 Stage 2 Deploy-Ancestry Verdict
- Source raw deploy status: `may16_pm_2_stage4.stdout`
- Source raw /version fallback: `version_direct_fallback.json`
- Source raw ancestor transcript: `ancestor_checks.txt`
- Source CI lists: `gh_run_list_gridl-infra-staging_fjcloud.json`, `gh_run_list_gridl-infra-prod_fjcloud.json`

## Ancestry classification
- prod dev_sha: `unknown` (`unknown` from owner probe)
- prod mirror_sha: `unknown` (`unknown` from owner probe)
- staging dev_sha: `67d48abce51678885b86b248d1c449756fd9206d` (`unknown`)
  - evidence: `git merge-base --is-ancestor 3d179dd0ea6d0f9bb4879bf4dcb7c24166346d9e 67d48abce51678885b86b248d1c449756fd9206d` exited `128` in `ancestor_checks.txt`, so this comparison did not produce an ancestry verdict.
- staging mirror_sha: `fa64aba192866d5aa72e6409b3ec04fe6375ea16` (`pre-wave`)
  - evidence: `git -C /Users/stuart/repos/gridl-infra-staging/fjcloud merge-base --is-ancestor 3d179dd0ea6d0f9bb4879bf4dcb7c24166346d9e fa64aba192866d5aa72e6409b3ec04fe6375ea16` exited `1` in `ancestor_checks.txt`.

- VERDICT: `FAIL` (staging mirror SHA is pre-wave; prod unresolved by owner probe)
