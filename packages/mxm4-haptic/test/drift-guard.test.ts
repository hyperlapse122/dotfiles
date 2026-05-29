import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import {
  sendCommand,
  waveformId,
  waveformNames,
  WAVEFORMS,
  SocketMissingError,
  XdgRuntimeDirUnsetError,
  UnknownWaveformError,
  HapticTimeoutError,
  ConnectionRefusedError,
} from "../src/index.ts";

const rustSrc = new URL("../../../crates/mxm4-haptic/src/lib.rs", import.meta.url);
const rustSource = readRustSource(rustSrc);

if (rustSource === undefined) {
  test("WAVEFORMS parity with Rust source", { skip: "Rust source not present; package is self-contained" }, () => {});
} else {
  test("WAVEFORMS parity with Rust source", () => {
    const rustWaveforms = parseRustWaveforms(rustSource);
    const tsWaveforms = new Map(WAVEFORMS);

    assert.equal(rustWaveforms.size, 16);
    assert.equal(rustWaveforms.size, tsWaveforms.size);
    assert.deepEqual([...rustWaveforms.keys()].sort(), [...tsWaveforms.keys()].sort());

    for (const [name, id] of tsWaveforms) {
      assert.equal(rustWaveforms.get(name), id);
    }

    assert.equal(rustWaveforms.get("WHISPER COLLISION"), 27);
  });
}

function readRustSource(sourceUrl: URL): string | undefined {
  try {
    return readFileSync(sourceUrl, "utf8");
  } catch (error) {
    if (hasErrorCode(error, "ENOENT")) {
      return undefined;
    }

    throw error;
  }
}

function parseRustWaveforms(source: string): Map<string, number> {
  const waveforms = new Map<string, number>();
  const tuplePattern = /\("([^"]+)",\s*(\d+)\)/g;

  for (const match of source.matchAll(tuplePattern)) {
    const name = match[1];
    const id = match[2];
    assert.ok(name);
    assert.ok(id);

    waveforms.set(name, Number(id));
  }

  return waveforms;
}

function hasErrorCode(error: unknown, code: string): boolean {
  return error instanceof Error && "code" in error && error.code === code;
}
