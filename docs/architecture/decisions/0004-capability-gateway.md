# ADR-0004: Capability gateway, not a resource sandbox

Status: Accepted

## Decision

Bind public facades to the immediately captured invoking resource and resource epoch. Resolve grants from operator policy with deny precedence. Treat privileged and destructive capabilities as deny-by-default.

## Consequences

Synex can enforce access to its own gateways and audit denied calls. It cannot prevent arbitrary server code from using FiveM natives, accessing unrelated exports, or deliberately forwarding an acquired facade; documentation and certification state this limit explicitly.
