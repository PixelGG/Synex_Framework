import { lstat, realpath } from "node:fs/promises";
import { resolve } from "node:path";

import type { Diagnostic } from "./types.ts";
import { CliError } from "./errors.ts";
import {
  compareText,
  containsPath,
  displayPath,
  isRecord,
  readTextFile,
  resolveWithin,
} from "./filesystem.ts";
import type { SchemaRegistry } from "./schemas.ts";
import { schemaDiagnostics } from "./schemas.ts";

const MAX_WORLD_BUNDLES = 1_024;
const MAX_WORLD_OBJECTS = 100_000;
const MAX_GRAPH_RESULTS = 256;
const MAX_LOCATE_RESULTS = 64;
const MAX_OVERLAP_RESULTS = 256;
const MAX_OVERLAP_COMPARISONS = 200_000;
const MAX_GEOMETRY_DEPTH = 4;
const MINIMUM_GEOMETRY_EXTENT = 0.001;
const MAX_STATE_BYTES = 16_384;
const MAX_STRUCTURED_DEPTH = 4;
const MAX_STRUCTURED_ENTRIES = 64;
const MAX_STRUCTURED_PROPERTIES = 32;
const MAX_STRUCTURED_ARRAY_ITEMS = 64;
const MAX_STRUCTURED_SCHEMA_NODES = 64;
const SEGMENT_EPSILON = 0.000000001;

export interface WorldManifestSource {
  file: string;
  directory: string;
  manifest: {
    name: string;
    worldBundles?: string[];
  };
}

export interface WorldObjectRecord {
  key: string;
  kind: string;
  ownerResource: string;
  bundleKey: string;
  bundleFile: string;
  definition: Record<string, unknown>;
}

export interface WorldBundleRecord {
  key: string;
  version: string;
  ownerResource: string;
  file: string;
  dependencies: string[];
  objects: WorldObjectRecord[];
}

export interface WorldCatalog {
  bundles: WorldBundleRecord[];
  objects: Map<string, WorldObjectRecord>;
  diagnostics: Diagnostic[];
  declaredBundleFiles: number;
}

interface OwnedDiagnostic extends Diagnostic {
  owners: string[];
}

interface Vector2 {
  x: number;
  y: number;
}

interface Vector3 extends Vector2 {
  z: number;
}

interface Bounds {
  minimum: Vector3;
  maximum: Vector3;
}

interface OverlapFinding {
  left: string;
  right: string;
  parent: string | null;
  approximate: boolean;
}

export type WorldReportStatus = "PASS" | "WARN" | "FAIL" | "UNKNOWN";

function asRecord(value: unknown): Record<string, unknown> | null {
  return isRecord(value) ? value : null;
}

function asVector2(value: unknown): Vector2 | null {
  const record = asRecord(value);
  return record && typeof record.x === "number" && typeof record.y === "number"
    ? { x: record.x, y: record.y }
    : null;
}

function asVector3(value: unknown): Vector3 | null {
  const record = asRecord(value);
  return record && typeof record.x === "number" && typeof record.y === "number"
    && typeof record.z === "number"
    ? { x: record.x, y: record.y, z: record.z }
    : null;
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string") : [];
}

function keyNamespace(key: string): string {
  return key.slice(0, Math.max(0, key.indexOf(":")));
}

function uint32(value: number): number {
  return value >>> 0;
}

function derivedDoorHash(doorKey: string, leafId: string): number {
  let accumulator = 2_166_136_261;
  for (const byte of Buffer.from(`${doorKey}:${leafId}`, "utf8")) {
    accumulator = uint32(Math.imul(uint32(accumulator ^ byte), 16_777_619));
  }
  return accumulator;
}

function diagnostic(
  owners: string[],
  level: Diagnostic["level"],
  rule: string,
  file: string,
  message: string,
): OwnedDiagnostic {
  return { owners, level, rule, file, message };
}

function includeDiagnostic(
  finding: OwnedDiagnostic,
  selectedResources: ReadonlySet<string> | undefined,
): boolean {
  return selectedResources === undefined
    || finding.owners.some((owner) => selectedResources.has(owner));
}

function plainDiagnostic(finding: OwnedDiagnostic): Diagnostic {
  const { owners: _owners, ...result } = finding;
  return result;
}

function pointEquals(left: Vector2, right: Vector2): boolean {
  return left.x === right.x && left.y === right.y;
}

function orientation(first: Vector2, second: Vector2, third: Vector2): number {
  return ((second.y - first.y) * (third.x - second.x))
    - ((second.x - first.x) * (third.y - second.y));
}

function onSegment(first: Vector2, second: Vector2, candidate: Vector2): boolean {
  return candidate.x <= Math.max(first.x, second.x)
    && candidate.x >= Math.min(first.x, second.x)
    && candidate.y <= Math.max(first.y, second.y)
    && candidate.y >= Math.min(first.y, second.y);
}

function segmentsIntersect(a: Vector2, b: Vector2, c: Vector2, d: Vector2): boolean {
  const first = orientation(a, b, c);
  const second = orientation(a, b, d);
  const third = orientation(c, d, a);
  const fourth = orientation(c, d, b);
  if (((first > 0 && second < 0) || (first < 0 && second > 0))
    && ((third > 0 && fourth < 0) || (third < 0 && fourth > 0))) {
    return true;
  }
  return (Math.abs(first) <= SEGMENT_EPSILON && onSegment(a, b, c))
    || (Math.abs(second) <= SEGMENT_EPSILON && onSegment(a, b, d))
    || (Math.abs(third) <= SEGMENT_EPSILON && onSegment(c, d, a))
    || (Math.abs(fourth) <= SEGMENT_EPSILON && onSegment(c, d, b));
}

function polygonSemanticError(vertices: Vector2[]): string | null {
  let signedArea = 0;
  for (let index = 0; index < vertices.length; index += 1) {
    const current = vertices[index];
    const next = vertices[(index + 1) % vertices.length];
    if (!current || !next) return "Polygon vertices are incomplete.";
    if (pointEquals(current, next)) return "Polygon contains duplicate consecutive vertices.";
    signedArea += (current.x * next.y) - (next.x * current.y);
  }
  if (Math.abs(signedArea) < MINIMUM_GEOMETRY_EXTENT) {
    return `Polygon area must be at least ${MINIMUM_GEOMETRY_EXTENT}.`;
  }
  for (let first = 0; first < vertices.length; first += 1) {
    const firstNext = (first + 1) % vertices.length;
    const a = vertices[first];
    const b = vertices[firstNext];
    if (!a || !b) continue;
    for (let second = first + 1; second < vertices.length; second += 1) {
      const secondNext = (second + 1) % vertices.length;
      if (first === second || firstNext === second || secondNext === first) continue;
      const c = vertices[second];
      const d = vertices[secondNext];
      if (c && d && segmentsIntersect(a, b, c, d)) return "Polygon edges must not self-intersect.";
    }
  }
  return null;
}

