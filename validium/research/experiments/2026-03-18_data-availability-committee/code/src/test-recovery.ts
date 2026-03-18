// RU-V6: Recovery and Failure Mode Tests
//
// Validates:
// 1. Recovery from k available nodes (normal operation)
// 2. Recovery when one node fails (2-of-3)
// 3. Fallback triggers when < k nodes available
// 4. Multiple sequential batches with intermittent failures
// 5. Node rejoining after failure
// 6. Attestation certificate verification
//
// These tests verify INV-DA2 (availability), INV-DA3 (attestation), INV-DA4 (liveness/fallback).

import { DACProtocol } from './dac-protocol.js';
import { randomBytes } from 'crypto';
import type { DACConfig } from './types.js';

let passed = 0;
let failed = 0;

function assert(condition: boolean, message: string): void {
  if (condition) {
    passed++;
    console.log(`  PASS: ${message}`);
  } else {
    failed++;
    console.error(`  FAIL: ${message}`);
  }
}

const DEFAULT_CONFIG: DACConfig = {
  committeeSize: 3,
  threshold: 2,
  attestationTimeoutMs: 5000,
  enableFallback: true,
};

function testNormalRecovery(): void {
  console.log('\n--- Test 1: Normal recovery (all nodes online) ---');

  const protocol = new DACProtocol(DEFAULT_CONFIG);
  const data = randomBytes(10_000);

  const result = protocol.attestBatch(data);
  assert(result.attestation.certificate.valid, 'Certificate is valid');
  assert(result.attestation.certificate.signatureCount === 3, 'All 3 nodes attested');

  const recovery = protocol.recoverData(result.distribution.batchId, data);
  assert(recovery.recovered, 'Data recovered successfully');
  assert(recovery.dataMatches, 'Recovered data matches original');
  assert(recovery.nodesUsed.length === 2, `Used ${recovery.nodesUsed.length} nodes (threshold=2)`);
}

function testOneNodeFailure(): void {
  console.log('\n--- Test 2: Recovery with one node offline ---');

  const protocol = new DACProtocol(DEFAULT_CONFIG);
  const data = randomBytes(50_000);

  // Distribute first (all nodes online)
  const dist = protocol.distributeShares(data);
  assert(dist.shareSent.every((s) => s), 'All shares distributed while online');

  // Take node 3 offline AFTER distribution
  protocol.setNodeOffline(3);

  // Attestation should still succeed (2-of-3)
  const attest = protocol.collectAttestations(dist.batchId, dist.commitment);
  assert(attest.certificate.valid, 'Certificate valid with 2 attestations');
  assert(attest.certificate.signatureCount === 2, 'Got 2 signatures (node 3 offline)');

  // Recovery from 2 available nodes
  const recovery = protocol.recoverData(dist.batchId, data);
  assert(recovery.recovered, 'Data recovered with 1 node down');
  assert(recovery.dataMatches, 'Recovered data matches original');
}

function testTwoNodeFailure(): void {
  console.log('\n--- Test 3: Two nodes offline -- fallback required ---');

  const protocol = new DACProtocol(DEFAULT_CONFIG);
  const data = randomBytes(10_000);

  // Distribute first
  const dist = protocol.distributeShares(data);

  // Take 2 nodes offline
  protocol.setNodeOffline(2);
  protocol.setNodeOffline(3);

  // Attestation should fail (only 1 of 3 online, need 2)
  const attest = protocol.collectAttestations(dist.batchId, dist.commitment);
  assert(!attest.certificate.valid, 'Certificate invalid with only 1 attestation');
  assert(attest.fallbackTriggered, 'Fallback triggered');
  assert(attest.certificate.signatureCount === 1, 'Only 1 signature received');

  // Recovery should fail (only 1 node, need 2)
  const recovery = protocol.recoverData(dist.batchId, data);
  assert(!recovery.recovered, 'Recovery fails with < threshold nodes');
}

