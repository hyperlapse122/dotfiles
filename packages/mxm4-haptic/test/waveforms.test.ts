import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { waveformId, waveformNames, WAVEFORMS } from "../src/index.ts";

const expectedWaveforms = [
  ["SHARP STATE CHANGE", 0],
  ["DAMP STATE CHANGE", 1],
  ["SHARP COLLISION", 2],
  ["DAMP COLLISION", 3],
  ["SUBTLE COLLISION", 4],
  ["HAPPY ALERT", 5],
  ["ANGRY ALERT", 6],
  ["COMPLETED", 7],
  ["SQUARE", 8],
  ["WAVE", 9],
  ["FIREWORK", 10],
  ["MAD", 11],
  ["KNOCK", 12],
  ["JINGLE", 13],
  ["RINGING", 14],
  ["WHISPER COLLISION", 27],
] as const;

describe("waveform lookup", () => {
  test("waveformNames returns the source order", () => {
    assert.deepEqual(
      waveformNames(),
      expectedWaveforms.map(([name]) => name),
    );
  });

  test("waveformId is case-insensitive", () => {
    assert.equal(waveformId("subtle collision"), 4);
    assert.equal(waveformId("Subtle Collision"), 4);
  });

  test("waveformId preserves the WHISPER COLLISION firmware gap", () => {
    // Guards the firmware enum gap: WHISPER COLLISION is 27, not 15.
    assert.equal(waveformId("WHISPER COLLISION"), 27);
  });

  test("waveformId returns undefined for unknown names", () => {
    assert.equal(waveformId("nope"), undefined);
  });

  test("WAVEFORMS exposes the exact id table", () => {
    assert.equal(WAVEFORMS.length, 16);

    const byName = new Map(WAVEFORMS);
    for (const [name, id] of expectedWaveforms) {
      assert.equal(byName.get(name), id);
    }

    const ids = WAVEFORMS.map(([, id]) => Number(id));
    assert.equal(Math.max(...ids), 27);
    assert.equal(ids.includes(15), false);
  });
});
