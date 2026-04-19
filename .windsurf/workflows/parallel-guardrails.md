---
description: Parallel guardrail/verification workflow
---
1. Launch per-service startup scripts concurrently
   - Start a terminal for `scripts/local/multi-dev-up.sh`
   - Start Spring Boot apps (`mvn spring-boot:run`) for each service using separate terminals
2. In parallel, run frontend dev servers
   - `npm run devserver` (or equivalent) for each web client in its own terminal
3. After all services and frontends are up, run `scripts/local/multi-dev-verify.sh`
   - Confirms containers, DB schemas, seed data, Spring config guardrails, and RabbitMQ
4. Execute frontend smoke tests while backends stay running
   - Visit each UI, confirm no TypeScript/runtime errors
5. Collect logs/output from all terminals; stop processes when verification passes
