package da

import (
	"fmt"
)

// CheckFallback evaluates whether the AnyTrust fallback condition is met for a batch.
// Fallback triggers when chunks were distributed but fewer than threshold nodes received them.
// [Spec: TriggerFallback(b) -- guards: certState="none", distributedTo /= {}, |distributedTo| < Threshold]
func (c *Committee) CheckFallback(batchID uint64) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if c.certState[batchID] != CertNone {
		return false
	}

	// Count nodes that have the batch stored.
	distributed := 0
	for _, node := range c.Nodes {
		if node.HasPackage(batchID) {
			distributed++
		}
	}

	// Fallback if distributed but below threshold.
	return distributed > 0 && distributed < c.Config.Threshold
}

// TriggerFallback activates AnyTrust fallback mode for a batch.
// In fallback mode, the raw batch data is posted as L1 calldata (validium -> rollup mode).
// [Spec: TriggerFallback(b) -- certState[b] <- "fallback"]
func (c *Committee) TriggerFallback(batchID uint64, rawData []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.certState[batchID] != CertNone {
		return fmt.Errorf("%w: batch %d, state %s",
			ErrCertificateExists, batchID, c.certState[batchID])
	}

	c.certState[batchID] = CertFallback
	c.fallback[batchID] = rawData
	return nil
}

// IsFallback returns whether a batch is in AnyTrust fallback mode.
func (c *Committee) IsFallback(batchID uint64) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.certState[batchID] == CertFallback
}

// GetFallbackData returns the raw data for a batch in fallback mode.
// This data should be posted as L1 calldata for data availability.
func (c *Committee) GetFallbackData(batchID uint64) ([]byte, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if c.certState[batchID] != CertFallback {
		return nil, fmt.Errorf("%w: batch %d not in fallback mode", ErrFallbackActive, batchID)
	}

	data, exists := c.fallback[batchID]
	if !exists {
		return nil, fmt.Errorf("no fallback data stored for batch %d", batchID)
	}
	return data, nil
}