function geometrySemanticErrors(value: unknown, depth = 0): string[] {
  const geometry = asRecord(value);
  if (!geometry) return ["Geometry must be an object."];
  if (depth > MAX_GEOMETRY_DEPTH) return [`Composite geometry exceeds depth ${MAX_GEOMETRY_DEPTH}.`];
  if (geometry.type === "aabb") {
    const minimum = asVector3(geometry.min);
    const maximum = asVector3(geometry.max);
    if (minimum && maximum && (maximum.x - minimum.x < MINIMUM_GEOMETRY_EXTENT
      || maximum.y - minimum.y < MINIMUM_GEOMETRY_EXTENT
      || maximum.z - minimum.z < MINIMUM_GEOMETRY_EXTENT)) {
      return [`Axis-aligned box extents must each be at least ${MINIMUM_GEOMETRY_EXTENT}.`];
    }
  } else if (geometry.type === "polygon") {
    if (typeof geometry.minZ === "number" && typeof geometry.maxZ === "number"
      && geometry.maxZ - geometry.minZ < MINIMUM_GEOMETRY_EXTENT) {
      return [`Polygon vertical extent must be at least ${MINIMUM_GEOMETRY_EXTENT}.`];
    }
    const vertices = Array.isArray(geometry.vertices)
      ? geometry.vertices.map(asVector2).filter((entry): entry is Vector2 => entry !== null)
      : [];
    const error = polygonSemanticError(vertices);
    if (error) return [error];
  } else if (geometry.type === "composite") {
    const geometries = Array.isArray(geometry.geometries) ? geometry.geometries : [];
    return geometries.flatMap((part) => geometrySemanticErrors(part, depth + 1));
  }
  return [];
}

function geometryBounds(value: unknown, depth = 0): Bounds | null {
  if (depth > MAX_GEOMETRY_DEPTH) return null;
  const geometry = asRecord(value);
  if (!geometry) return null;
  if (geometry.type === "point") {
    const point = asVector3(geometry.position);
    return point ? { minimum: point, maximum: point } : null;
  }
  if (geometry.type === "sphere") {
    const center = asVector3(geometry.center);
    const radius = typeof geometry.radius === "number" ? geometry.radius : null;
    return center && radius !== null ? {
      minimum: { x: center.x - radius, y: center.y - radius, z: center.z - radius },
      maximum: { x: center.x + radius, y: center.y + radius, z: center.z + radius },
    } : null;
  }
  if (geometry.type === "aabb") {
    const minimum = asVector3(geometry.min);
    const maximum = asVector3(geometry.max);
    return minimum && maximum ? { minimum, maximum } : null;
  }
  if (geometry.type === "box") {
    const center = asVector3(geometry.center);
    const size = asVector3(geometry.size);
    if (!center || !size) return null;
    const heading = typeof geometry.heading === "number" ? geometry.heading * Math.PI / 180 : 0;
    const extentX = (Math.abs(Math.cos(heading)) * size.x + Math.abs(Math.sin(heading)) * size.y) / 2;
    const extentY = (Math.abs(Math.sin(heading)) * size.x + Math.abs(Math.cos(heading)) * size.y) / 2;
    return {
      minimum: { x: center.x - extentX, y: center.y - extentY, z: center.z - size.z / 2 },
      maximum: { x: center.x + extentX, y: center.y + extentY, z: center.z + size.z / 2 },
    };
  }
  if (geometry.type === "polygon") {
    const vertices = Array.isArray(geometry.vertices)
      ? geometry.vertices.map(asVector2).filter((entry): entry is Vector2 => entry !== null)
      : [];
    if (vertices.length === 0 || typeof geometry.minZ !== "number" || typeof geometry.maxZ !== "number") return null;
    return {
      minimum: {
        x: Math.min(...vertices.map((vertex) => vertex.x)),
        y: Math.min(...vertices.map((vertex) => vertex.y)),
        z: geometry.minZ,
      },
      maximum: {
        x: Math.max(...vertices.map((vertex) => vertex.x)),
        y: Math.max(...vertices.map((vertex) => vertex.y)),
        z: geometry.maxZ,
      },
    };
  }
  if (geometry.type === "composite") {
    const bounds = (Array.isArray(geometry.geometries) ? geometry.geometries : [])
      .map((part) => geometryBounds(part, depth + 1))
      .filter((entry): entry is Bounds => entry !== null);
    if (bounds.length === 0) return null;
    return {
      minimum: {
        x: Math.min(...bounds.map((entry) => entry.minimum.x)),
        y: Math.min(...bounds.map((entry) => entry.minimum.y)),
        z: Math.min(...bounds.map((entry) => entry.minimum.z)),
      },
      maximum: {
        x: Math.max(...bounds.map((entry) => entry.maximum.x)),
        y: Math.max(...bounds.map((entry) => entry.maximum.y)),
        z: Math.max(...bounds.map((entry) => entry.maximum.z)),
      },
    };
  }
  return null;
}

function pointInPolygon(point: Vector2, vertices: Vector2[]): boolean {
  let inside = false;
  for (let index = 0, previous = vertices.length - 1; index < vertices.length; previous = index, index += 1) {
    const currentVertex = vertices[index];
    const previousVertex = vertices[previous];
    if (!currentVertex || !previousVertex) continue;
    const crosses = (currentVertex.y > point.y) !== (previousVertex.y > point.y)
      && point.x < ((previousVertex.x - currentVertex.x) * (point.y - currentVertex.y)
        / (previousVertex.y - currentVertex.y)) + currentVertex.x;
    if (crosses) inside = !inside;
  }
  return inside;
}

function geometryContains(value: unknown, point: Vector3, depth = 0): boolean {
  if (depth > MAX_GEOMETRY_DEPTH) return false;
  const geometry = asRecord(value);
  if (!geometry) return false;
  if (geometry.type === "point") {
    const position = asVector3(geometry.position);
    return position !== null && point.x === position.x && point.y === position.y && point.z === position.z;
  }
  if (geometry.type === "sphere") {
    const center = asVector3(geometry.center);
    return center !== null && typeof geometry.radius === "number"
      && Math.hypot(point.x - center.x, point.y - center.y, point.z - center.z) <= geometry.radius;
  }
  if (geometry.type === "aabb") {
    const minimum = asVector3(geometry.min);
    const maximum = asVector3(geometry.max);
    return minimum !== null && maximum !== null && point.x >= minimum.x && point.x <= maximum.x
      && point.y >= minimum.y && point.y <= maximum.y && point.z >= minimum.z && point.z <= maximum.z;
  }
  if (geometry.type === "box") {
    const center = asVector3(geometry.center);
    const size = asVector3(geometry.size);
    if (!center || !size || typeof geometry.heading !== "number") return false;
    const radians = -geometry.heading * Math.PI / 180;
    const deltaX = point.x - center.x;
    const deltaY = point.y - center.y;
    const localX = (deltaX * Math.cos(radians)) - (deltaY * Math.sin(radians));
    const localY = (deltaX * Math.sin(radians)) + (deltaY * Math.cos(radians));
    return Math.abs(localX) <= size.x / 2 && Math.abs(localY) <= size.y / 2
      && Math.abs(point.z - center.z) <= size.z / 2;
  }
  if (geometry.type === "polygon") {
    if (typeof geometry.minZ !== "number" || typeof geometry.maxZ !== "number"
      || point.z < geometry.minZ || point.z > geometry.maxZ) return false;
    const vertices = Array.isArray(geometry.vertices)
      ? geometry.vertices.map(asVector2).filter((entry): entry is Vector2 => entry !== null)
      : [];
    return pointInPolygon(point, vertices);
  }
  if (geometry.type === "composite") {
    const geometries = Array.isArray(geometry.geometries) ? geometry.geometries : [];
    return geometries.some((part) => geometryContains(part, point, depth + 1));
  }
  return false;
}

