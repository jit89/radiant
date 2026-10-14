// Tier 2 reference: written from the spec before any implementation, imports
// nothing from either fixture. Prints each computed expectation.
const sortMinutes = [60, 25, 9].slice().sort((a, b) => a - b);          // numeric
const sortMinutesHand = [60, 25, 9].slice().sort();                      // the plausible hand slip
const label = "go\u{1F680}";
const labelWidth = Array.from(label).length;                            // code points
const labelWidthHand = label.length;                                     // UTF-16 units
const dayStartUtc = Date.UTC(2026, 9, 14);                               // TZ=UTC start of 2026-10-14
const dayStartHand = Date.parse("2026-10-14");                           // date-only parse: UTC midnight
const scaled = { hours: 0 * -1, minutes: 5 * -1, label: undefined };    // scale(0h5m, -1), computed
console.log(JSON.stringify({ sortMinutes, sortMinutesHand, labelWidth, labelWidthHand,
  dayStartUtc, dayStartHand, tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
  scaledHoursIsNegZero: Object.is(scaled.hours, -0), hasLabelKey: "label" in scaled }));
