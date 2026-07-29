import fs from "node:fs";
import path from "node:path";

/**
 * Minimal .env loader (no dependency). Node does not read .env automatically,
 * so without this the server would run with the default secret below and
 * reject every device registration. Populates process.env for any key not
 * already set in the real environment. Run from the "Server App" dir so ./.env
 * resolves correctly.
 */
function loadDotEnv() {
  try {
    const envPath = path.resolve(".env");
    if (!fs.existsSync(envPath)) return;
    for (const raw of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
      const line = raw.trim();
      if (!line || line.startsWith("#")) continue;
      const eq = line.indexOf("=");
      if (eq === -1) continue;
      const key = line.slice(0, eq).trim();
      let val = line.slice(eq + 1).trim();
      if (
        (val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))
      ) {
        val = val.slice(1, -1);
      }
      if (!(key in process.env)) process.env[key] = val;
    }
  } catch {
    /* ignore malformed .env */
  }
}

loadDotEnv();

/** Runtime configuration, read from environment with sensible dev defaults. */
export const config = {
  port: Number(process.env.PORT ?? 8787),
  dataDir: path.resolve(process.env.DATA_DIR ?? "./data"),
  registrationSecret: process.env.REGISTRATION_SECRET ?? "change-me-to-a-long-random-string",
};

export const paths = {
  db: () => path.join(config.dataDir, "sms.sqlite"),
  media: () => path.join(config.dataDir, "media"),
};
