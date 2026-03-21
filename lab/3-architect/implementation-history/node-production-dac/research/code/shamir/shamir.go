// Package shamir implements Shamir's Secret Sharing over a 256-bit prime field.
//
// Used for distributing the AES encryption key across DAC members.
// The key (32 bytes) is treated as a single field element and split into n shares
// with threshold k, providing information-theoretic privacy for the encryption key.
package shamir

import (
	"crypto/rand"
	"fmt"
	"math/big"
)

// Prime is a 256-bit prime for the secret sharing field.
// Using a prime slightly larger than 2^256 to accommodate 32-byte secrets.
// This is the BN254 scalar field order (same field used by Basis Network ZK circuits).
var Prime = new(big.Int).SetBytes([]byte{
	0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
	0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
	0x28, 0x33, 0xe8, 0x48, 0x79, 0xb9, 0x70, 0x91,
	0x43, 0xe1, 0xf5, 0x93, 0xf0, 0x00, 0x00, 0x01,
})

// Share represents a single Shamir share: (x, y) point on the polynomial.
type Share struct {
	X *big.Int // Evaluation point (1-indexed)
	Y *big.Int // Polynomial evaluation at X
}

// Config holds the Shamir SSS parameters.
type Config struct {
	Threshold int // k: minimum shares needed for reconstruction
	Total     int // n: total number of shares to generate
}

// DefaultConfig returns the production (5,7) configuration.
func DefaultConfig() Config {
	return Config{
		Threshold: 5,
		Total:     7,
	}
}

// Split divides a secret (32-byte key) into n shares with threshold k.
func Split(secret []byte, config Config) ([]Share, error) {
	if len(secret) > 32 {
		return nil, fmt.Errorf("secret too large: %d bytes (max 32)", len(secret))
	}
	if config.Threshold > config.Total {
		return nil, fmt.Errorf("threshold %d exceeds total %d", config.Threshold, config.Total)
	}
	if config.Threshold < 2 {
		return nil, fmt.Errorf("threshold must be at least 2, got %d", config.Threshold)
	}

	// Convert secret to big.Int
	s := new(big.Int).SetBytes(secret)
	if s.Cmp(Prime) >= 0 {
		return nil, fmt.Errorf("secret exceeds field prime")
	}

	// Generate random polynomial of degree k-1: f(x) = s + a1*x + a2*x^2 + ... + a_{k-1}*x^{k-1}
	coeffs := make([]*big.Int, config.Threshold)
	coeffs[0] = new(big.Int).Set(s) // f(0) = secret

	for i := 1; i < config.Threshold; i++ {
		coeff, err := randFieldElement()
		if err != nil {
			return nil, fmt.Errorf("generate coefficient: %w", err)
		}
		coeffs[i] = coeff
	}

	// Evaluate polynomial at points 1, 2, ..., n
	shares := make([]Share, config.Total)
	for i := 0; i < config.Total; i++ {
		x := big.NewInt(int64(i + 1))
		y := evaluatePolynomial(coeffs, x)
		shares[i] = Share{
			X: x,
			Y: y,
		}
	}

	return shares, nil
}

// Recover reconstructs the secret from k or more shares using Lagrange interpolation.
func Recover(shares []Share) ([]byte, error) {
	if len(shares) < 2 {
		return nil, fmt.Errorf("need at least 2 shares, got %d", len(shares))
	}

	// Lagrange interpolation at x=0 to recover f(0) = secret
	secret := new(big.Int)
	for i, si := range shares {
		// Compute Lagrange basis polynomial li(0) = PRODUCT_{j!=i} (0 - xj) / (xi - xj)
		numerator := big.NewInt(1)
		denominator := big.NewInt(1)

		for j, sj := range shares {
			if i == j {
				continue
			}
			// numerator *= (0 - xj) = -xj
			neg := new(big.Int).Neg(sj.X)
			neg.Mod(neg, Prime)
			numerator.Mul(numerator, neg)
			numerator.Mod(numerator, Prime)

			// denominator *= (xi - xj)
			diff := new(big.Int).Sub(si.X, sj.X)
			diff.Mod(diff, Prime)
			denominator.Mul(denominator, diff)
			denominator.Mod(denominator, Prime)
		}

		// li(0) = numerator / denominator = numerator * denominator^(-1) mod p
		inv := new(big.Int).ModInverse(denominator, Prime)
		if inv == nil {
			return nil, fmt.Errorf("modular inverse does not exist (duplicate x values?)")
		}

		term := new(big.Int).Mul(numerator, inv)
		term.Mod(term, Prime)

		// secret += yi * li(0)
		term.Mul(term, si.Y)
		term.Mod(term, Prime)

		secret.Add(secret, term)
		secret.Mod(secret, Prime)
	}

	// Convert to 32-byte key
	result := make([]byte, 32)
	secretBytes := secret.Bytes()
	copy(result[32-len(secretBytes):], secretBytes)

	return result, nil
}

// evaluatePolynomial evaluates the polynomial at point x using Horner's method.
func evaluatePolynomial(coeffs []*big.Int, x *big.Int) *big.Int {
	result := new(big.Int).Set(coeffs[len(coeffs)-1])
	for i := len(coeffs) - 2; i >= 0; i-- {
		result.Mul(result, x)
		result.Add(result, coeffs[i])
		result.Mod(result, Prime)
	}
	return result
}

// randFieldElement generates a random element in GF(Prime).
func randFieldElement() (*big.Int, error) {
	max := new(big.Int).Sub(Prime, big.NewInt(1))
	n, err := rand.Int(rand.Reader, max)
	if err != nil {
		return nil, err
	}
	return n.Add(n, big.NewInt(1)), nil
}
