import { resolve } from "node:path";

import { flattenContracts, loadContractSources } from "./contracts.ts";
import { compareText, displayPath } from "./filesystem.ts";
import { loadSchemaRegistry } from "./schemas.ts";
import { satisfiesVersionRange } from "./semver.ts";
import { loadFxmanifestResourceMetadata, loadResourceManifests } from "./validation.ts";

export type ResourceGraphEdgeKind =
  | "dependency-required"
  | "dependency-optional"
  | "dependency-development"
  | "service-required"
  | "service-optional"
  | "contract-consume";

export interface ResourceGraphNode {
  name: string;
  version: string | null;
  path: string | null;
  external: boolean;
  critical: boolean;
}

export interface ResourceGraphEdge {
  from: string;
  to: string;
  kind: ResourceGraphEdgeKind;
  reference: string;
  resolved: boolean;
  actualVersion?: string | null;
  versionStatus?:
    | "compatible"
    | "incompatible"
    | "missing"
    | "metadata-missing"
    | "metadata-invalid"
    | "metadata-ambiguous"
    | "runtime-unverified";
}

export interface DependencyVersionFinding {
  resource: string;
  dependency: string;
  dependencyClass: "required" | "optional" | "development";
  requiredRange: string;
  actualVersion: string | null;
  status:
    | "incompatible"
    | "missing"
    | "metadata-missing"
    | "metadata-invalid"
    | "metadata-ambiguous"
    | "runtime-unverified";
  severity: "error" | "warning";
}

export interface ResourceUsageEntry {
  name: string;
  provider: string;
  consumers: string[];
  unused: boolean;
}

export interface ResourceGraphReport {
  nodes: ResourceGraphNode[];
  edges: ResourceGraphEdge[];
  cycles: string[][];
  topologicalOrder: string[] | null;
  unresolvedRequired: Array<{ resource: string; kind: "dependency" | "service"; reference: string }>;
  dependencyVersions: DependencyVersionFinding[];
  usage: {
    contracts: ResourceUsageEntry[];
    services: ResourceUsageEntry[];
    disclaimer: string;
  };
}

function stronglyConnectedComponents(nodes: string[], adjacency: Map<string, Set<string>>): string[][] {
  let nextIndex = 0;
  const indices = new Map<string, number>();
  const lowLinks = new Map<string, number>();
  const stack: string[] = [];
  const onStack = new Set<string>();
  const components: string[][] = [];

  const visit = (node: string): void => {
    indices.set(node, nextIndex);
    lowLinks.set(node, nextIndex);
    nextIndex += 1;
    stack.push(node);
    onStack.add(node);

    for (const dependency of [...(adjacency.get(node) ?? [])].sort(compareText)) {
      if (!indices.has(dependency)) {
        visit(dependency);
        lowLinks.set(node, Math.min(lowLinks.get(node) ?? 0, lowLinks.get(dependency) ?? 0));
      } else if (onStack.has(dependency)) {
        lowLinks.set(node, Math.min(lowLinks.get(node) ?? 0, indices.get(dependency) ?? 0));
      }
    }

    if (lowLinks.get(node) !== indices.get(node)) return;
    const component: string[] = [];
    while (stack.length > 0) {
      const candidate = stack.pop();
      if (!candidate) break;
      onStack.delete(candidate);
      component.push(candidate);
      if (candidate === node) break;
    }
    component.sort(compareText);
    if (component.length > 1 || (adjacency.get(node)?.has(node) ?? false)) components.push(component);
  };

  for (const node of [...nodes].sort(compareText)) {
    if (!indices.has(node)) visit(node);
  }
  return components.sort((left, right) => compareText(left.join("\0"), right.join("\0")));
}

function topologicalOrder(nodes: string[], adjacency: Map<string, Set<string>>): string[] | null {
  const indegree = new Map(nodes.map((node) => [node, 0]));
  const dependents = new Map<string, Set<string>>();
  for (const [resource, dependencies] of adjacency) {
    for (const dependency of dependencies) {
      if (!indegree.has(dependency)) continue;
      indegree.set(resource, (indegree.get(resource) ?? 0) + 1);
      const entries = dependents.get(dependency) ?? new Set<string>();
      entries.add(resource);
      dependents.set(dependency, entries);
    }
  }
  const ready = [...indegree.entries()].filter(([, degree]) => degree === 0).map(([name]) => name).sort(compareText);
  const ordered: string[] = [];
  while (ready.length > 0) {
    const current = ready.shift();
    if (!current) break;
    ordered.push(current);
    for (const dependent of [...(dependents.get(current) ?? [])].sort(compareText)) {
      const degree = (indegree.get(dependent) ?? 1) - 1;
      indegree.set(dependent, degree);
      if (degree === 0) {
        ready.push(dependent);
        ready.sort(compareText);
      }
    }
  }
  return ordered.length === nodes.length ? ordered : null;
}

