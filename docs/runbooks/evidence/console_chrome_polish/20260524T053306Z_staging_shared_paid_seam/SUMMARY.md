# Console Chrome Polish Stage 2 Evidence

- Spec path: 
- Target command: 
Running 1 test using 1 worker

  ✘  1 [chromium] › tests/e2e-ui/full/console_chrome_polish.spec.ts:51:2 › Console chrome polish shared-to-paid seam › staging seam shows shared API plan with paid console chrome and migrated shell elements (70ms)


  1) [chromium] › tests/e2e-ui/full/console_chrome_polish.spec.ts:51:2 › Console chrome polish shared-to-paid seam › staging seam shows shared API plan with paid console chrome and migrated shell elements 

    TypeError: fetch failed
    [cause]: AggregateError: 

    attachment #1: screenshot (image/png) ──────────────────────────────────────────────────────────
    test-results/e2e-ui-full-console_chrome-d13c2-and-migrated-shell-elements-chromium/test-failed-1.png
    ────────────────────────────────────────────────────────────────────────────────────────────────

  1 failed
    [chromium] › tests/e2e-ui/full/console_chrome_polish.spec.ts:51:2 › Console chrome polish shared-to-paid seam › staging seam shows shared API plan with paid console chrome and migrated shell elements 
- Host pair: , , 
- Result: **RED (seam still broken in deployed staging)**

## Pass/Fail by seam requirement
-  payload contains : PASS (spec reached plan-badge assertion stage after shared-plan setup).
-  renders : FAIL ( rendered ).
-  visible with  link: NOT REACHED due earlier assertion failure.
- Legacy hook  absent in active shell: PASS ( has no matches under  or ; only spec assertion reference).
- Footer links (, , , ) visible in console: NOT REACHED due earlier assertion failure.

## Artifacts
- : full command output including pre-create marker and failure stack.
- : focused grep proving no active-shell legacy hook emission.
- : copied failing Playwright artifact directory when present.
