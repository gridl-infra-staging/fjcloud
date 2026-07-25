# Approaching live (staging/prod) work without the repeated headaches

**Last updated:** 2026-07-25

Local coding works great fully hands-off. Live-environment work — staging/prod
deploys and the proofs that run on them — has repeatedly stalled for *weeks*.
This note captures why, and how to do it differently. It is doctrine for anyone
(agent or human) about to touch the live environment. Companion to
[`docs/launch/beta_launch_remaining_work.md`](../launch/beta_launch_remaining_work.md).

## The core idea

Treat local work and live work as **two different modes**:

- **Local mode** — agents run free, fully autonomous. This works well; keep it.
- **Live mode** — small, supervised, on an environment made reliable *first*.
  Do **not** run live work as big hands-off marathons. That is precisely what
  keeps stranding it.

## Five principles

**1. Make the environment reliable first — before proving anything on it.**
Most failures were not the product; they were the environment: a database you
can't reach the normal way, a deploy that failed, old code still running,
"evidence" that turned out to come from a dead alias or a masked failure. Every
proof attempt has been fighting the environment *and* the product at once. Fix
the environment once — a deploy that just works, a reliable way to reach the
database, and a check that "what's running matches our code" — and proofs on
top become easy instead of a battle.

**2. Deploy small and often, so live never drifts from the code.**
A big pile of merged-but-undeployed work accumulated, so nobody was sure what
was actually running. Push after each small change; there is never a scary
"deploy weeks of changes at once" moment, and nobody reasons off a stale
picture of the environment.

**3. Small, single-purpose, supervised steps — not big autonomous marathons.**
The failure pattern is one job that tries to deploy AND prove AND sign off, runs
out of budget, and drops the proof at the very end (the proof is always the last
stage). Instead: one tiny job that *just* deploys; another that *just* proves
billing; another that *just* flips a switch — each with a person available to
unstick it the moment it breaks. Live environments break in messy ways that
need a human's eyes and access an agent doesn't have.

**4. Tell "the code is broken" apart from "the environment isn't set up right."**
A lot of wasted effort came from a live check failing and nobody being sure
whether it was a real bug or a misconfigured environment — so agents chased the
wrong thing for hours. Every live check should clearly report which of the two
it is (real defect → fix the code; setup/infra problem → fix the environment),
and must never default an unknown failure to "product bug."

**5. Make the final "it's proven, we're go" sign-off its own tiny job.**
The launch sign-off keeps not happening partly because it's always the last
thing after a long grind, so it gets dropped. Give it its own small, dedicated
slot that runs after everything else is green — never buried at the tail of a
broad build lane.

## One sentence

Agents run free locally; **live work should be small, deployed continuously,
watched by a person, on an environment you made reliable first** — and that
alone removes most of the headaches.

## Note

The general versions of principles 3–5 (terminal/sign-off work getting dropped;
distinguishing environment vs. code failure) are recurring across projects and
are good candidates for a matt/supervisor process suggestion
(`mike_dev/pp/matt_suggest.md`) if we decide to fix them at the system level,
not just for fjcloud.
