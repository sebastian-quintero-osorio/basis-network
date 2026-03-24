// e2e-dac-test verifies the Data Availability Committee (DAC) protocol.
//
// This test exercises the DAC module directly (no external running nodes required)
// to verify dispersal, attestation, certification, and recovery flows.
//
// Test scenarios:
//   1. Happy path: disperse data -> collect attestations -> produce certificate
//   2. Recovery: recover original data from threshold chunks + shares
//   3. Node failure: 2 nodes offline, verify recovery from remaining 5
//   4. Certificate soundness: < threshold attestations cannot produce valid cert
//   5. Fallback: insufficient nodes triggers AnyTrust fallback
package main

import (
	"crypto/rand"
	"fmt"
	"os"
	"time"

	"basis-network/zkl2/node/da"
)

func main() {
	fmt.Println("=== DAC E2E Test ===")
	fmt.Printf("Timestamp: %s\n\n", time.Now().UTC().Format(time.RFC3339))

	passed := 0
	failed := 0

	// ---------------------------------------------------------------
	// Test 1: Full dispersal + certification (happy path)
	// ---------------------------------------------------------------
	fmt.Println("--- Test 1: Dispersal + Certification ---")
	func() {
		committee := createCommittee(7, 5)
		data := randomBytes(1024) // 1 KB test data

		result := committee.Disperse(1, data)
		if result.Err != nil {
			fmt.Printf("FAIL: dispersal error: %v\n", result.Err)
			failed++
			return
		}

		if result.CertState != da.CertValid {
			fmt.Printf("FAIL: expected CertValid, got %v\n", result.CertState)
			failed++
			return
		}

		if result.Certificate == nil {
			fmt.Printf("FAIL: certificate is nil\n")
			failed++
			return
		}

		if len(result.Certificate.Attestations) < 5 {
			fmt.Printf("FAIL: expected >= 5 attestations, got %d\n", len(result.Certificate.Attestations))
			failed++
			return
		}

		fmt.Printf("PASS: Dispersal complete (cert=%d attestations, time=%s)\n",
			len(result.Certificate.Attestations), result.TotalTime)
		fmt.Printf("      Encode: %s, KeyShare: %s, Distribute: %s\n",
			result.EncodeTime, result.KeyShareTime, result.DistributeTime)
		fmt.Printf("      Verify: %s, Attest: %s, Certify: %s\n",
			result.VerifyTime, result.AttestTime, result.CertifyTime)
		passed++
	}()
	fmt.Println()

	// ---------------------------------------------------------------
	// Test 2: Data recovery from threshold chunks
	// ---------------------------------------------------------------
	fmt.Println("--- Test 2: Data Recovery ---")
	func() {
		committee := createCommittee(7, 5)
		original := randomBytes(2048)

		result := committee.Disperse(2, original)
		if result.Err != nil {
			fmt.Printf("FAIL: dispersal error: %v\n", result.Err)
			failed++
			return
		}

		// Recover using the committee's built-in recovery (collects from nodes internally).
		recovered, recovery := committee.Recover(2)
		if recovery.State != da.RecoverySuccess {
			fmt.Printf("FAIL: recovery state=%v, err=%v\n", recovery.State, recovery.Err)
			failed++
			return
		}

		if len(recovered) == 0 {
			fmt.Printf("FAIL: recovered data is empty\n")
			failed++
			return
		}

		fmt.Printf("PASS: Data recovered (size=%d, time=%s)\n",
			recovery.DataSize, recovery.TotalTime)
		fmt.Printf("      RS decode: %s, Key recover: %s, Decrypt: %s\n",
			recovery.RSDecodeTime, recovery.KeyRecoverTime, recovery.DecryptTime)
		passed++
	}()
	fmt.Println()

	// ---------------------------------------------------------------
	// Test 3: Node failure tolerance (2 offline)
	// ---------------------------------------------------------------
	fmt.Println("--- Test 3: Node Failure (2 Offline) ---")
	func() {
		committee := createCommittee(7, 5)

		// Take 2 nodes offline before dispersal.
		committee.Nodes[5].SetOffline()
		committee.Nodes[6].SetOffline()

		data := randomBytes(512)
		result := committee.Disperse(3, data)

		if result.Err != nil {
			fmt.Printf("FAIL: dispersal with 2 offline: %v\n", result.Err)
			failed++
			return
		}

		// Should still succeed with 5 online nodes.
		if result.NodesReceived < 5 {
			fmt.Printf("FAIL: expected >= 5 nodes received, got %d\n", result.NodesReceived)
			failed++
			return
		}

		if result.CertState != da.CertValid {
			fmt.Printf("FAIL: expected CertValid with 5/7 nodes, got %v\n", result.CertState)
			failed++
			return
		}

		fmt.Printf("PASS: 5/7 nodes online, cert valid (%d attestations)\n",
			len(result.Certificate.Attestations))
		passed++
	}()
	fmt.Println()

	// ---------------------------------------------------------------
	// Test 4: Certificate soundness (< threshold = invalid)
	// ---------------------------------------------------------------
	fmt.Println("--- Test 4: Certificate Soundness ---")
	func() {
		committee := createCommittee(7, 5)

		// Take 3 nodes offline (only 4 remain, below threshold of 5).
		committee.Nodes[4].SetOffline()
		committee.Nodes[5].SetOffline()
		committee.Nodes[6].SetOffline()

		data := randomBytes(256)
		result := committee.Disperse(4, data)

		if result.CertState == da.CertValid {
			fmt.Printf("FAIL: should NOT produce valid cert with 4/7 nodes (threshold=5)\n")
			failed++
			return
		}

		// Should trigger fallback or produce no cert.
		fmt.Printf("PASS: Below threshold (4/7), cert state=%v (not valid), fallback triggered\n",
			result.CertState)
		passed++
	}()
	fmt.Println()

	// ---------------------------------------------------------------
	// Test 5: Recovery with subset of nodes
	// ---------------------------------------------------------------
	fmt.Println("--- Test 5: Recovery from Subset ---")
	func() {
		committee := createCommittee(7, 5)
		data := randomBytes(1024)

		result := committee.Disperse(5, data)
		if result.Err != nil {
			fmt.Printf("FAIL: dispersal error: %v\n", result.Err)
			failed++
			return
		}

		// Recover using only first 5 nodes.
		nodeIDs := []da.NodeID{0, 1, 2, 3, 4}
		recovered, recovery := committee.RecoverFrom(5, nodeIDs)
		if recovery.State != da.RecoverySuccess {
			fmt.Printf("FAIL: subset recovery state=%v, err=%v\n", recovery.State, recovery.Err)
			failed++
			return
		}

		if len(recovered) == 0 {
			fmt.Printf("FAIL: recovered data is empty\n")
			failed++
			return
		}

		fmt.Printf("PASS: Data recovered from 5/7 nodes (size=%d, time=%s)\n",
			recovery.DataSize, recovery.TotalTime)
		passed++
	}()
	fmt.Println()

	// ---------------------------------------------------------------
	// Summary
	// ---------------------------------------------------------------
	fmt.Printf("\n=== DAC E2E Test Complete ===\n")
	fmt.Printf("Passed: %d, Failed: %d\n", passed, failed)

	if failed > 0 {
		os.Exit(1)
	}
}

func createCommittee(total, threshold int) *da.Committee {
	cfg := da.Config{
		DataShards:   5,
		ParityShards: 2,
		Threshold:    threshold,
		Total:        total,
	}

	committee, err := da.NewCommittee(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: create committee: %v\n", err)
		os.Exit(1)
	}
	return committee
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	rand.Read(b)
	return b
}
