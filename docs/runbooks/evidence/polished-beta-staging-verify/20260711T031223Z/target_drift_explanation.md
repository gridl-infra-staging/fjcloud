Stage 1 target drift explanation

target_dev_sha.txt records the current checkout HEAD required by the checklist: e899605d567b44db251c8068f6bcb007ac547059.
This session is running from branch batman/jul10_pm_8_deployed_launch_sentence_verify, whose HEAD is a stage/checklist commit and is not dev main.
The canonical staging deployment owner, debbie sync staging plus scripts/deploy_status.sh, deployed dev main: 873f39ef4a375e69f81fcb021f0297fd75381708.
scripts/deploy_status.sh reports staging dev_sha=873f39ef4a375e69f81fcb021f0297fd75381708 and commits_behind_main=0.
Stage 2 should treat dev main 873f39ef4a375e69f81fcb021f0297fd75381708 as the deployed product SHA and target_dev_sha.txt as checkout provenance for this evidence session.