function objectGeometry(object: WorldObjectRecord): unknown {
  if (["region", "location", "interior", "room", "zone"].includes(object.kind)) {
    return object.definition.geometry;
  }
  if (object.kind === "portal") {
    const source = asRecord(object.definition.source);
    return source ? { type: "sphere", center: source.position, radius: source.radius } : null;
  }
  return null;
}

function objectPosition(object: WorldObjectRecord): Vector3 | null {
  if (object.kind === "anchor" || object.kind === "door") return asVector3(object.definition.position);
  return null;
}

function expectedReferenceKind(
  catalog: WorldCatalog,
  source: WorldObjectRecord,
  reference: string,
  field: string,
  expected: ReadonlySet<string>,
  findings: OwnedDiagnostic[],
): void {
  const target = catalog.objects.get(reference);
  if (!target) {
    findings.push(diagnostic([source.ownerResource], "error", "world-reference-missing", source.bundleFile,
      `${source.key}.${field} references missing world object ${reference}.`));
  } else if (!expected.has(target.kind)) {
    findings.push(diagnostic([source.ownerResource, target.ownerResource], "error", "world-reference-kind", source.bundleFile,
      `${source.key}.${field} references ${target.kind} ${reference}; expected ${[...expected].sort(compareText).join(", ")}.`));
  }
}

function parentKinds(object: WorldObjectRecord): ReadonlySet<string> | null {
  const values: Record<string, string[]> = {
    region: ["region"],
    location: ["region"],
    interior: ["location"],
    room: ["interior"],
    zone: ["region", "location", "interior", "room"],
    anchor: ["region", "location", "interior", "room", "zone"],
    door: ["location", "interior", "room", "zone"],
    portal: ["region", "location", "interior", "room", "zone"],
    world_state_definition: ["region", "location", "interior", "room"],
  };
  return values[object.kind] ? new Set(values[object.kind]) : null;
}

interface StructuredSchemaResult {
  schema: Record<string, unknown> | null;
  error: string | null;
}

function validateStructuredSchema(value: unknown): StructuredSchemaResult {
  const schema = asRecord(value);
  if (!schema || (schema.type !== "object" && schema.type !== "array")
    || !Number.isInteger(schema.maximumBytes) || (schema.maximumBytes as number) < 1
    || (schema.maximumBytes as number) > MAX_STATE_BYTES
    || !Number.isInteger(schema.maximumDepth) || (schema.maximumDepth as number) < 1
    || (schema.maximumDepth as number) > MAX_STRUCTURED_DEPTH
    || !Number.isInteger(schema.maximumEntries) || (schema.maximumEntries as number) < 1
    || (schema.maximumEntries as number) > MAX_STRUCTURED_ENTRIES) {
    return { schema: null, error: "root bounds are invalid" };
  }

  let nodes = 0;
  const propertyName = (candidate: string): boolean => /^[A-Za-z][A-Za-z0-9_.-]{0,63}$/u.test(candidate);
  const exactKeys = (candidate: Record<string, unknown>, allowed: ReadonlySet<string>): boolean =>
    Object.keys(candidate).every((key) => allowed.has(key));
  const visit = (candidate: unknown, depth: number): string | null => {
    const node = asRecord(candidate);
    nodes += 1;
    if (!node || nodes > MAX_STRUCTURED_SCHEMA_NODES || typeof node.type !== "string") {
      return "schema node is invalid or the schema is too complex";
    }
    if (node.type === "boolean") {
      return exactKeys(node, new Set(["type"])) ? null : "boolean node contains unsupported fields";
    }
    if (node.type === "integer" || node.type === "number") {
      if (!exactKeys(node, new Set(["type", "minimum", "maximum"]))) {
        return "numeric node contains unsupported fields";
      }
      const minimum = node.minimum;
      const maximum = node.maximum;
      if (minimum !== undefined && (typeof minimum !== "number" || !Number.isFinite(minimum)
          || Math.abs(minimum) > Number.MAX_SAFE_INTEGER)
        || maximum !== undefined && (typeof maximum !== "number" || !Number.isFinite(maximum)
          || Math.abs(maximum) > Number.MAX_SAFE_INTEGER)
        || typeof minimum === "number" && typeof maximum === "number" && minimum > maximum) {
        return "numeric node bounds are invalid";
      }
      return null;
    }
    if (node.type === "string") {
      return exactKeys(node, new Set(["type", "maxLength"]))
        && Number.isInteger(node.maxLength) && (node.maxLength as number) >= 1
        && (node.maxLength as number) <= 4096 ? null : "string node bound is invalid";
    }
    if (node.type === "enum") {
      if (!exactKeys(node, new Set(["type", "allowed"])) || !Array.isArray(node.allowed)
        || node.allowed.length < 1 || node.allowed.length > 64) return "enum node is invalid";
      const seen = new Set<string>();
      for (const item of node.allowed) {
        if (typeof item !== "string" || Buffer.byteLength(item, "utf8") < 1
          || Buffer.byteLength(item, "utf8") > 128 || /[\u0000-\u001f\u007f]/u.test(item)
          || seen.has(item)) return "enum node values are invalid";
        seen.add(item);
      }
      return null;
    }
    if (node.type === "object") {
      if (depth > (schema.maximumDepth as number)
        || !exactKeys(node, new Set(["type", "properties", "required", "additionalProperties"]))
        || !isRecord(node.properties) || node.additionalProperties !== false
        || !Array.isArray(node.required) || node.required.length > MAX_STRUCTURED_PROPERTIES) {
        return "object node is invalid or too deep";
      }
      const keys = Object.keys(node.properties);
      if (keys.length > MAX_STRUCTURED_PROPERTIES || keys.some((key) => !propertyName(key))) {
        return "object properties are invalid";
      }
      const required = new Set<string>();
      for (const key of node.required) {
        if (typeof key !== "string" || !propertyName(key) || !(key in node.properties)
          || required.has(key)) return "required object properties are invalid";
        required.add(key);
      }
      for (const key of keys.sort((left, right) => left.localeCompare(right))) {
        const error = visit(node.properties[key], depth + 1);
        if (error) return error;
      }
      return null;
    }
    if (node.type === "array") {
      if (depth > (schema.maximumDepth as number)
        || !exactKeys(node, new Set(["type", "items", "maximumItems"]))
        || !Number.isInteger(node.maximumItems) || (node.maximumItems as number) < 1
        || (node.maximumItems as number) > MAX_STRUCTURED_ARRAY_ITEMS) {
        return "array node is invalid or too deep";
      }
      return visit(node.items, depth + 1);
    }
    return "schema node type is unsupported";
  };

  const rootAllowed = schema.type === "object"
    ? new Set(["type", "maximumBytes", "maximumDepth", "maximumEntries",
      "properties", "required", "additionalProperties"])
    : new Set(["type", "maximumBytes", "maximumDepth", "maximumEntries", "items", "maximumItems"]);
  if (!exactKeys(schema, rootAllowed)) return { schema: null, error: "root contains unsupported fields" };
  const root = schema.type === "object"
    ? { type: schema.type, properties: schema.properties, required: schema.required,
      additionalProperties: schema.additionalProperties }
    : { type: schema.type, items: schema.items, maximumItems: schema.maximumItems };
  const error = visit(root, 1);
  return { schema: error ? null : schema, error };
}

