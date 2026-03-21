package da

import (
	"crypto/rand"
	"fmt"
	"math/big"
)

// ShamirSplit divides a 32-byte secret into n shares with threshold k.
// The secret is treated as a field element in GF(BN254). Any k shares
// can reconstruct the secret; k-1 shares reveal zero information.
// [Spec: Shamir-share(key, 5-of-7) step in Disperse action]
func ShamirSplit(secret []byte, threshold, total int) ([]ShamirShare, error) {
	if len(secret) > AESKeySize {
		return nil, fmt.Errorf("secret too large: %d bytes (max %d)", len(secret), AESKeySize)
	}
	if threshold > total {
		return nil, fmt.Errorf("threshold %d exceeds total %d", threshold, total)
	}
	if threshold < 2 {
		return nil, fmt.Errorf("threshold must be >= 2, got %d", threshold)
	}

	s := new(big.Int).SetBytes(secret)
	if s.Cmp(bn254Prime) >= 0 {
		return nil, ErrSecretExceedsField
	}

	// Generate random polynomial f(x) = s + a1*x + a2*x^2 + ... + a_{k-1}*x^{k-1}
	// where f(0) = secret.
	coeffs := make([]*big.Int, threshold)
	coeffs[0] = new(big.Int).Set(s)

	for i := 1; i < threshold; i++ {
		coeff, err := randFieldElement()
		if err != nil {
			return nil, fmt.Errorf("generate polynomial coefficient: %w", err)
		}
		coeffs[i] = coeff
	}

	// Evaluate polynomial at points x = 1, 2, ..., n using Horner's method.
	shares := make([]ShamirShare, total)
	for i := 0; i < total; i++ {
		x := big.NewInt(int64(i + 1))
		y := evaluatePolynomial(coeffs, x)
		shares[i] = ShamirShare{X: x, Y: y}
	}

	return shares, nil
}

// ShamirRecover reconstructs the secret from k or more shares using
// Lagrange interpolation at x=0.
// [Spec: Shamir-recover(key) step in RecoverData action]
func ShamirRecover(shares []ShamirShare) ([]byte, error) {
	if len(shares) < 2 {
		return nil, fmt.Errorf("%w: need >= 2, got %d", ErrInsufficientShares, len(shares))
	}

	// Check for duplicate x-values (would cause division by zero).
	seen := make(map[string]bool, len(shares))
	for _, s := range shares {
		key := s.X.String()
		if seen[key] {
			return nil, ErrDuplicateShares
		}
		seen[key] = true
	}

	// Lagrange interpolation at x=0: f(0) = SUM_i (y_i * l_i(0))
	// where l_i(0) = PRODUCT_{j!=i} (-x_j) / (x_i - x_j)
	secret := new(big.Int)
	for i, si := range shares {
		numerator := big.NewInt(1)
		denominator := big.NewInt(1)

		for j, sj := range shares {
			if i == j {
				continue
			}
			// numerator *= (0 - x_j) = -x_j mod p
			neg := new(big.Int).Neg(sj.X)
			neg.Mod(neg, bn254Prime)
			numerator.Mul(numerator, neg)
			numerator.Mod(numerator, bn254Prime)

			// denominator *= (x_i - x_j) mod p
			diff := new(big.Int).Sub(si.X, sj.X)
			diff.Mod(diff, bn254Prime)
			denominator.Mul(denominator, diff)
			denominator.Mod(denominator, bn254Prime)
		}

		// l_i(0) = numerator * denominator^(-1) mod p
		inv := new(big.Int).ModInverse(denominator, bn254Prime)
		if inv == nil {
			return nil, fmt.Errorf("modular inverse failed (duplicate x-values?)")
		}

		term := new(big.Int).Mul(numerator, inv)
		term.Mod(term, bn254Prime)

		// secret += y_i * l_i(0)
		term.Mul(term, si.Y)
		term.Mod(term, bn254Prime)

		secret.Add(secret, term)
		secret.Mod(secret, bn254Prime)
	}

	// Convert to fixed-size 32-byte key.
	result := make([]byte, AESKeySize)
	secretBytes := secret.Bytes()
	copy(result[AESKeySize-len(secretBytes):], secretBytes)

	return result, nil
}

// evaluatePolynomial evaluates the polynomial at point x using Horner's method.
// f(x) = c[0] + c[1]*x + c[2]*x^2 + ... = c[0] + x*(c[1] + x*(c[2] + ...))
func evaluatePolynomial(coeffs []*big.Int, x *big.Int) *big.Int {
	result := new(big.Int).Set(coeffs[len(coeffs)-1])
	for i := len(coeffs) - 2; i >= 0; i-- {
		result.Mul(result, x)
		result.Add(result, coeffs[i])
		result.Mod(result, bn254Prime)
	}
	return result
}

// randFieldElement generates a random non-zero element in GF(BN254).
func randFieldElement() (*big.Int, error) {
	max := new(big.Int).Sub(bn254Prime, big.NewInt(1))
	n, err := rand.Int(rand.Reader, max)
	if err != nil {
		return nil, err
	}
	return n.Add(n, big.NewInt(1)), nil
}
