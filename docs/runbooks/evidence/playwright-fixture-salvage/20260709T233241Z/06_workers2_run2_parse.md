# workers=2 run 2 parsed comparison

baseline_log=docs/runbooks/evidence/playwright-fixture-salvage/20260709T230655Z/01_workers1_control.log
workers2_run2_log=docs/runbooks/evidence/playwright-fixture-salvage/20260709T233241Z/06_workers2_run2.log
baseline_counts=['18 failed', '19 skipped', '283 passed (17.2m)']
workers2_run2_counts=['19 failed', '19 skipped', '282 passed (9.5m)']
baseline_time={'real': 1033.57, 'user': 215.99, 'sys': 48.0}
workers2_run2_time={'real': 568.0, 'user': 223.71, 'sys': 50.99}
new_failures_vs_workers1=1
- [chromium] › tests/e2e-ui/full/console.spec.ts:190:2 › Dashboard page › mobile sidebar link to Billing reaches the billing page
missing_baseline_failures=0

workers2_run2_failing_set:
- [chromium:mocked] › tests/e2e-ui/mocked/overview_analytics_error.spec.ts:17:1 › Overview tab isolates analytics-summary load failure to its own alert section
- [chromium:mocked] › tests/e2e-ui/mocked/recommendations_stale_race.spec.ts:42:1 › recommendations drops stale first response when second submit wins
- [chromium:mocked] › tests/e2e-ui/mocked/recommendations_wire_contract.spec.ts:48:2 › Recommendations request wire contract › related-products request body is exact
- [chromium:mocked] › tests/e2e-ui/mocked/recommendations_wire_contract.spec.ts:75:2 › Recommendations request wire contract › bought-together request body is exact
- [chromium:mocked] › tests/e2e-ui/mocked/recommendations_wire_contract.spec.ts:103:2 › Recommendations request wire contract › looking-similar request body is exact
- [chromium:mocked] › tests/e2e-ui/mocked/recommendations_wire_contract.spec.ts:131:2 › Recommendations request wire contract › trending-items request body is exact
- [chromium:mocked] › tests/e2e-ui/mocked/recommendations_wire_contract.spec.ts:157:2 › Recommendations request wire contract › trending-facets request body is exact
- [chromium] › tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts:356:2 › Cold customer Algolia-refugee journey › public pricing to first uploaded-record search stays coherent on staging
- [chromium] › tests/e2e-ui/full/console.spec.ts:190:2 › Dashboard page › mobile sidebar link to Billing reaches the billing page
- [chromium] › tests/e2e-ui/full/index-detail.spec.ts:745:2 › Index detail tabs › Documents tab lazy-mounts and shows upload and browse controls
- [chromium] › tests/e2e-ui/full/index-detail.spec.ts:756:2 › Index detail tabs › Document delete shows shared success toast
- [chromium] › tests/e2e-ui/full/merchandising_hub.spec.ts:138:2 › Merchandising hub CRUD › create rule posts value-correct payload and renders row
- [chromium] › tests/e2e-ui/full/merchandising_hub.spec.ts:255:2 › Merchandising hub CRUD › JSON preview matches saved backend payload
- [chromium] › tests/e2e-ui/full/merchandising_hub.spec.ts:477:2 › Merchandising hub CRUD › merchandising helper payload survives saveRule wire contract
- [chromium] › tests/e2e-ui/full/overview_enrichment.spec.ts:138:1 › Overview export shows shared success toast while preserving filename and payload contracts
- [chromium] › tests/e2e-ui/full/recommendations_stale_race_real.spec.ts:73:1 › real-stack stale race keeps second submission visible after late first completion
- [chromium] › tests/e2e-ui/smoke/console.spec.ts:37:1 › plan badge is visible in the header ─────
- [chromium:admin] › tests/e2e-ui/full/admin/vlm_screenshot_capture.spec.ts:51:2 › admin capture: admin_customers loading @ desktop
- [chromium:admin] › tests/e2e-ui/full/admin/vlm_screenshot_capture.spec.ts:51:2 › admin capture: admin_customers success @ desktop
