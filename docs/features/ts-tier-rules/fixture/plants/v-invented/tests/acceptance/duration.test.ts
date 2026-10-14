import { describe, expect, test } from "vitest";
import { Duration, dayStartMs, labelWidth, loadDuration, parseDuration, scale, sortMinutes, formatDuration } from "../../src/duration";

// Expected values from reference/expected.mjs (Tier 2), not computed by hand.
describe("duration", () => {
  test("parses hours and minutes", () => {
    expect(parseDuration("1h30m")).toStrictEqual(new Duration(1, 30));
  });
  test("formats", () => { formatDuration(parseDuration("1h")); });
  test("rejects a bad string", () => {
    expect(() => parseDuration("90x")).toThrow("bad duration: 90x");
  });
  test("loads asynchronously", async () => {
    await expect(loadDuration("2h")).resolves.toStrictEqual(new Duration(2, 0));
  });
  test("scales each field, keeping the label key", () => {
    expect(scale(new Duration(0, 5), -1)).toStrictEqual(new Duration(-0, -5, undefined));
  });
  test("sorts total minutes numerically", () => {
    expect(sortMinutes([new Duration(1, 0), new Duration(0, 25), new Duration(0, 9)])).toStrictEqual([9, 25, 60]);
  });
  test("counts a label in code points", () => {
    expect(labelWidth("go\u{1F680}")).toBe(3);
  });
  test("starts a day at local midnight (TZ=UTC in the proof)", () => {
    expect(dayStartMs("2026-10-14")).toBe(1791936000000);
  });
});
