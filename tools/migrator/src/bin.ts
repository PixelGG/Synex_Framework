import { pathToFileURL } from "node:url";

const sourceMode = import.meta.url.endsWith(".ts");
const implementationUrl = new URL(sourceMode ? "./migrator.ts" : "./migrator.js", import.meta.url);
const implementation = (await import(implementationUrl.href)) as typeof import("./migrator.js");

const invokedPath = process.argv[1];
if (invokedPath !== undefined && import.meta.url === pathToFileURL(invokedPath).href) {
  implementation.runMigratorCli(process.argv.slice(2)).then(
    (exitCode) => {
      process.exitCode = exitCode;
    },
    (error: unknown) => {
      console.error(error instanceof Error ? error.message : "Legacy migration failed.");
      process.exitCode = 1;
    },
  );
}
