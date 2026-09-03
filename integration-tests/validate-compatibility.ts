import { access, readFile } from "node:fs/promises";
import Ajv2020 from "ajv/dist/2020";

type Entry = {
  path?: string;
  id?: string;
  status: string;
  verification: string;
  reason?: string;
};

const schema = JSON.parse(await readFile("docs/compatibility-manifest.schema.json", "utf8"));
const manifest = JSON.parse(await readFile("docs/compatibility-manifest.json", "utf8"));
const ajv = new Ajv2020({ allErrors: true, strict: false });
const validate = ajv.compile(schema);
if (!validate(manifest)) {
  throw new Error(`compatibility manifest schema failure: ${ajv.errorsText(validate.errors)}`);
}

const entries: Entry[] = [...manifest.commands, ...manifest.additionalBehavior];
for (const entry of entries) {
  const name = entry.path ?? entry.id ?? "unknown entry";
  if (entry.status === "unimplemented" || entry.status === "partial") {
    throw new Error(`${name} has stale release status ${entry.status}`);
  }
  if (entry.status === "intentional-deviation" && !entry.reason?.trim()) {
    throw new Error(`${name} is an intentional deviation without a rationale`);
  }
  const verificationPath = entry.verification.split("#", 1)[0];
  await access(verificationPath);
}

console.log(
  `Compatibility manifest passed: ${entries.length} entries are verified and release-classified.`,
);
