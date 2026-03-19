// Package main implements a Sparse Merkle Tree with Poseidon2 hash for benchmarking.
//
// Uses gnark-crypto's Poseidon2 implementation over BN254 scalar field.
// Poseidon2 (Grassi et al., 2023) is the improved version of Poseidon with faster
// native computation and same/fewer ZK circuit constraints.
//
// BN254 scalar field: p = 21888242871839275222246405745257275088548364400416034343698204186575808495617
package main

import (
	"math/big"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
	"github.com/consensys/gnark-crypto/ecc/bn254/fr/poseidon2"
)

// Global permutation instance for 2-to-1 compression (reusable, thread-unsafe).
var perm2to1 *poseidon2.Permutation

func init() {
	// Width 2, default parameters (rf=6, rp=50) for BN254
	perm2to1 = poseidon2.NewPermutation(2, 6, 50)
}

// PoseidonHash computes Poseidon2(left, right) over the BN254 scalar field.
// Uses the Compress method which is a collision-resistant 2-to-1 hash.
func PoseidonHash(left, right *big.Int) *big.Int {
	var l, r fr.Element
	l.SetBigInt(left)
	r.SetBigInt(right)

	lBytes := l.Marshal()
	rBytes := r.Marshal()

	digest, err := perm2to1.Compress(lBytes, rBytes)
	if err != nil {
		panic("poseidon2 compress failed: " + err.Error())
	}

	var result fr.Element
	result.SetBytes(digest)
	var out big.Int
	result.BigInt(&out)
	return &out
}

// PoseidonHashFr computes Poseidon2 on fr.Element inputs directly (faster path).
func PoseidonHashFr(left, right *fr.Element) *fr.Element {
	lBytes := left.Marshal()
	rBytes := right.Marshal()

	digest, err := perm2to1.Compress(lBytes, rBytes)
	if err != nil {
		panic("poseidon2 compress failed: " + err.Error())
	}

	var result fr.Element
	result.SetBytes(digest)
	return &result
}

// PoseidonHashSingle computes Poseidon2 on a single input (key derivation).
// Pads with zero as the second input.
func PoseidonHashSingle(input *big.Int) *big.Int {
	return PoseidonHash(input, big.NewInt(0))
}

// FieldModulus returns the BN254 scalar field modulus.
func FieldModulus() *big.Int {
	return fr.Modulus()
}