function structuredStateMatches(value: unknown, schema: Record<string, unknown>): boolean {
  let entries = 0;
  const visit = (candidate: unknown, node: Record<string, unknown>, depth: number): boolean => {
    if (node.type === "boolean") return typeof candidate === "boolean";
    if (node.type === "integer") {
      return typeof candidate === "number" && Number.isSafeInteger(candidate)
        && (typeof node.minimum !== "number" || candidate >= node.minimum)
        && (typeof node.maximum !== "number" || candidate <= node.maximum);
    }
    if (node.type === "number") {
      return typeof candidate === "number" && Number.isFinite(candidate)
        && Math.abs(candidate) <= Number.MAX_SAFE_INTEGER
        && (typeof node.minimum !== "number" || candidate >= node.minimum)
        && (typeof node.maximum !== "number" || candidate <= node.maximum);
    }
    if (node.type === "string") {
      return typeof candidate === "string" && Buffer.byteLength(candidate, "utf8") <= (node.maxLength as number)
        && !/[\u0000-\u001f\u007f]/u.test(candidate);
    }
    if (node.type === "enum") {
      return typeof candidate === "string" && (node.allowed as unknown[]).includes(candidate);
    }
    if (depth > (schema.maximumDepth as number)) return false;
    if (node.type === "array") {
      if (!Array.isArray(candidate) || candidate.length > (node.maximumItems as number)) return false;
      for (const item of candidate) {
        entries += 1;
        if (entries > (schema.maximumEntries as number)
          || !visit(item, node.items as Record<string, unknown>, depth + 1)) return false;
      }
      return true;
    }
    if (!isRecord(candidate) || Array.isArray(candidate)) return false;
    const properties = node.properties as Record<string, Record<string, unknown>>;
    const keys = Object.keys(candidate);
    for (const key of keys) {
      entries += 1;
      const child = properties[key];
      if (!child || entries > (schema.maximumEntries as number)
        || !visit(candidate[key], child, depth + 1)) return false;
    }
    return (node.required as string[]).every((key) => Object.hasOwn(candidate, key));
  };
  if (!visit(value, schema, 1)) return false;
  try {
    const encoded = JSON.stringify(value);
    return typeof encoded === "string"
      && Buffer.byteLength(encoded, "utf8") <= (schema.maximumBytes as number);
  } catch {
    return false;
  }
}

const stateScopeRanks: Readonly<Record<string, number>> = {
  region: 1,
  location: 2,
  interior: 3,
  room: 4,
};

function hierarchyContains(catalog: WorldCatalog, start: WorldObjectRecord, ancestorKey: string): boolean {
  let current: WorldObjectRecord | undefined = start;
  const visited = new Set<string>();
  while (current && !visited.has(current.key)) {
    if (current.key === ancestorKey) return true;
    visited.add(current.key);
    const parentKey: string | null = typeof current.definition.parent === "string"
      ? current.definition.parent : null;
    current = parentKey ? catalog.objects.get(parentKey) : undefined;
  }
  return false;
}

function scalarStateValueMatches(definition: Record<string, unknown>, value: unknown): boolean {
  const minimum = typeof definition.minimum === "number" ? definition.minimum : null;
  const maximum = typeof definition.maximum === "number" ? definition.maximum : null;
  if (definition.stateType === "boolean") return typeof value === "boolean";
  if (definition.stateType === "integer") {
    return typeof value === "number" && Number.isSafeInteger(value)
      && (minimum === null || value >= minimum) && (maximum === null || value <= maximum);
  }
  if (definition.stateType === "number") {
    return typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= Number.MAX_SAFE_INTEGER
      && (minimum === null || value >= minimum) && (maximum === null || value <= maximum);
  }
  if (definition.stateType === "string") {
    const maximumLength = typeof definition.maxLength === "number" ? definition.maxLength : 4_096;
    return typeof value === "string" && Buffer.byteLength(value, "utf8") <= maximumLength
      && Buffer.byteLength(value, "utf8") <= MAX_STATE_BYTES
      && !/[\u0000-\u001f\u007f]/u.test(value);
  }
  if (definition.stateType === "enum") {
    return typeof value === "string" && !/[\u0000-\u001f\u007f]/u.test(value)
      && Array.isArray(definition.allowed)
      && definition.allowed.some((allowed) => allowed === value);
  }
  return false;
}

function validateStateDefinition(
  catalog: WorldCatalog,
  object: WorldObjectRecord,
  findings: OwnedDiagnostic[],
): void {
  const definition = object.definition;
  const stateType = definition.stateType;
  if (typeof definition.minimum === "number" && typeof definition.maximum === "number"
    && definition.minimum > definition.maximum) {
    findings.push(diagnostic([object.ownerResource], "error", "world-state-bounds", object.bundleFile,
      `${object.key} has min greater than max.`));
  }
  const structured = stateType === "structured"
    ? validateStructuredSchema(definition.structuredSchema)
    : { schema: null, error: null };
  if (stateType === "structured" && structured.error) findings.push(diagnostic(
    [object.ownerResource], "error", "world-state-structured-schema", object.bundleFile,
    `${object.key} has an invalid structuredSchema: ${structured.error}.`));
  if (stateType === "enum" && stringArray(definition.allowed).length === 0
    && (!Array.isArray(definition.allowed) || definition.allowed.length === 0)) {
    findings.push(diagnostic([object.ownerResource], "error", "world-state-enum", object.bundleFile,
      `${object.key} requires a non-empty allowed set for enum state.`));
  }
  if (stateType === "enum" && stringArray(definition.allowed)
    .some((value) => Buffer.byteLength(value, "utf8") > 128)) {
    findings.push(diagnostic([object.ownerResource], "error", "world-string-byte-bound",
      object.bundleFile, `${object.key} enum value exceeds the 128-byte runtime limit.`));
  }
  const parentKey = typeof definition.parent === "string" ? definition.parent : null;
  const parent = parentKey ? catalog.objects.get(parentKey) : undefined;
  const scope = typeof definition.scope === "string" ? definition.scope : "";
  const scopeRank = stateScopeRanks[scope];
  const parentRank = parent ? stateScopeRanks[parent.kind] : undefined;
  if (scope === "global" && parentKey !== null
    || parent && scopeRank !== undefined && (parentRank === undefined || parentRank > scopeRank)) {
    findings.push(diagnostic([object.ownerResource], "error", "world-state-parent-scope", object.bundleFile,
      `${object.key} parent is incompatible with state scope ${scope}.`));
  }
  if (!("default" in definition)) return;
  const value = definition.default;
  const validType = stateType === "boolean" ? typeof value === "boolean"
    : stateType === "integer" ? typeof value === "number" && Number.isSafeInteger(value)
      : stateType === "number" ? typeof value === "number" && Number.isFinite(value)
          && Math.abs(value) <= Number.MAX_SAFE_INTEGER
        : stateType === "string" || stateType === "enum" ? typeof value === "string"
          && !/[\u0000-\u001f\u007f]/u.test(value)
          : stateType === "structured" ? structured.schema !== null
            && structuredStateMatches(value, structured.schema) : false;
  if (!validType) {
    findings.push(diagnostic([object.ownerResource], "error", "world-state-default-type", object.bundleFile,
      `${object.key} default does not match stateType ${String(stateType)}.`));
    return;
  }
  if (stateType !== "structured" && !scalarStateValueMatches(definition, value)) {
    findings.push(diagnostic([object.ownerResource], "error", "world-state-default-value", object.bundleFile,
      `${object.key} default does not satisfy its bounded state schema.`));
  }
  if (typeof value === "number"
    && ((typeof definition.minimum === "number" && value < definition.minimum)
      || (typeof definition.maximum === "number" && value > definition.maximum))) {
    findings.push(diagnostic([object.ownerResource], "error", "world-state-default-bounds", object.bundleFile,
      `${object.key} default is outside its numeric bounds.`));
  }
  if (typeof value === "string" && typeof definition.maxLength === "number"
    && Buffer.byteLength(value, "utf8") > definition.maxLength) {
    findings.push(diagnostic([object.ownerResource], "error", "world-state-default-length", object.bundleFile,
      `${object.key} default exceeds maxLength.`));
  }
  if (Array.isArray(definition.allowed)
    && !definition.allowed.some((allowed) => Object.is(allowed, value))) {
    findings.push(diagnostic([object.ownerResource], "error", "world-state-default-allowed", object.bundleFile,
      `${object.key} default is not present in allowed.`));
  }
}