export async function buildResourceGraph(repositoryRoot: string): Promise<ResourceGraphReport> {
  const schemas = await loadSchemaRegistry(repositoryRoot);
  const loaded = await loadResourceManifests(repositoryRoot, resolve(repositoryRoot), schemas);
  const manifests = loaded.manifests;
  const byName = new Map(manifests.map((entry) => [entry.manifest.name, entry]));
  const fxmanifestResources = await loadFxmanifestResourceMetadata(repositoryRoot);
  const graphNodes = new Map<string, ResourceGraphNode>();
  const edges: ResourceGraphEdge[] = [];
  const unresolvedRequired: ResourceGraphReport["unresolvedRequired"] = [];
  const dependencyVersions: DependencyVersionFinding[] = [];

  for (const entry of manifests) {
    graphNodes.set(entry.manifest.name, {
      name: entry.manifest.name,
      version: entry.manifest.version,
      path: displayPath(repositoryRoot, entry.directory),
      external: false,
      critical: entry.manifest.critical,
    });
  }

  const addDependency = (
    from: string,
    dependency: { name: string; version: string },
    kind: Extract<ResourceGraphEdgeKind, `dependency-${string}`>,
  ): void => {
    const provider = byName.get(dependency.name);
    const runtimeMetadata = fxmanifestResources.get(dependency.name);
    const resolved = provider !== undefined || runtimeMetadata !== undefined;
    const dependencyClass = kind.slice("dependency-".length) as DependencyVersionFinding["dependencyClass"];
    const actualVersion = runtimeMetadata?.version ?? null;
    const compatible = runtimeMetadata?.versionStatus === "valid" && actualVersion !== null
      && satisfiesVersionRange(actualVersion, dependency.version);
    const external = !dependency.name.startsWith("synex_");
    const versionStatus = compatible
      ? "compatible"
      : !resolved
        ? external ? "runtime-unverified" : "missing"
        : runtimeMetadata?.versionStatus === "missing" || !runtimeMetadata
          ? "metadata-missing"
          : runtimeMetadata.versionStatus === "invalid"
            ? "metadata-invalid"
            : runtimeMetadata.versionStatus === "ambiguous"
              ? "metadata-ambiguous"
              : "incompatible";
    if (!graphNodes.has(dependency.name)) {
      graphNodes.set(dependency.name, {
        name: dependency.name,
        version: runtimeMetadata?.versionStatus === "valid" ? runtimeMetadata.version : null,
        path: runtimeMetadata ? displayPath(repositoryRoot, runtimeMetadata.directory) : null,
        external: true,
        critical: false,
      });
    }
    edges.push({
      from,
      to: dependency.name,
      kind,
      reference: dependency.version,
      resolved,
      actualVersion,
      versionStatus,
    });
    if (versionStatus !== "compatible" && dependencyClass !== "development") {
      dependencyVersions.push({
        resource: from,
        dependency: dependency.name,
        dependencyClass,
        requiredRange: dependency.version,
        actualVersion,
        status: versionStatus,
        severity: dependencyClass === "required" && versionStatus !== "runtime-unverified"
          ? "error"
          : "warning",
      });
    } else if (dependencyClass === "development"
      && versionStatus !== "compatible"
      && versionStatus !== "missing"
      && versionStatus !== "runtime-unverified") {
      dependencyVersions.push({
        resource: from,
        dependency: dependency.name,
        dependencyClass,
        requiredRange: dependency.version,
        actualVersion,
        status: versionStatus,
        severity: "warning",
      });
    }
    if (kind === "dependency-required" && dependency.name.startsWith("synex_") && !resolved) {
      unresolvedRequired.push({ resource: from, kind: "dependency", reference: dependency.name });
    }
  };

  const serviceProviders = new Map<string, string[]>();
  for (const entry of manifests) {
    for (const service of entry.manifest.services.provide) {
      const providers = serviceProviders.get(service) ?? [];
      providers.push(entry.manifest.name);
      serviceProviders.set(service, providers);
    }
    for (const dependency of entry.manifest.dependencies.required) {
      addDependency(entry.manifest.name, dependency, "dependency-required");
    }
    for (const dependency of entry.manifest.dependencies.optional) {
      addDependency(entry.manifest.name, dependency, "dependency-optional");
    }
    for (const dependency of entry.manifest.dependencies.development) {
      addDependency(entry.manifest.name, dependency, "dependency-development");
    }
  }

  const serviceConsumers = new Map<string, Set<string>>();
  for (const entry of manifests) {
    for (const [kind, services] of [
      ["service-required", entry.manifest.services.require],
      ["service-optional", entry.manifest.services.optional],
    ] as const) {
      for (const service of services) {
        const consumers = serviceConsumers.get(service) ?? new Set<string>();
        consumers.add(entry.manifest.name);
        serviceConsumers.set(service, consumers);
        const providers = [...(serviceProviders.get(service) ?? [])].sort(compareText);
        if (providers.length === 0) {
          if (kind === "service-required") {
            unresolvedRequired.push({ resource: entry.manifest.name, kind: "service", reference: service });
          }
          continue;
        }
        for (const provider of providers) {
          edges.push({ from: entry.manifest.name, to: provider, kind, reference: service, resolved: true });
        }
      }
    }
  }

  const contracts = await loadContractSources(repositoryRoot, schemas);
  const contractProviders = new Map(flattenContracts(contracts.sources).map((contract) => [contract.name, contract.provider]));
  const contractConsumers = new Map<string, Set<string>>();
  for (const entry of manifests) {
    for (const contract of entry.manifest.contracts.consume) {
      const consumers = contractConsumers.get(contract) ?? new Set<string>();
      consumers.add(entry.manifest.name);
      contractConsumers.set(contract, consumers);
      const provider = contractProviders.get(contract);
      if (provider) {
        edges.push({ from: entry.manifest.name, to: provider, kind: "contract-consume", reference: contract, resolved: byName.has(provider) });
      }
    }
  }

  const internalNames = manifests.map((entry) => entry.manifest.name).sort(compareText);
  const adjacency = new Map(internalNames.map((name) => [name, new Set<string>()]));
  for (const edge of edges) {
    if (!edge.resolved || !byName.has(edge.from) || !byName.has(edge.to)) continue;
    if (edge.kind === "dependency-required" || edge.kind === "service-required") {
      adjacency.get(edge.from)?.add(edge.to);
    }
  }

  const serviceUsage: ResourceUsageEntry[] = [];
  for (const entry of manifests) {
    for (const service of entry.manifest.services.provide) {
      const consumers = [...(serviceConsumers.get(service) ?? [])].sort(compareText);
      serviceUsage.push({ name: service, provider: entry.manifest.name, consumers, unused: consumers.length === 0 });
    }
  }
  const contractUsage: ResourceUsageEntry[] = [];
  for (const entry of manifests) {
    for (const contract of entry.manifest.contracts.provide) {
      const consumers = [...(contractConsumers.get(contract) ?? [])].sort(compareText);
      contractUsage.push({ name: contract, provider: entry.manifest.name, consumers, unused: consumers.length === 0 });
    }
  }

  return {
    nodes: [...graphNodes.values()].sort((left, right) => compareText(left.name, right.name)),
    edges: edges.sort((left, right) =>
      compareText(left.from, right.from) || compareText(left.kind, right.kind) || compareText(left.reference, right.reference),
    ),
    cycles: stronglyConnectedComponents(internalNames, adjacency),
    topologicalOrder: topologicalOrder(internalNames, adjacency),
    unresolvedRequired: unresolvedRequired.sort((left, right) =>
      compareText(left.resource, right.resource) || compareText(left.reference, right.reference),
    ),
    dependencyVersions: dependencyVersions.sort((left, right) =>
      compareText(left.resource, right.resource)
      || compareText(left.dependencyClass, right.dependencyClass)
      || compareText(left.dependency, right.dependency),
    ),
    usage: {
      contracts: contractUsage.sort((left, right) => compareText(left.name, right.name)),
      services: serviceUsage.sort((left, right) => compareText(left.name, right.name)),
      disclaimer: "Unused means no consumer is declared in this checkout; dynamic or external consumers require manual review.",
    },
  };
}