function testNodeOfflineDuringDistribution(): void {
  console.log('\n--- Test 4: Node offline DURING distribution ---');

  const protocol = new DACProtocol(DEFAULT_CONFIG);
  const data = randomBytes(10_000);

  // Take node 2 offline BEFORE distribution
  protocol.setNodeOffline(2);

  const dist = protocol.distributeShares(data);
  assert(dist.shareSent[0] === true, 'Node 1 received shares');
  assert(dist.shareSent[1] === false, 'Node 2 did not receive shares (offline)');
  assert(dist.shareSent[2] === true, 'Node 3 received shares');

  // Attestation: 2 nodes can still attest
  const attest = protocol.collectAttestations(dist.batchId, dist.commitment);
  assert(attest.certificate.valid, 'Certificate still valid (2 of 3)');

  // Recovery from nodes 1 and 3
  const recovery = protocol.recoverData(dist.batchId, data);
  assert(recovery.recovered, 'Recovery succeeds from nodes 1,3');
  assert(recovery.dataMatches, 'Data matches');
}

function testNodeRejoin(): void {
  console.log('\n--- Test 5: Node goes offline then rejoins ---');

  const protocol = new DACProtocol(DEFAULT_CONFIG);

  // Batch 1: all online
  const data1 = randomBytes(5_000);
  const result1 = protocol.attestBatch(data1);
  assert(result1.attestation.certificate.signatureCount === 3, 'Batch 1: 3 attestations');

  // Node 2 goes offline
  protocol.setNodeOffline(2);

  // Batch 2: 2 nodes
  const data2 = randomBytes(5_000);
  const result2 = protocol.attestBatch(data2);
  assert(result2.attestation.certificate.signatureCount === 2, 'Batch 2: 2 attestations');

  // Node 2 comes back
  protocol.setNodeOnline(2);

  // Batch 3: 3 nodes again
  const data3 = randomBytes(5_000);
  const result3 = protocol.attestBatch(data3);
  assert(result3.attestation.certificate.signatureCount === 3, 'Batch 3: 3 attestations (node rejoined)');

  // Verify all batches recoverable
  const r1 = protocol.recoverData(result1.distribution.batchId, data1);
  assert(r1.dataMatches, 'Batch 1 still recoverable');

  // Batch 2: node 2 has no shares (was offline during distribution)
  const r2 = protocol.recoverData(result2.distribution.batchId, data2);
  assert(r2.dataMatches, 'Batch 2 recoverable (from nodes 1,3)');

  const r3 = protocol.recoverData(result3.distribution.batchId, data3);
  assert(r3.dataMatches, 'Batch 3 recoverable');
}

function testCertificateVerification(): void {
  console.log('\n--- Test 6: On-chain certificate verification ---');

  const protocol = new DACProtocol(DEFAULT_CONFIG);
  const data = randomBytes(10_000);

  const result = protocol.attestBatch(data);
  const cert = result.attestation.certificate;

  // Verify valid certificate
  const verify = protocol.verifyOnChain(cert);
  assert(verify.valid, 'Valid certificate passes on-chain verification');
  assert(verify.ecrecoverCount === 3, `Performed ${verify.ecrecoverCount} ecrecover operations`);

  // Tamper with certificate -- modify a signature
  const tamperedCert = { ...cert, attestations: [...cert.attestations] };
  tamperedCert.attestations[0] = {
    ...tamperedCert.attestations[0],
    signature: 'deadbeef' + tamperedCert.attestations[0].signature.slice(8),
  };
  const verifyTampered = protocol.verifyOnChain(tamperedCert);
  assert(!verifyTampered.valid, 'Tampered certificate fails verification');
}

