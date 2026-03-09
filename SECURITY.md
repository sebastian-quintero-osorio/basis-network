# Security Policy

## Reporting a Vulnerability

Basis Network is enterprise infrastructure. Security is a top priority.

If you discover a security vulnerability, please report it responsibly:

- **Email:** social@basecomputing.com.co
- **Subject line:** `[SECURITY] Basis Network — <brief description>`

Do NOT open a public GitHub issue for security vulnerabilities.

## Response Timeline

- **Acknowledgment:** within 48 hours of report.
- **Assessment:** within 5 business days.
- **Resolution:** depends on severity; critical issues are prioritized immediately.

## Scope

This policy covers:

- Smart contracts in `contracts/`
- Blockchain Adapter Layer in `adapter/`
- ZK circuits and verifier in `prover/`
- Dashboard application in `dashboard/`
- L1 configuration in `l1-config/`

## Smart Contract Security

- All contracts use OpenZeppelin audited base contracts where applicable.
- Access control is enforced at both the L1 level (allowlists) and contract level (role-based).
- The ZK verifier uses Groth16 verification with trusted setup parameters.
- No contract holds user funds in the current architecture.

## Responsible Disclosure

We commit to:

- Not pursuing legal action against researchers who follow this policy.
- Working with reporters to understand and resolve issues.
- Crediting reporters (with permission) in any public disclosure.