function validateAccessStateRequirement(
  catalog: WorldCatalog,
  object: WorldObjectRecord,
  requirement: Record<string, unknown>,
  findings: OwnedDiagnostic[],
): void {
  if (typeof requirement.key !== "string") return;
  const stateObject = catalog.objects.get(requirement.key);
  if (!stateObject || stateObject.kind !== "world_state_definition") return;
  const definition = stateObject.definition;
  if (typeof requirement.value === "string"
    && Buffer.byteLength(requirement.value, "utf8") > 256) {
    findings.push(diagnostic([object.ownerResource, stateObject.ownerResource], "error",
      "world-access-state-value", object.bundleFile,
      `${object.key} state requirement string exceeds the 256-byte runtime limit.`));
  }
  const scope = typeof definition.scope === "string" ? definition.scope : "";
  const scopeRef = typeof requirement.scopeRef === "string" ? requirement.scopeRef : null;
  let scopeObject: WorldObjectRecord | undefined;
  if ((scope === "global" || scope === "instance") && scopeRef !== null) {
    findings.push(diagnostic([object.ownerResource], "error", "world-access-state-scope", object.bundleFile,
      `${object.key} state requirement ${stateObject.key} cannot use an explicit ${scope} scopeRef.`));
  } else if (scopeRef !== null) {
    expectedReferenceKind(catalog, object, scopeRef, "accessPolicy.stateRequirements.scopeRef",
      new Set([scope]), findings);
    scopeObject = catalog.objects.get(scopeRef);
  }

  const definitionParent = typeof definition.parent === "string" ? definition.parent : null;
  if (definitionParent !== null && !hierarchyContains(catalog, object, definitionParent)) {
    findings.push(diagnostic([object.ownerResource, stateObject.ownerResource], "error",
      "world-access-state-hierarchy", object.bundleFile,
      `${object.key} state requirement ${stateObject.key} is outside the target hierarchy.`));
  }
  if (definitionParent !== null && scopeObject
    && !hierarchyContains(catalog, scopeObject, definitionParent)) {
    findings.push(diagnostic([object.ownerResource, stateObject.ownerResource], "error",
      "world-access-state-hierarchy", object.bundleFile,
      `${object.key} explicit state scope ${scopeObject.key} is outside ${stateObject.key}'s hierarchy.`));
  }
  if (definition.stateType === "structured" || !scalarStateValueMatches(definition, requirement.value)) {
    findings.push(diagnostic([object.ownerResource, stateObject.ownerResource], "error",
      "world-access-state-value", object.bundleFile,
      `${object.key} state requirement value does not satisfy ${stateObject.key}.`));
  }
}

function validateWorldReferences(catalog: WorldCatalog, findings: OwnedDiagnostic[]): void {
  const portalTargets = new Set(["region", "location", "interior", "room", "zone", "anchor", "door",
    "portal", "instance_template", "map_package", "ipl_bundle", "world_state_definition"]);
  const dependenciesByBundle = new Map(catalog.bundles.map((bundle) => [bundle.key, new Set(bundle.dependencies)]));
  const doorHashes = new Map<number, { doorKey: string; leafId: string; owner: string }>();
  for (const object of [...catalog.objects.values()].sort((left, right) => compareText(left.key, right.key))) {
    const definition = object.definition;
    if (object.kind === "door" && Array.isArray(definition.leaves)) {
      for (const leafValue of definition.leaves) {
        const leaf = asRecord(leafValue);
        if (!leaf || typeof leaf.id !== "string") continue;
        const hash = typeof leaf.doorHash === "number"
          ? uint32(leaf.doorHash) : derivedDoorHash(object.key, leaf.id);
        const previous = doorHashes.get(hash);
        if (previous) {
          findings.push(diagnostic([previous.owner, object.ownerResource], "error",
            "world-door-hash-collision", object.bundleFile,
            `${object.key}:${leaf.id} and ${previous.doorKey}:${previous.leafId} resolve to DoorSystem hash ${hash}.`));
        } else {
          doorHashes.set(hash, { doorKey: object.key, leafId: leaf.id, owner: object.ownerResource });
        }
      }
    }
    const parent = typeof definition.parent === "string" ? definition.parent : null;
    const expectedParents = parentKinds(object);
    if (parent && expectedParents) expectedReferenceKind(catalog, object, parent, "parent", expectedParents, findings);
    for (const reference of stringArray(definition.mapPackages)) {
      expectedReferenceKind(catalog, object, reference, "mapPackages", new Set(["map_package"]), findings);
    }
    for (const reference of stringArray(definition.iplBundles)) {
      expectedReferenceKind(catalog, object, reference, "iplBundles", new Set(["ipl_bundle"]), findings);
    }
    const accessPolicy = asRecord(definition.accessPolicy);
    for (const requirementValue of Array.isArray(accessPolicy?.stateRequirements)
      ? accessPolicy.stateRequirements : []) {
      const requirement = asRecord(requirementValue);
      if (typeof requirement?.key === "string") {
        expectedReferenceKind(catalog, object, requirement.key, "accessPolicy.stateRequirements",
          new Set(["world_state_definition"]), findings);
        validateAccessStateRequirement(catalog, object, requirement, findings);
      }
    }
    if (object.kind === "portal") {
      const destination = asRecord(definition.destination);
      if (!destination) continue;
      if (typeof destination.target === "string") {
        expectedReferenceKind(catalog, object, destination.target, "destination.target", portalTargets, findings);
      }
      if (typeof destination.instanceTemplate === "string") {
        expectedReferenceKind(catalog, object, destination.instanceTemplate, "destination.instanceTemplate",
          new Set(["instance_template"]), findings);
      }
      if (definition.portalType === "physical" && typeof destination.target !== "string") {
        findings.push(diagnostic([object.ownerResource], "error", "world-portal-destination", object.bundleFile,
          `${object.key} physical portal requires destination.target.`));
      }
      if (definition.portalType === "instance" && typeof destination.instanceTemplate !== "string") {
        findings.push(diagnostic([object.ownerResource], "error", "world-portal-destination", object.bundleFile,
          `${object.key} instance portal requires destination.instanceTemplate.`));
      }
    } else if (object.kind === "instance_template") {
      if (typeof definition.baseLocation === "string") {
        expectedReferenceKind(catalog, object, definition.baseLocation, "baseLocation", new Set(["location"]), findings);
      }
    } else if (object.kind === "map_package") {
      for (const reference of stringArray(definition.locations)) {
        expectedReferenceKind(catalog, object, reference, "locations", new Set(["location"]), findings);
      }
      for (const reference of stringArray(definition.iplBundles)) {
        expectedReferenceKind(catalog, object, reference, "iplBundles", new Set(["ipl_bundle"]), findings);
      }
    } else if (object.kind === "world_state_definition") {
      validateStateDefinition(catalog, object, findings);
    }
    const geometry = objectGeometry(object);
    if (geometry !== null) {
      for (const error of geometrySemanticErrors(geometry)) {
        findings.push(diagnostic([object.ownerResource], "error", "world-geometry", object.bundleFile,
          `${object.key}: ${error}`));
      }
    }
    const references = [parent, ...stringArray(definition.mapPackages), ...stringArray(definition.iplBundles)];
    if (object.kind === "portal") {
      const destination = asRecord(definition.destination);
      if (typeof destination?.target === "string") references.push(destination.target);
      if (typeof destination?.instanceTemplate === "string") references.push(destination.instanceTemplate);
    } else if (object.kind === "instance_template" && typeof definition.baseLocation === "string") {
      references.push(definition.baseLocation);
    } else if (object.kind === "map_package") {
      references.push(...stringArray(definition.locations));
    }
    for (const requirementValue of Array.isArray(accessPolicy?.stateRequirements)
      ? accessPolicy.stateRequirements : []) {
      const requirement = asRecord(requirementValue);
      if (typeof requirement?.key === "string") references.push(requirement.key);
      if (typeof requirement?.scopeRef === "string") references.push(requirement.scopeRef);
    }
    for (const reference of references) {
      if (!reference) continue;
      const target = catalog.objects.get(reference);
      if (target && target.ownerResource !== object.ownerResource
        && !dependenciesByBundle.get(object.bundleKey)?.has(target.ownerResource)) {
        findings.push(diagnostic([object.ownerResource, target.ownerResource], "error",
          "world-cross-resource-dependency", object.bundleFile,
          `${object.key} references ${reference} without declaring dependency ${target.ownerResource}.`));
      }
    }
  }
}

