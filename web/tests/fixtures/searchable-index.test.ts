// Keep a fixture-adjacent test entrypoint while reusing the single canonical
// test implementation under src/, which is where vitest's include pattern runs.
import '../../src/tests/searchable-index-fixture.test';
