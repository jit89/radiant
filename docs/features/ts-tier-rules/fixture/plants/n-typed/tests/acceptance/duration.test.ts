import { test } from "node:test";
import assert from "node:assert/strict";
import { Duration, dayStartMs, labelWidth, loadDuration, parseDuration, scale, sortMinutes } from "../../src/duration.ts";

// Expected values from reference/expected.mjs (Tier 2), not computed by hand.
test("parses hours and minutes", () => {
  assert.deepStrictEqual(parseDuration("1h30m"), new Duration(1, 30));
});
test("rejects a bad string", () => {
  assert.throws(() => parseDuration("90x"), { message: "bad duration: 90x" });
});
test("loads asynchronously", async () => {
  assert.deepStrictEqual(await loadDuration("2h"), new Duration(2, 0));
});
test("scales each field, keeping the label key", () => {
  assert.deepStrictEqual(scale(new Duration(0, 5), "-1"), new Duration(-0, -5, undefined));
});
test("sorts total minutes numerically", () => {
  assert.deepStrictEqual(sortMinutes([new Duration(1, 0), new Duration(0, 25), new Duration(0, 9)]), [9, 25, 60]);
});
test("counts a label in code points", () => {
  assert.equal(labelWidth("go\u{1F680}"), 3);
});
test("starts a day at local midnight (TZ=UTC in the proof)", () => {
  assert.equal(dayStartMs("2026-10-14"), 1791936000000);
});
