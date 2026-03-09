# Contributing to Basis Network

Basis Network is proprietary software developed by Base Computing S.A.S. under the Business Source License 1.1.

## Current Status

This repository is not open for external contributions at this time. The codebase is maintained by the Base Computing development team.

## For Base Computing Team Members

### Development Workflow

1. Pull the latest `dev` branch.
2. Create a feature branch: `feature/<descriptive-name>`.
3. Make your changes with atomic commits following Conventional Commits format.
4. Ensure all tests pass: `cd contracts && npx hardhat test`.
5. Merge your feature branch into `dev`.
6. Delete the feature branch after merging.

### Commit Message Format

```
<type>(<scope>): <short description>
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, `ci`

Scopes: `contracts`, `adapter`, `prover`, `dashboard`, `l1-config`, `docs`

### Code Standards

- All code and documentation must be in English.
- Solidity: follow the official Solidity style guide. Use NatSpec for public functions.
- TypeScript: use strict mode. Prefer explicit types over `any`.
- No emojis in code, comments, or documentation.
- Write tests for all new functionality.

## Questions

Contact social@basecomputing.com.co for inquiries.
