import { readdir } from "node:fs/promises";
import { join } from "node:path";
import Ajv2020 from "ajv/dist/2020";

const root = process.env.AUDIBLE_TUI_ROOT ?? process.cwd();
const protocolDir = join(root, "protocol");
const version = (await Bun.file(join(protocolDir, "VERSION")).text()).trim();
if (version !== "1") throw new Error(`unsupported protocol VERSION ${version}`);

const schemaDir = join(protocolDir, "schema");
const fixtureDir = join(protocolDir, "fixtures");
const schemaNames = (await readdir(schemaDir)).filter((name) => name.endsWith(".json"));
const fixtureNames = (await readdir(fixtureDir)).filter((name) => name.endsWith(".json"));
if (schemaNames.length === 0) throw new Error("schema contains no JSON files");
if (fixtureNames.length === 0) throw new Error("fixtures contains no JSON files");

const ajv = new Ajv2020({ allErrors: true, strict: true });
const schemas = new Map<string, Record<string, unknown>>();
for (const name of schemaNames) {
  const schema = await readObject(join(schemaDir, name), `schema/${name}`);
  schemas.set(name, schema);
  ajv.addSchema(schema);
}

for (const [name, schema] of schemas) {
  try {
    ajv.compile(schema);
  } catch (error) {
    throw new Error(`schema/${name} failed to compile: ${String(error)}`);
  }
}

for (const name of fixtureNames) {
  const fixture = await readObject(join(fixtureDir, name), `fixtures/${name}`);
  const schemaName = name.endsWith(".request.json")
    ? "request.schema.json"
    : name.endsWith(".response.json")
      ? "response.schema.json"
      : name.endsWith(".event.json")
        ? "event.schema.json"
        : undefined;
  if (!schemaName) throw new Error(`fixtures/${name} has no schema-routing suffix`);
  const schema = schemas.get(schemaName)!;
  const validate = ajv.getSchema(schema.$id as string) ?? ajv.compile(schema);
  if (!validate(fixture)) {
    throw new Error(
      `fixtures/${name} violates ${schemaName}: ${ajv.errorsText(validate.errors, { separator: "; " })}`,
    );
  }
  if (schemaName === "request.schema.json") validateMethodParams(fixture, name);
}

console.log(
  `protocol v${version}: ${schemaNames.length} schemas compiled; ${fixtureNames.length} fixtures validated`,
);

async function readObject(path: string, label: string): Promise<Record<string, unknown>> {
  const value = await Bun.file(path).json();
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must contain a JSON object`);
  }
  return value as Record<string, unknown>;
}

function validateMethodParams(request: Record<string, unknown>, fixtureName: string): void {
  const methodDefinitions: Record<string, string> = {
    "profile.select": "profileSelect",
    "profile.remove": "profileRemove",
    "library.list": "libraryQuery",
    "library.search": "librarySearch",
    "library.refresh": "libraryRefresh",
    "downloads.start": "downloadStart",
    "downloads.cancel": "downloadCancel",
    "wishlist.list": "wishlistList",
    "wishlist.add": "wishlistMutation",
    "wishlist.remove": "wishlistMutation",
    "player.command": "playerCommand",
    cancel: "cancel",
  };
  const method = request.method;
  if (typeof method !== "string") return;
  const definition = methodDefinitions[method];
  if (!definition) return;
  const methodsSchema = schemas.get("methods.schema.json")!;
  const validate = ajv.getSchema(`${String(methodsSchema.$id)}#/$defs/${definition}`);
  if (!validate) throw new Error(`method schema ${definition} was not registered`);
  const params = request.params ?? {};
  if (!validate(params)) {
    throw new Error(
      `fixtures/${fixtureName} params violate methods.schema.json#/$defs/${definition}: ${ajv.errorsText(validate.errors, { separator: "; " })}`,
    );
  }
}