function validateBundleDependencyCycles(catalog: WorldCatalog, findings: OwnedDiagnostic[]): void {
  const owners = new Set(catalog.bundles.map((bundle) => bundle.ownerResource));
  const edges = new Map<string, Set<string>>();
  for (const bundle of catalog.bundles) {
    const dependencies = edges.get(bundle.ownerResource) ?? new Set<string>();
    for (const dependency of bundle.dependencies) if (owners.has(dependency)) dependencies.add(dependency);
    edges.set(bundle.ownerResource, dependencies);
  }
  const states = new Map<string, 1 | 2>();
  const visit = (owner: string, stack: string[]): void => {
    if (states.get(owner) === 2) return;
    if (states.get(owner) === 1) {
      const bundle = catalog.bundles.find((entry) => entry.ownerResource === owner);
      if (bundle) findings.push(diagnostic([...stack, owner], "error", "world-bundle-dependency-cycle",
        bundle.file, `World bundle dependency cycle: ${[...stack, owner].join(" -> ")}.`));
      return;
    }
    states.set(owner, 1);
    for (const dependency of edges.get(owner) ?? []) visit(dependency, [...stack, owner]);
    states.set(owner, 2);
  };
  for (const owner of [...owners].sort(compareText)) visit(owner, []);
}

function validateParentCycles(catalog: WorldCatalog, findings: OwnedDiagnostic[]): void {
  const state = new Map<string, 1 | 2>();
  const stack: string[] = [];
  const reported = new Set<string>();
  const visit = (key: string): void => {
    if (state.get(key) === 2) return;
    if (state.get(key) === 1) {
      const start = stack.indexOf(key);
      const cycle = [...stack.slice(Math.max(0, start)), key];
      const signature = [...new Set(cycle)].sort(compareText).join("|");
      if (!reported.has(signature)) {
        reported.add(signature);
        const object = catalog.objects.get(key);
        if (object) findings.push(diagnostic([object.ownerResource], "error", "world-parent-cycle",
          object.bundleFile, `World parent graph contains a cycle: ${cycle.join(" -> ")}.`));
      }
      return;
    }
    const object = catalog.objects.get(key);
    if (!object) return;
    state.set(key, 1);
    stack.push(key);
    const parent = typeof object.definition.parent === "string" ? object.definition.parent : null;
    if (parent && catalog.objects.has(parent)) visit(parent);
    stack.pop();
    state.set(key, 2);
  };
  for (const key of [...catalog.objects.keys()].sort(compareText)) visit(key);
}

async function bundlePathIsContained(resourceDirectory: string, bundleFile: string): Promise<boolean> {
  try {
    const metadata = await lstat(bundleFile);
    if (!metadata.isFile() || metadata.isSymbolicLink()) return false;
    const [realResource, realBundle] = await Promise.all([realpath(resourceDirectory), realpath(bundleFile)]);
    return containsPath(realResource, realBundle);
  } catch {
    return false;
  }
}

