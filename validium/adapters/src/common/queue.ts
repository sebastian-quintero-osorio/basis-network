import { ethers } from "ethers";

interface QueueItem {
  id: string;
  execute: () => Promise<ethers.TransactionResponse>;
  retries: number;
  maxRetries: number;
  createdAt: number;
}

/// Transaction queue with retry logic for reliable on-chain writes.
/// Ensures eventual consistency between off-chain applications and the L1.
export class TransactionQueue {
  private queue: QueueItem[] = [];
  private processing = false;
  private readonly maxRetries: number;
  private readonly retryDelayMs: number;

  constructor(maxRetries = 3, retryDelayMs = 2000) {
    this.maxRetries = maxRetries;
    this.retryDelayMs = retryDelayMs;
  }

  async enqueue(
    id: string,
    execute: () => Promise<ethers.TransactionResponse>
  ): Promise<void> {
    this.queue.push({
      id,
      execute,
      retries: 0,
      maxRetries: this.maxRetries,
      createdAt: Date.now(),
    });

    console.log(`[Queue] Enqueued transaction: ${id} (queue size: ${this.queue.length})`);

    if (!this.processing) {
      await this.processQueue();
    }
  }

  private async processQueue(): Promise<void> {
    this.processing = true;

    while (this.queue.length > 0) {
      const item = this.queue[0];

      try {
        console.log(`[Queue] Processing: ${item.id} (attempt ${item.retries + 1}/${item.maxRetries})`);
        const tx = await item.execute();
        const receipt = await tx.wait();
        console.log(`[Queue] Confirmed: ${item.id} (block: ${receipt?.blockNumber})`);
        this.queue.shift();
      } catch (error) {
        item.retries++;
        if (item.retries >= item.maxRetries) {
          console.error(`[Queue] Failed after ${item.maxRetries} attempts: ${item.id}`, error);
          this.queue.shift();
        } else {
          console.warn(`[Queue] Retry ${item.retries}/${item.maxRetries} for: ${item.id}`);
          await this.delay(this.retryDelayMs * item.retries);
        }
      }
    }

    this.processing = false;
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  get size(): number {
    return this.queue.length;
  }
}
