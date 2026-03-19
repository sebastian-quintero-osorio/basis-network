# Gas Benchmark Results

## Environment
- Solidity 0.8.24, optimizer 200 runs, evmVersion: cancun
- Hardhat local network (EVM simulation)
- BasisRollupHarness (mock Groth16 verification)
- 61 tests, all passing

## Per-Phase Gas (First Batch vs Steady State)

| Phase | First Batch | Steady State | Delta |
|-------|------------|-------------|-------|
| commitBatch | 150,118 | 116,147 | -33,971 |
| proveBatch | 67,943 | 50,855 | -17,088 |
| executeBatch | 69,712 | 52,624 | -17,088 |
| TOTAL | 287,773 | 219,626 | -68,147 |

## Gas Reporter Aggregates (All 61 Tests)

| Method | Min | Max | Avg | Calls |
|--------|-----|-----|-----|-------|
| commitBatch | 115,775 | 150,118 | 141,723 | 76 |
| proveBatch | 50,843 | 67,943 | 65,558 | 43 |
| executeBatch | 52,612 | 69,712 | 67,338 | 36 |
| revertBatch | 45,862 | 50,140 | 47,611 | 6 |
| initializeEnterprise | 73,358 | 73,370 | 73,368 | 74 |

## Block Range Scaling

| Blocks/Batch | Commit | Prove | Execute | Total |
|-------------|--------|-------|---------|-------|
| 1 | 149,746 | 67,943 | 69,712 | 287,401 |
| 10 | 149,746 | 67,943 | 69,712 | 287,401 |
| 100 | 149,746 | 67,943 | 69,712 | 287,401 |
| 1,000 | 149,758 | 67,943 | 69,712 | 287,413 |

## Projected Gas with Real Groth16 Verification

| Scenario | Commit | Prove (+206K) | Execute | Total |
|----------|--------|---------------|---------|-------|
| First batch | 150,118 | 273,543 | 69,712 | 493,373 |
| Steady state | 116,147 | 256,455 | 52,624 | 425,226 |

## Deployment Size

| Contract | Gas | % of Block Limit |
|----------|-----|-----------------|
| BasisRollupHarness | 1,419,864 | 2.4% |
| MockEnterpriseRegistry | 128,315 | 0.2% |