export async function loadWorldBundleCatalog(
  repositoryRoot: string,
  manifests: WorldManifestSource[],
  schemas: SchemaRegistry,
  selectedResources?: ReadonlySet<string>,
): Promise<WorldCatalog> {
  const findings: OwnedDiagnostic[] = [];
  const bundles: WorldBundleRecord[] = [];
  const objects = new Map<string, WorldObjectRecord>();
  const bundleKeys = new Map<string, WorldBundleRecord>();
  let declaredBundleFiles = 0;

  for (const loaded of manifests) {
    for (const relativeBundle of loaded.manifest.worldBundles ?? []) {
      declaredBundleFiles += 1;
      if (declaredBundleFiles > MAX_WORLD_BUNDLES) {
        findings.push(diagnostic([loaded.manifest.name], "error", "world-bundle-limit",
          displayPath(repositoryRoot, loaded.file), `Repository exceeds the ${MAX_WORLD_BUNDLES} bundle safety limit.`));
        break;
      }
      let bundleFile: string;
      try {
        bundleFile = resolveWithin(loaded.directory, relativeBundle);
      } catch {
        findings.push(diagnostic([loaded.manifest.name], "error", "world-bundle-path",
          displayPath(repositoryRoot, loaded.file), `World bundle path ${relativeBundle} escapes its resource.`));
        continue;
      }
      const shownFile = displayPath(repositoryRoot, bundleFile);
      if (!(await bundlePathIsContained(loaded.directory, bundleFile))) {
        findings.push(diagnostic([loaded.manifest.name], "error", "world-bundle-path", shownFile,
          "World bundle must be a regular file contained by its declaring resource."));
        continue;
      }
      let value: unknown;
      let text: string;
      try {
        text = await readTextFile(bundleFile);
        value = JSON.parse(text) as unknown;
      } catch (error) {
        findings.push(diagnostic([loaded.manifest.name], "error", "world-bundle-json", shownFile,
          error instanceof Error ? error.message : "World bundle could not be read."));
        continue;
      }
      if (!schemas.worldBundle(value)) {
        for (const schemaFinding of schemaDiagnostics(
          schemas.worldBundle.errors, bundleFile, repositoryRoot, "world-bundle-schema",
        )) {
          findings.push({ ...schemaFinding, owners: [loaded.manifest.name] });
        }
        continue;
      }
      const raw = asRecord(value);
      if (!raw || typeof raw.key !== "string" || typeof raw.version !== "string"
        || !Array.isArray(raw.objects)) continue;
      if (keyNamespace(raw.key) !== loaded.manifest.name) {
        findings.push(diagnostic([loaded.manifest.name], "error", "world-bundle-ownership", shownFile,
          `Bundle key ${raw.key} must use declaring resource namespace ${loaded.manifest.name}.`));
      }
      const bundle: WorldBundleRecord = {
        key: raw.key,
        version: raw.version,
        ownerResource: loaded.manifest.name,
        file: shownFile,
        dependencies: stringArray(raw.dependencies),
        objects: [],
      };
      const previousBundle = bundleKeys.get(bundle.key);
      if (previousBundle) {
        findings.push(diagnostic([bundle.ownerResource, previousBundle.ownerResource], "error",
          "world-bundle-key-unique", shownFile,
          `Bundle key ${bundle.key} is already declared in ${previousBundle.file}.`));
      } else {
        bundleKeys.set(bundle.key, bundle);
      }
      for (const rawObject of raw.objects) {
        const definition = asRecord(rawObject);
        if (!definition || typeof definition.key !== "string" || typeof definition.kind !== "string") continue;
        if (objects.size >= MAX_WORLD_OBJECTS) {
          findings.push(diagnostic([loaded.manifest.name], "error", "world-object-limit", shownFile,
            `Repository exceeds the ${MAX_WORLD_OBJECTS} world-object safety limit.`));
          break;
        }
        const object: WorldObjectRecord = {
          key: definition.key,
          kind: definition.kind,
          ownerResource: loaded.manifest.name,
          bundleKey: bundle.key,
          bundleFile: shownFile,
          definition,
        };
        if (typeof definition.label === "string"
          && Buffer.byteLength(definition.label, "utf8") > 96) {
          findings.push(diagnostic([loaded.manifest.name], "error", "world-string-byte-bound",
            shownFile, `${object.key} label exceeds the 96-byte runtime limit.`));
        }
        if (object.kind === "room" && typeof definition.gameRoomKey === "string"
          && Buffer.byteLength(definition.gameRoomKey, "utf8") > 64) {
          findings.push(diagnostic([loaded.manifest.name], "error", "world-string-byte-bound",
            shownFile, `${object.key} gameRoomKey exceeds the 64-byte runtime limit.`));
        }
        if (object.kind === "ipl_bundle") {
          for (const name of stringArray(definition.ipls)) {
            if (Buffer.byteLength(name, "utf8") > 96) findings.push(diagnostic(
              [loaded.manifest.name], "error", "world-string-byte-bound", shownFile,
              `${object.key} IPL name exceeds the 96-byte runtime limit.`));
          }
          for (const entry of Array.isArray(definition.interiorSets)
            ? definition.interiorSets : []) {
            const interiorSet = asRecord(entry);
            if (typeof interiorSet?.name === "string"
              && Buffer.byteLength(interiorSet.name, "utf8") > 64) findings.push(diagnostic(
                [loaded.manifest.name], "error", "world-string-byte-bound", shownFile,
                `${object.key} interior set name exceeds the 64-byte runtime limit.`));
          }
        }
        bundle.objects.push(object);
        if (keyNamespace(object.key) !== loaded.manifest.name) {
          findings.push(diagnostic([loaded.manifest.name], "error", "world-object-ownership", shownFile,
            `Object key ${object.key} must use declaring resource namespace ${loaded.manifest.name}.`));
        }
        const previousObject = objects.get(object.key);
        if (previousObject) {
          findings.push(diagnostic([object.ownerResource, previousObject.ownerResource], "error",
            "world-object-key-unique", shownFile,
            `Object key ${object.key} is already declared in ${previousObject.bundleFile}.`));
        } else {
          objects.set(object.key, object);
        }
      }
      bundles.push(bundle);
    }
  }

  const catalog: WorldCatalog = {
    bundles: bundles.sort((left, right) => compareText(left.key, right.key)),
    objects,
    diagnostics: [],
    declaredBundleFiles,
  };
  validateWorldReferences(catalog, findings);
  validateParentCycles(catalog, findings);
  validateBundleDependencyCycles(catalog, findings);
  catalog.diagnostics = findings
    .filter((finding) => includeDiagnostic(finding, selectedResources))
    .map(plainDiagnostic)
    .sort((left, right) => compareText(`${left.file}:${left.rule}:${left.message}`, `${right.file}:${right.rule}:${right.message}`));
  return catalog;
}

function worldStatus(diagnostics: Diagnostic[]): WorldReportStatus {
  if (diagnostics.some((entry) => entry.level === "error")) return "FAIL";
  if (diagnostics.some((entry) => entry.level === "warning")) return "WARN";
  return "PASS";
}

function objectSummary(object: WorldObjectRecord): Record<string, unknown> {
  const parent = typeof object.definition.parent === "string" ? object.definition.parent : null;
  const geometry = asRecord(objectGeometry(object));
  return {
    key: object.key,
    kind: object.kind,
    ownerResource: object.ownerResource,
    bundle: object.bundleKey,
    file: object.bundleFile,
    parent,
    label: typeof object.definition.label === "string" ? object.definition.label : null,
    tags: stringArray(object.definition.tags),
    geometry: typeof geometry?.type === "string" ? geometry.type : null,
    mapPackages: stringArray(object.definition.mapPackages),
    iplBundles: stringArray(object.definition.iplBundles),
  };
}

function boundsOverlap(left: Bounds, right: Bounds): boolean {
  return left.minimum.x <= right.maximum.x && left.maximum.x >= right.minimum.x
    && left.minimum.y <= right.maximum.y && left.maximum.y >= right.minimum.y
    && left.minimum.z <= right.maximum.z && left.maximum.z >= right.minimum.z;
}

function findOverlaps(catalog: WorldCatalog): {
  findings: OverlapFinding[];
  comparisons: number;
  truncated: boolean;
} {
  const candidates = [...catalog.objects.values()].flatMap((object) => {
    const bounds = geometryBounds(objectGeometry(object));
    return bounds ? [{ object, bounds }] : [];
  });
  const findings: OverlapFinding[] = [];
  let comparisons = 0;
  let truncated = false;
  for (let leftIndex = 0; leftIndex < candidates.length; leftIndex += 1) {
    const left = candidates[leftIndex];
    if (!left) continue;
    for (let rightIndex = leftIndex + 1; rightIndex < candidates.length; rightIndex += 1) {
      const right = candidates[rightIndex];
      if (!right) continue;
      const leftParent = typeof left.object.definition.parent === "string" ? left.object.definition.parent : null;
      const rightParent = typeof right.object.definition.parent === "string" ? right.object.definition.parent : null;
      if (leftParent !== rightParent || left.object.kind !== right.object.kind) continue;
      comparisons += 1;
      if (comparisons > MAX_OVERLAP_COMPARISONS || findings.length >= MAX_OVERLAP_RESULTS) {
        truncated = true;
        return { findings, comparisons: Math.min(comparisons, MAX_OVERLAP_COMPARISONS), truncated };
      }
      if (boundsOverlap(left.bounds, right.bounds)) {
        findings.push({ left: left.object.key, right: right.object.key, parent: leftParent, approximate: true });
      }
    }
  }
  return { findings, comparisons, truncated };
}

