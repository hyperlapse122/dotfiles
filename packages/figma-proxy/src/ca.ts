import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface CAConfig {
  caDir?: string;
}

export interface CertKeyPair {
  cert: string;
  key: string;
}

const certCache = new Map<string, CertKeyPair>();

export function getDefaultCADir(): string {
  return join(homedir(), ".local", "share", "figma-proxy");
}

export function ensureRootCA(caDir: string = getDefaultCADir()): {
  certPath: string;
  keyPath: string;
} {
  mkdirSync(caDir, { recursive: true, mode: 0o700 });

  const certPath = join(caDir, "ca.crt");
  const keyPath = join(caDir, "ca.key");

  if (!existsSync(certPath) || !existsSync(keyPath)) {
    execFileSync(
      "openssl",
      [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-sha256",
        "-days",
        "3650",
        "-nodes",
        "-keyout",
        keyPath,
        "-out",
        certPath,
        "-subj",
        "/CN=Figma Proxy Local CA/O=h82",
      ],
      { stdio: "pipe" },
    );
    chmodSync(keyPath, 0o600);
  }

  return { certPath, keyPath };
}

export function getHostCertificate(
  hostname: string,
  caDir: string = getDefaultCADir(),
): CertKeyPair {
  const cached = certCache.get(hostname);
  if (cached) return cached;

  const { certPath: caCertPath, keyPath: caKeyPath } = ensureRootCA(caDir);
  const certsDir = join(caDir, "certs");
  mkdirSync(certsDir, { recursive: true, mode: 0o700 });

  const hostCertPath = join(certsDir, `${hostname}.crt`);
  const hostKeyPath = join(certsDir, `${hostname}.key`);

  if (!existsSync(hostCertPath) || !existsSync(hostKeyPath)) {
    const hostCsrPath = join(certsDir, `${hostname}.csr`);
    const extFilePath = join(certsDir, `${hostname}.ext`);

    try {
      execFileSync("openssl", ["genrsa", "-out", hostKeyPath, "2048"], { stdio: "pipe" });
      chmodSync(hostKeyPath, 0o600);

      execFileSync(
        "openssl",
        ["req", "-new", "-key", hostKeyPath, "-subj", `/CN=${hostname}`, "-out", hostCsrPath],
        { stdio: "pipe" },
      );

      const extContent = `basicConstraints=CA:FALSE\nsubjectAltName=DNS:${hostname}\n`;
      writeFileSync(extFilePath, extContent, "utf-8");

      execFileSync(
        "openssl",
        [
          "x509",
          "-req",
          "-in",
          hostCsrPath,
          "-CA",
          caCertPath,
          "-CAkey",
          caKeyPath,
          "-CAcreateserial",
          "-out",
          hostCertPath,
          "-days",
          "365",
          "-sha256",
          "-extfile",
          extFilePath,
        ],
        { stdio: "pipe" },
      );
    } finally {
      // Clean up temporary files if they exist
      try {
        if (existsSync(hostCsrPath)) {
          execFileSync("rm", ["-f", hostCsrPath]);
        }
        if (existsSync(extFilePath)) {
          execFileSync("rm", ["-f", extFilePath]);
        }
      } catch {
        // Ignore cleanup error
      }
    }
  }

  const cert = readFileSync(hostCertPath, "utf-8");
  const key = readFileSync(hostKeyPath, "utf-8");
  const pair: CertKeyPair = { cert, key };
  certCache.set(hostname, pair);
  return pair;
}
