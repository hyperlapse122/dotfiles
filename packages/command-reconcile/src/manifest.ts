import { readFile } from "node:fs/promises";

export type ProducerClass = "external" | "source" | "build" | "existingTree";
export type SafetyProfile = "native-single-file" | "interpreted" | "multi-file" | "mutable-tree";
export type Privacy = "public" | "secret";

export interface CommandEntry {
  name: string;
  relPath?: string;
  mode?: string | number;
}

export interface UnitManifest {
  id: string;
  producer: ProducerClass;
  safetyProfile: SafetyProfile;
  proofEligible: boolean;
  mutableTree: boolean;
  privacy: Privacy;
  mode: string | number;
  commands: CommandEntry[];
  identity: string;
  stagingPath: string;
  treePath?: string;
  legacy?: {
    path?: string;
    owner?: string;
  };
}

export interface CommandManifest {
  schemaVersion: "command-manifest/v1";
  units: UnitManifest[];
}

export function parseManifest(raw: string): CommandManifest {
  const parsed = JSON.parse(raw) as unknown;
  if (!parsed || typeof parsed !== "object") {
    throw new Error("Invalid command manifest: root must be an object");
  }
  const obj = parsed as Record<string, unknown>;
  if (obj["schemaVersion"] !== "command-manifest/v1") {
    throw new Error(`Unsupported manifest schema version: ${String(obj["schemaVersion"])}`);
  }
  if (!Array.isArray(obj["units"])) {
    throw new Error("Invalid command manifest: units must be an array");
  }
  const units: UnitManifest[] = [];
  for (const item of obj["units"]) {
    if (!item || typeof item !== "object") {
      throw new Error("Invalid command manifest unit: must be an object");
    }
    const u = item as Record<string, unknown>;
    if (typeof u["id"] !== "string" || !u["id"] || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(u["id"])) {
      throw new Error(`Invalid unit id: ${String(u["id"])}`);
    }
    if (
      u["producer"] !== "external" &&
      u["producer"] !== "source" &&
      u["producer"] !== "build" &&
      u["producer"] !== "existingTree"
    ) {
      throw new Error(`Unit ${u["id"]} has invalid producer: ${String(u["producer"])}`);
    }
    if (
      u["safetyProfile"] !== "native-single-file" &&
      u["safetyProfile"] !== "interpreted" &&
      u["safetyProfile"] !== "multi-file" &&
      u["safetyProfile"] !== "mutable-tree"
    ) {
      throw new Error(`Unit ${u["id"]} has invalid safetyProfile: ${String(u["safetyProfile"])}`);
    }
    if (!Array.isArray(u["commands"]) || u["commands"].length === 0) {
      throw new Error(`Unit ${u["id"]} must declare at least one command`);
    }
    const commands: CommandEntry[] = [];
    for (const c of u["commands"]) {
      if (
        !c ||
        typeof c !== "object" ||
        typeof (c as Record<string, unknown>)["name"] !== "string"
      ) {
        throw new Error(`Unit ${u["id"]} has invalid command entry`);
      }
      const ce = c as Record<string, unknown>;
      const cmdName = ce["name"] as string;
      if (!/^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(cmdName)) {
        throw new Error(`Unit ${u["id"]} has invalid command name: ${cmdName}`);
      }
      const relPath = typeof ce["relPath"] === "string" ? ce["relPath"] : undefined;
      if (
        relPath &&
        (relPath.startsWith("/") || relPath.includes("..") || relPath.includes("\\"))
      ) {
        throw new Error(`Unit ${u["id"]} command ${cmdName} has invalid relPath: ${relPath}`);
      }
      commands.push({
        name: cmdName,
        ...(relPath ? { relPath } : {}),
        ...(ce["mode"] !== undefined ? { mode: ce["mode"] as string | number } : {}),
      });
    }
    units.push({
      id: u["id"],
      producer: u["producer"] as ProducerClass,
      safetyProfile: u["safetyProfile"] as SafetyProfile,
      proofEligible: Boolean(u["proofEligible"]),
      mutableTree: Boolean(u["mutableTree"]),
      privacy: u["privacy"] === "secret" ? "secret" : "public",
      mode: (u["mode"] as string | number) ?? "0755",
      commands,
      identity: typeof u["identity"] === "string" ? u["identity"] : "",
      stagingPath: typeof u["stagingPath"] === "string" ? u["stagingPath"] : "",
      ...(typeof u["treePath"] === "string" ? { treePath: u["treePath"] } : {}),
      ...(u["legacy"] && typeof u["legacy"] === "object"
        ? { legacy: u["legacy"] as { path?: string; owner?: string } }
        : {}),
    });
  }
  return { schemaVersion: "command-manifest/v1", units };
}

export async function loadManifest(filePathOrJson: string): Promise<CommandManifest> {
  const trimmed = filePathOrJson.trim();
  if (trimmed.startsWith("{")) {
    return parseManifest(trimmed);
  }
  const content = await readFile(filePathOrJson, "utf-8");
  return parseManifest(content);
}
