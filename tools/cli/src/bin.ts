import { pathToFileURL } from "node:url";

import { runCli } from "./cli.ts";

const invokedPath = process.argv[1];
const invokedDirectly = invokedPath !== undefined && import.meta.url === pathToFileURL(invokedPath).href;
if (invokedDirectly) {
  const arguments_ = process.argv.slice(2);
  runCli(arguments_).then(
    (exitCode) => {
      process.exitCode = exitCode;
    },
    (error: unknown) => {
      console.error(error instanceof Error ? error.message : "Synex CLI failed.");
      process.exitCode = 1;
    },
  );
}