export function renderResourceGraph(report: ResourceGraphReport): string {
  const outgoing = new Map<string, ResourceGraphEdge[]>();
  for (const edge of report.edges) {
    const entries = outgoing.get(edge.from) ?? [];
    entries.push(edge);
    outgoing.set(edge.from, entries);
  }
  const lines: string[] = [];
  for (const node of report.nodes.filter((candidate) => !candidate.external)) {
    lines.push(node.name);
    const entries = outgoing.get(node.name) ?? [];
    entries.forEach((edge, index) => {
      const marker = index === entries.length - 1 ? "└──" : "├──";
      const versionMarker = edge.versionStatus === "incompatible"
        ? ` [INCOMPATIBLE: ${edge.actualVersion ?? "missing"}]`
        : edge.versionStatus === "missing"
          ? " [UNRESOLVED]"
          : edge.versionStatus?.startsWith("metadata-")
            ? ` [${edge.versionStatus.toUpperCase()}]`
          : edge.versionStatus === "runtime-unverified"
            ? " [RUNTIME VERSION CHECK]"
            : "";
      lines.push(`${marker} ${edge.to} (${edge.kind}: ${edge.reference})${versionMarker}`);
    });
  }
  if (report.cycles.length > 0) {
    lines.push("", "CIRCULAR DEPENDENCIES");
    for (const cycle of report.cycles) lines.push(`! ${cycle.join(" <-> ")}`);
  }
  return lines.join("\n");
}
