import assert from "node:assert/strict";
import { describe, test } from "bun:test";

import { WAVEFORMS } from "../src/index.ts";

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

describe("WAVEFORMS", () => {
  test("lists the waveforms in firmware source order", () => {
    assert.deepEqual(WAVEFORMS, expectedWaveforms);
  });

  test("exposes the exact id table", () => {
    assert.equal(WAVEFORMS.length, 16);

    const byName = new Map(WAVEFORMS);
    for (const [name, id] of expectedWaveforms) {
      assert.equal(byName.get(name), id);
    }
  });

  test("preserves the WHISPER COLLISION firmware gap", () => {
    // Guards the firmware enum gap: WHISPER COLLISION is 27, not 15.
    const ids = WAVEFORMS.map(([, id]) => Number(id));
    assert.equal(Math.max(...ids), 27);
    assert.equal(ids.includes(15), false);
  });
});