function testMultipleBatches(): void {
  console.log('\n--- Test 7: Multiple sequential batches ---');

  const protocol = new DACProtocol(DEFAULT_CONFIG);
  const batches: { data: Buffer; batchId: string }[] = [];
  const BATCH_COUNT = 20;

  // Submit multiple batches
  for (let i = 0; i < BATCH_COUNT; i++) {
    const data = randomBytes(5_000 + i * 1_000);
    const result = protocol.attestBatch(data);
    assert(result.attestation.certificate.valid, `Batch ${i}: valid certificate`);
    batches.push({ data, batchId: result.distribution.batchId });
  }

  // Verify all are recoverable
  let allRecovered = true;
  for (let i = 0; i < BATCH_COUNT; i++) {
    const recovery = protocol.recoverData(batches[i].batchId, batches[i].data);
    if (!recovery.dataMatches) {
      allRecovered = false;
      console.error(`  FAIL: Batch ${i} recovery mismatch`);
    }
  }
  assert(allRecovered, `All ${BATCH_COUNT} batches recoverable`);
}

function testThreeOfThreeConfig(): void {
  console.log('\n--- Test 8: 3-of-3 configuration ---');

  const config: DACConfig = {
    committeeSize: 3,
    threshold: 3,
    attestationTimeoutMs: 5000,
    enableFallback: true,
  };

  const protocol = new DACProtocol(config);
  const data = randomBytes(10_000);

  // All online: should work
  const result = protocol.attestBatch(data);
  assert(result.attestation.certificate.valid, '3-of-3: valid with all online');

  const recovery = protocol.recoverData(result.distribution.batchId, data);
  assert(recovery.dataMatches, '3-of-3: data recovered');
  assert(recovery.nodesUsed.length === 3, '3-of-3: used all 3 nodes');

  // One offline: should fail (3-of-3 requires all)
  protocol.reset();
  protocol.setNodeOffline(1);
  const data2 = randomBytes(10_000);
  const result2 = protocol.attestBatch(data2);
  assert(!result2.attestation.certificate.valid, '3-of-3: invalid with 1 offline');
  assert(result2.attestation.fallbackTriggered, '3-of-3: fallback triggered');
}

function testLargerCommittee(): void {
  console.log('\n--- Test 9: 3-of-5 committee ---');

  const config: DACConfig = {
    committeeSize: 5,
    threshold: 3,
    attestationTimeoutMs: 5000,
    enableFallback: true,
  };

  const protocol = new DACProtocol(config);
  const data = randomBytes(10_000);

  // All online
  const result = protocol.attestBatch(data);
  assert(result.attestation.certificate.valid, '3-of-5: valid with all online');
  assert(result.attestation.certificate.signatureCount === 5, '3-of-5: 5 attestations');

  // 2 nodes offline (still have 3 of 5)
  protocol.reset();
  protocol.setNodeOffline(4);
  protocol.setNodeOffline(5);
  const data2 = randomBytes(10_000);
  const result2 = protocol.attestBatch(data2);
  assert(result2.attestation.certificate.valid, '3-of-5: valid with 2 offline');
  assert(result2.attestation.certificate.signatureCount === 3, '3-of-5: 3 attestations');

  const recovery = protocol.recoverData(result2.distribution.batchId, data2);
  assert(recovery.dataMatches, '3-of-5: data recovered from 3 nodes');
}

function testDeterministicRecovery(): void {
  console.log('\n--- Test 10: Recovery determinism (30 iterations) ---');

  const protocol = new DACProtocol(DEFAULT_CONFIG);
  const data = randomBytes(50_000);
  const dist = protocol.distributeShares(data);

  let allMatch = true;
  for (let i = 0; i < 30; i++) {
    const recovery = protocol.recoverData(dist.batchId, data);
    if (!recovery.dataMatches) {
      allMatch = false;
      break;
    }
  }
  assert(allMatch, 'Recovery is deterministic across 30 iterations');
}

// Run all tests
console.log('=== RU-V6: Recovery and Failure Mode Tests ===');

testNormalRecovery();
testOneNodeFailure();
testTwoNodeFailure();
testNodeOfflineDuringDistribution();
testNodeRejoin();
testCertificateVerification();
testMultipleBatches();
testThreeOfThreeConfig();
testLargerCommittee();
testDeterministicRecovery();

console.log(`\n========================================`);
console.log(`Results: ${passed} passed, ${failed} failed out of ${passed + failed} tests`);
console.log(`========================================`);

if (failed > 0) {
  process.exit(1);
}