function graphReport(catalog: WorldCatalog, requestedKey: string): Record<string, unknown> {
  const root = catalog.objects.get(requestedKey);
  if (!root) return { status: "FAIL", key: requestedKey, error: "WORLD_OBJECT_NOT_FOUND" };
  const ancestors: string[] = [];
  const visited = new Set<string>();
  let current: WorldObjectRecord | undefined = root;
  while (current && ancestors.length < MAX_GRAPH_RESULTS) {
    const parent = typeof current.definition.parent === "string" ? current.definition.parent : null;
    if (!parent || visited.has(parent)) break;
    visited.add(parent);
    ancestors.push(parent);
    current = catalog.objects.get(parent);
  }
  const descendants: string[] = [];
  const queue = [requestedKey];
  while (queue.length > 0 && descendants.length < MAX_GRAPH_RESULTS) {
    const parent = queue.shift();
    if (!parent) break;
    for (const candidate of catalog.objects.values()) {
      if (candidate.definition.parent === parent) {
        descendants.push(candidate.key);
        queue.push(candidate.key);
        if (descendants.length >= MAX_GRAPH_RESULTS) break;
      }
    }
  }
  return {
    status: "PASS",
    key: requestedKey,
    ancestors,
    descendants: descendants.sort(compareText),
    truncated: descendants.length >= MAX_GRAPH_RESULTS,
  };
}

function locateReport(catalog: WorldCatalog, point: Vector3): Record<string, unknown> {
  const containing: Array<Record<string, unknown>> = [];
  const nearby: Array<Record<string, unknown>> = [];
  for (const object of catalog.objects.values()) {
    const geometry = objectGeometry(object);
    if (geometry && geometryContains(geometry, point)) containing.push(objectSummary(object));
    const position = objectPosition(object);
    if (position) {
      const distance = Math.hypot(point.x - position.x, point.y - position.y, point.z - position.z);
      const radius = typeof object.definition.radius === "number" ? object.definition.radius : 25;
      if (distance <= Math.max(radius, 25)) nearby.push({ ...objectSummary(object), distance: Number(distance.toFixed(3)) });
    }
  }
  containing.sort((left, right) => compareText(String(left.key), String(right.key)));
  nearby.sort((left, right) => Number(left.distance) - Number(right.distance)
    || compareText(String(left.key), String(right.key)));
  return {
    status: "PASS",
    point,
    containing: containing.slice(0, MAX_LOCATE_RESULTS),
    nearby: nearby.slice(0, MAX_LOCATE_RESULTS),
    truncated: containing.length > MAX_LOCATE_RESULTS || nearby.length > MAX_LOCATE_RESULTS,
  };
}

function parseCoordinate(value: string | undefined, name: string): number {
  const number = value === undefined ? Number.NaN : Number(value);
  if (!Number.isFinite(number) || number < -20_000 || number > 20_000) {
    throw new CliError(`world locate ${name} must be a finite coordinate between -20000 and 20000.`, 2);
  }
  return number;
}

export function runWorldCommand(
  catalog: WorldCatalog,
  subcommand: string,
  argumentsList: string[],
): { report: Record<string, unknown>; exitCode: number } {
  if (subcommand === "validate") {
    if (argumentsList.length > 0) throw new CliError("world validate does not accept positional arguments.", 2);
    const status = worldStatus(catalog.diagnostics);
    return { report: {
      status,
      bundles: catalog.bundles.length,
      objects: catalog.objects.size,
      diagnostics: catalog.diagnostics,
    }, exitCode: status === "FAIL" ? 1 : 0 };
  }
  if (subcommand === "doctor") {
    if (argumentsList.length > 0) throw new CliError("world doctor does not accept positional arguments.", 2);
    const staticStatus = worldStatus(catalog.diagnostics);
    const status: WorldReportStatus = staticStatus === "FAIL" ? "FAIL" : "UNKNOWN";
    return { report: {
      status,
      staticValidation: {
        status: staticStatus,
        bundles: catalog.bundles.length,
        objects: catalog.objects.size,
        diagnostics: catalog.diagnostics,
      },
      runtime: {
        status: "UNKNOWN",
        detail: "Offline tooling cannot verify FXServer resource state, IPL activation, door entities, routing buckets, or live presence.",
      },
    }, exitCode: status === "FAIL" ? 1 : 0 };
  }
  if (subcommand === "bundles") {
    if (argumentsList.length > 0) throw new CliError("world bundles does not accept positional arguments.", 2);
    const entries = catalog.bundles.slice(0, MAX_GRAPH_RESULTS).map((bundle) => ({
      key: bundle.key,
      version: bundle.version,
      ownerResource: bundle.ownerResource,
      file: bundle.file,
      dependencies: bundle.dependencies,
      objects: bundle.objects.length,
    }));
    return { report: { status: worldStatus(catalog.diagnostics), bundles: entries,
      truncated: catalog.bundles.length > entries.length }, exitCode: 0 };
  }
  if (subcommand === "inspect") {
    const key = argumentsList[0];
    if (!key || argumentsList.length > 1) throw new CliError("world inspect requires exactly one world object key.", 2);
    const object = catalog.objects.get(key);
    return object
      ? { report: { status: "PASS", object: objectSummary(object) }, exitCode: 0 }
      : { report: { status: "FAIL", key, error: "WORLD_OBJECT_NOT_FOUND" }, exitCode: 1 };
  }
  if (subcommand === "locate") {
    if (argumentsList.length !== 3) throw new CliError("world locate requires x y z coordinates.", 2);
    const point = {
      x: parseCoordinate(argumentsList[0], "x"),
      y: parseCoordinate(argumentsList[1], "y"),
      z: parseCoordinate(argumentsList[2], "z"),
    };
    return { report: locateReport(catalog, point), exitCode: 0 };
  }
  if (subcommand === "graph") {
    const key = argumentsList[0];
    if (!key || argumentsList.length > 1) throw new CliError("world graph requires exactly one world object key.", 2);
    const report = graphReport(catalog, key);
    return { report, exitCode: report.status === "FAIL" ? 1 : 0 };
  }
  if (subcommand === "overlaps") {
    if (argumentsList.length > 0) throw new CliError("world overlaps does not accept positional arguments.", 2);
    const overlaps = findOverlaps(catalog);
    return { report: { status: "PASS", ...overlaps,
      disclaimer: "Overlap results use bounded axis-aligned broad-phase bounds and require runtime confirmation." }, exitCode: 0 };
  }
  throw new CliError("world requires one of: validate, doctor, inspect, locate, graph, bundles, overlaps.", 2);
}

export function worldCatalogTargetResources(
  manifests: WorldManifestSource[],
  target: string,
): ReadonlySet<string> {
  const selected = resolve(target);
  return new Set(manifests
    .filter((loaded) => containsPath(selected, loaded.file))
    .map((loaded) => loaded.manifest.name));
}
