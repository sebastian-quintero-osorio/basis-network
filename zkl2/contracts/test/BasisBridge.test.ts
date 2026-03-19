// Test suite for BasisBridge.sol
// [Spec: zkl2/specs/units/2026-03-bridge/1-formalization/v0-analysis/specs/BasisBridge/BasisBridge.tla]
//
// Maps all 6 security invariants (INV-B1 through INV-B6) to concrete Hardhat tests.
// Uses BasisBridgeHarness to mock Merkle proof verification.
// Uses MockBasisRollup to simulate rollup state without full BasisRollup deployment.

import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// Contract types (loose typing to avoid typechain dependency issues)
type BasisBridgeHarness = any;
type MockBasisRollup = any;

const ESCAPE_TIMEOUT = 86400; // 24 hours in seconds
const ONE_ETH = ethers.parseEther("1");
const HALF_ETH = ethers.parseEther("0.5");

// Dummy state root for mock rollup
const MOCK_STATE_ROOT = ethers.keccak256(ethers.toUtf8Bytes("mock-state-root"));
const MOCK_WITHDRAW_ROOT = ethers.keccak256(ethers.toUtf8Bytes("mock-withdraw-root"));

describe("BasisBridge", function () {
  let bridge: BasisBridgeHarness;
  let mockRollup: MockBasisRollup;
  let admin: HardhatEthersSigner;
  let enterprise: HardhatEthersSigner;
  let user1: HardhatEthersSigner;
  let user2: HardhatEthersSigner;
  let outsider: HardhatEthersSigner;

  beforeEach(async function () {
    [admin, enterprise, user1, user2, outsider] = await ethers.getSigners();

    // Deploy mock rollup
    const MockRollup = await ethers.getContractFactory("MockBasisRollup");
    mockRollup = await MockRollup.deploy();
    await mockRollup.waitForDeployment();

    // Initialize enterprise on mock rollup (1 batch executed)
    await mockRollup.setEnterprise(
      enterprise.address,
      MOCK_STATE_ROOT,
      1, // totalBatchesExecuted
      10  // lastL2Block
    );

    // Deploy bridge harness
    const BridgeHarness = await ethers.getContractFactory("BasisBridgeHarness");
    bridge = await BridgeHarness.deploy(
      await mockRollup.getAddress(),
      ESCAPE_TIMEOUT
    );
    await bridge.waitForDeployment();
  });

  // Helper: compute withdrawal hash matching Solidity's abi.encodePacked
  function computeWithdrawalHash(
    ent: string,
    batchId: bigint,
    recipient: string,
    amount: bigint,
    index: bigint
  ): string {
    return ethers.keccak256(
      ethers.solidityPacked(
        ["address", "uint256", "address", "uint256", "uint256"],
        [ent, batchId, recipient, amount, index]
      )
    );
  }

  // Helper: advance blockchain time
  async function advanceTime(seconds: number) {
    await ethers.provider.send("evm_increaseTime", [seconds]);
    await ethers.provider.send("evm_mine", []);
  }

  // =====================================================================
  // DEPOSIT (L1 -> L2)
  // [Spec: BasisBridge.tla, Deposit(u, amt)]
  // =====================================================================

  describe("Deposit", function () {
    it("accepts ETH deposit and emits DepositInitiated event", async function () {
      const tx = bridge.connect(user1).deposit(
        enterprise.address,
        user1.address,
        { value: ONE_ETH }
      );

      await expect(tx)
        .to.emit(bridge, "DepositInitiated")
        .withArgs(
          enterprise.address,
          user1.address,
          user1.address,
          ONE_ETH,
          0n, // first deposit ID
          (v: bigint) => v > 0n // timestamp
        );
    });

    it("locks ETH in the bridge contract", async function () {
      await bridge.connect(user1).deposit(
        enterprise.address,
        user1.address,
        { value: ONE_ETH }
      );

      const bridgeBalance = await ethers.provider.getBalance(await bridge.getAddress());
      expect(bridgeBalance).to.equal(ONE_ETH);
    });

    it("INV-B5: increments deposit counter monotonically", async function () {
      expect(await bridge.depositCounter(enterprise.address)).to.equal(0n);

      await bridge.connect(user1).deposit(
        enterprise.address, user1.address, { value: ONE_ETH }
      );
      expect(await bridge.depositCounter(enterprise.address)).to.equal(1n);

      await bridge.connect(user2).deposit(
        enterprise.address, user2.address, { value: HALF_ETH }
      );
      expect(await bridge.depositCounter(enterprise.address)).to.equal(2n);
    });

    it("INV-B2: tracks total deposited", async function () {
      await bridge.connect(user1).deposit(
        enterprise.address, user1.address, { value: ONE_ETH }
      );
      await bridge.connect(user2).deposit(
        enterprise.address, user2.address, { value: HALF_ETH }
      );

      const total = await bridge.totalDeposited(enterprise.address);
      expect(total).to.equal(ONE_ETH + HALF_ETH);
    });

    it("reverts on zero amount", async function () {
      await expect(
        bridge.connect(user1).deposit(enterprise.address, user1.address, { value: 0 })
      ).to.be.revertedWithCustomError(bridge, "ZeroAmount");
    });

    it("reverts on zero l2Recipient", async function () {
      await expect(
        bridge.connect(user1).deposit(enterprise.address, ethers.ZeroAddress, { value: ONE_ETH })
      ).to.be.revertedWithCustomError(bridge, "ZeroAddress");
    });

    it("reverts for uninitialized enterprise", async function () {
      await expect(
        bridge.connect(user1).deposit(outsider.address, user1.address, { value: ONE_ETH })
      ).to.be.revertedWithCustomError(bridge, "EnterpriseNotInitialized");
    });
  });

  // =====================================================================
  // CLAIM WITHDRAWAL (L2 -> L1)
  // [Spec: BasisBridge.tla, ClaimWithdrawal(w)]
  // =====================================================================

  describe("ClaimWithdrawal", function () {
    const BATCH_ID = 0n;
    const WITHDRAWAL_INDEX = 0n;

    beforeEach(async function () {
      // Fund bridge with ETH for withdrawals
      await bridge.connect(user1).deposit(
        enterprise.address, user1.address, { value: ethers.parseEther("10") }
      );

      // Admin submits withdraw root for batch 0
      await bridge.connect(admin).submitWithdrawRoot(
        enterprise.address,
        BATCH_ID,
        MOCK_WITHDRAW_ROOT
      );
    });

    it("claims withdrawal with valid proof", async function () {
      const balanceBefore = await ethers.provider.getBalance(user1.address);

      const tx = await bridge.connect(user2).claimWithdrawal(
        enterprise.address,
        BATCH_ID,
        user1.address,
        ONE_ETH,
        WITHDRAWAL_INDEX,
        [] // empty proof (harness mocks verification)
      );

      await expect(tx).to.emit(bridge, "WithdrawalClaimed");

      const balanceAfter = await ethers.provider.getBalance(user1.address);
      expect(balanceAfter - balanceBefore).to.equal(ONE_ETH);
    });

    it("INV-B1: reverts on double claim (no double spend)", async function () {
      // First claim succeeds
      await bridge.connect(user2).claimWithdrawal(
        enterprise.address,
        BATCH_ID,
        user1.address,
        ONE_ETH,
        WITHDRAWAL_INDEX,
        []
      );

      // Second claim with same parameters reverts
      await expect(
        bridge.connect(user2).claimWithdrawal(
          enterprise.address,
          BATCH_ID,
          user1.address,
          ONE_ETH,
          WITHDRAWAL_INDEX,
          []
        )
      ).to.be.revertedWithCustomError(bridge, "AlreadyClaimed");
    });

    it("INV-B2: tracks total withdrawn", async function () {
      await bridge.connect(user2).claimWithdrawal(
        enterprise.address,
        BATCH_ID,
        user1.address,
        ONE_ETH,
        WITHDRAWAL_INDEX,
        []
      );

      expect(await bridge.totalWithdrawn(enterprise.address)).to.equal(ONE_ETH);
    });

    it("reverts when withdraw root not set", async function () {
      await expect(
        bridge.connect(user2).claimWithdrawal(
          enterprise.address,
          99n, // non-existent batch
          user1.address,
          ONE_ETH,
          WITHDRAWAL_INDEX,
          []
        )
      ).to.be.revertedWithCustomError(bridge, "WithdrawRootNotSet");
    });

    it("reverts on invalid proof", async function () {
      await bridge.setMockProofResult(false);

      await expect(
        bridge.connect(user2).claimWithdrawal(
          enterprise.address,
          BATCH_ID,
          user1.address,
          ONE_ETH,
          WITHDRAWAL_INDEX,
          []
        )
      ).to.be.revertedWithCustomError(bridge, "InvalidProof");
    });

    it("reverts on zero amount", async function () {
      await expect(
        bridge.connect(user2).claimWithdrawal(
          enterprise.address, BATCH_ID, user1.address, 0n, WITHDRAWAL_INDEX, []
        )
      ).to.be.revertedWithCustomError(bridge, "ZeroAmount");
    });

    it("reverts on zero recipient", async function () {
      await expect(
        bridge.connect(user2).claimWithdrawal(
          enterprise.address, BATCH_ID, ethers.ZeroAddress, ONE_ETH, WITHDRAWAL_INDEX, []
        )
      ).to.be.revertedWithCustomError(bridge, "ZeroAddress");
    });

    it("different withdrawal indices have independent nullifiers", async function () {
      // Claim index 0
      await bridge.connect(user2).claimWithdrawal(
        enterprise.address, BATCH_ID, user1.address, ONE_ETH, 0n, []
      );

      // Claim index 1 with same parameters but different index succeeds
      await bridge.connect(user2).claimWithdrawal(
        enterprise.address, BATCH_ID, user1.address, ONE_ETH, 1n, []
      );

      expect(await bridge.totalWithdrawn(enterprise.address)).to.equal(ONE_ETH + ONE_ETH);
    });
  });

  // =====================================================================
  // ESCAPE HATCH
  // [Spec: BasisBridge.tla, ActivateEscapeHatch, EscapeWithdraw(u)]
  // =====================================================================

  describe("EscapeHatch", function () {
    beforeEach(async function () {
      // Fund bridge
      await bridge.connect(user1).deposit(
        enterprise.address, user1.address, { value: ethers.parseEther("10") }
      );

      // Record batch execution so lastBatchExecutionTime is set
      await bridge.connect(admin).recordBatchExecution(enterprise.address);
    });

    describe("activateEscapeHatch", function () {
      it("INV-B3: activates after timeout", async function () {
        await advanceTime(ESCAPE_TIMEOUT + 1);

        const tx = bridge.connect(outsider).activateEscapeHatch(enterprise.address);
        await expect(tx).to.emit(bridge, "EscapeHatchActivated");

        expect(await bridge.escapeMode(enterprise.address)).to.be.true;
      });

      it("reverts before timeout", async function () {
        await advanceTime(ESCAPE_TIMEOUT - 100);

        await expect(
          bridge.connect(outsider).activateEscapeHatch(enterprise.address)
        ).to.be.revertedWithCustomError(bridge, "EscapeTimeoutNotReached");
      });

      it("reverts if already active", async function () {
        await advanceTime(ESCAPE_TIMEOUT + 1);
        await bridge.connect(outsider).activateEscapeHatch(enterprise.address);

        await expect(
          bridge.connect(outsider).activateEscapeHatch(enterprise.address)
        ).to.be.revertedWithCustomError(bridge, "EscapeAlreadyActive");
      });

      it("reverts if no batch ever executed", async function () {
        // Deploy fresh bridge with no batch execution recorded
        const BridgeHarness = await ethers.getContractFactory("BasisBridgeHarness");
        const freshBridge = await BridgeHarness.deploy(
          await mockRollup.getAddress(),
          ESCAPE_TIMEOUT
        );
        await freshBridge.waitForDeployment();

        await expect(
          freshBridge.connect(outsider).activateEscapeHatch(enterprise.address)
        ).to.be.revertedWithCustomError(freshBridge, "EscapeTimeoutNotReached");
      });

      it("anyone can activate (not admin-only)", async function () {
        await advanceTime(ESCAPE_TIMEOUT + 1);
        await bridge.connect(outsider).activateEscapeHatch(enterprise.address);
        expect(await bridge.escapeMode(enterprise.address)).to.be.true;
      });
    });

    describe("escapeWithdraw", function () {
      beforeEach(async function () {
        // Activate escape mode
        await advanceTime(ESCAPE_TIMEOUT + 1);
        await bridge.connect(outsider).activateEscapeHatch(enterprise.address);
      });

      it("withdraws via escape hatch with valid proof", async function () {
        const balanceBefore = await ethers.provider.getBalance(user1.address);

        const tx = await bridge.connect(user2).escapeWithdraw(
          enterprise.address,
          user1.address,
          ONE_ETH,
          [], // mocked proof
          0n
        );

        await expect(tx)
          .to.emit(bridge, "EscapeWithdrawal")
          .withArgs(
            enterprise.address,
            user1.address,
            ONE_ETH,
            (v: bigint) => v > 0n
          );

        const balanceAfter = await ethers.provider.getBalance(user1.address);
        expect(balanceAfter - balanceBefore).to.equal(ONE_ETH);
      });

      it("INV-B6: reverts on double escape withdrawal", async function () {
        await bridge.connect(user2).escapeWithdraw(
          enterprise.address, user1.address, ONE_ETH, [], 0n
        );

        await expect(
          bridge.connect(user2).escapeWithdraw(
            enterprise.address, user1.address, ONE_ETH, [], 0n
          )
        ).to.be.revertedWithCustomError(bridge, "AlreadyEscaped");
      });

      it("reverts if escape not active", async function () {
        // Deploy fresh bridge (no escape mode)
        const BridgeHarness = await ethers.getContractFactory("BasisBridgeHarness");
        const freshBridge = await BridgeHarness.deploy(
          await mockRollup.getAddress(),
          ESCAPE_TIMEOUT
        );
        await freshBridge.waitForDeployment();

        await expect(
          freshBridge.connect(user2).escapeWithdraw(
            enterprise.address, user1.address, ONE_ETH, [], 0n
          )
        ).to.be.revertedWithCustomError(freshBridge, "EscapeNotActive");
      });

      it("reverts on zero balance", async function () {
        await expect(
          bridge.connect(user2).escapeWithdraw(
            enterprise.address, user1.address, 0n, [], 0n
          )
        ).to.be.revertedWithCustomError(bridge, "ZeroAmount");
      });

      it("reverts on invalid proof", async function () {
        await bridge.setMockProofResult(false);

        await expect(
          bridge.connect(user2).escapeWithdraw(
            enterprise.address, user1.address, ONE_ETH, [], 0n
          )
        ).to.be.revertedWithCustomError(bridge, "InvalidProof");
      });

      it("reverts on insufficient bridge balance", async function () {
        // Try to escape more than bridge holds
        const bridgeBalance = await ethers.provider.getBalance(await bridge.getAddress());

        await expect(
          bridge.connect(user2).escapeWithdraw(
            enterprise.address,
            user1.address,
            bridgeBalance + ONE_ETH,
            [],
            0n
          )
        ).to.be.revertedWithCustomError(bridge, "InsufficientBridgeBalance");
      });

      it("different users can escape independently", async function () {
        await bridge.connect(user2).escapeWithdraw(
          enterprise.address, user1.address, ONE_ETH, [], 0n
        );
        await bridge.connect(user2).escapeWithdraw(
          enterprise.address, user2.address, HALF_ETH, [], 1n
        );

        expect(await bridge.hasEscaped(enterprise.address, user1.address)).to.be.true;
        expect(await bridge.hasEscaped(enterprise.address, user2.address)).to.be.true;
      });
    });
  });

  // =====================================================================
  // ADMIN / RELAYER FUNCTIONS
  // [Spec: BasisBridge.tla, FinalizeBatch]
  // =====================================================================

  describe("Admin Functions", function () {
    describe("submitWithdrawRoot", function () {
      it("admin can submit withdraw root", async function () {
        const tx = bridge.connect(admin).submitWithdrawRoot(
          enterprise.address,
          0n,
          MOCK_WITHDRAW_ROOT
        );

        await expect(tx)
          .to.emit(bridge, "WithdrawRootSubmitted")
          .withArgs(
            enterprise.address,
            0n,
            MOCK_WITHDRAW_ROOT,
            (v: bigint) => v > 0n
          );

        expect(await bridge.withdrawRoots(enterprise.address, 0n))
          .to.equal(MOCK_WITHDRAW_ROOT);
      });

      it("non-admin cannot submit withdraw root", async function () {
        await expect(
          bridge.connect(outsider).submitWithdrawRoot(
            enterprise.address, 0n, MOCK_WITHDRAW_ROOT
          )
        ).to.be.revertedWithCustomError(bridge, "OnlyAdmin");
      });

      it("reverts for non-executed batch", async function () {
        await expect(
          bridge.connect(admin).submitWithdrawRoot(
            enterprise.address,
            99n, // batch not yet executed
            MOCK_WITHDRAW_ROOT
          )
        ).to.be.revertedWithCustomError(bridge, "BatchNotExecuted");
      });

      it("reverts for uninitialized enterprise", async function () {
        await expect(
          bridge.connect(admin).submitWithdrawRoot(
            outsider.address, 0n, MOCK_WITHDRAW_ROOT
          )
        ).to.be.revertedWithCustomError(bridge, "EnterpriseNotInitialized");
      });

      it("updates lastBatchExecutionTime", async function () {
        await bridge.connect(admin).submitWithdrawRoot(
          enterprise.address, 0n, MOCK_WITHDRAW_ROOT
        );

        const lastExec = await bridge.lastBatchExecutionTime(enterprise.address);
        expect(lastExec).to.be.gt(0n);
      });
    });

    describe("recordBatchExecution", function () {
      it("admin can record batch execution", async function () {
        const tx = bridge.connect(admin).recordBatchExecution(enterprise.address);
        await expect(tx).to.emit(bridge, "BatchExecutionRecorded");
      });

      it("non-admin cannot record batch execution", async function () {
        await expect(
          bridge.connect(outsider).recordBatchExecution(enterprise.address)
        ).to.be.revertedWithCustomError(bridge, "OnlyAdmin");
      });
    });
  });

  // =====================================================================
  // VIEW FUNCTIONS
  // =====================================================================

  describe("View Functions", function () {
    it("getBridgeBalance returns deposited minus withdrawn", async function () {
      await bridge.connect(user1).deposit(
        enterprise.address, user1.address, { value: ethers.parseEther("5") }
      );

      expect(await bridge.getBridgeBalance(enterprise.address))
        .to.equal(ethers.parseEther("5"));

      // Submit withdraw root and claim
      await bridge.connect(admin).submitWithdrawRoot(
        enterprise.address, 0n, MOCK_WITHDRAW_ROOT
      );
      await bridge.connect(user2).claimWithdrawal(
        enterprise.address, 0n, user1.address, ONE_ETH, 0n, []
      );

      expect(await bridge.getBridgeBalance(enterprise.address))
        .to.equal(ethers.parseEther("4"));
    });

    it("isWithdrawalClaimed tracks claims correctly", async function () {
      await bridge.connect(user1).deposit(
        enterprise.address, user1.address, { value: ethers.parseEther("5") }
      );
      await bridge.connect(admin).submitWithdrawRoot(
        enterprise.address, 0n, MOCK_WITHDRAW_ROOT
      );

      const withdrawalHash = computeWithdrawalHash(
        enterprise.address, 0n, user1.address, ONE_ETH, 0n
      );

      expect(await bridge.isWithdrawalClaimed(enterprise.address, withdrawalHash))
        .to.be.false;

      await bridge.connect(user2).claimWithdrawal(
        enterprise.address, 0n, user1.address, ONE_ETH, 0n, []
      );

      expect(await bridge.isWithdrawalClaimed(enterprise.address, withdrawalHash))
        .to.be.true;
    });

    it("hasEscaped tracks escape withdrawals", async function () {
      expect(await bridge.hasEscaped(enterprise.address, user1.address)).to.be.false;

      // Setup escape
      await bridge.connect(user1).deposit(
        enterprise.address, user1.address, { value: ethers.parseEther("5") }
      );
      await bridge.connect(admin).recordBatchExecution(enterprise.address);
      await advanceTime(ESCAPE_TIMEOUT + 1);
      await bridge.connect(outsider).activateEscapeHatch(enterprise.address);

      await bridge.connect(user2).escapeWithdraw(
        enterprise.address, user1.address, ONE_ETH, [], 0n
      );

      expect(await bridge.hasEscaped(enterprise.address, user1.address)).to.be.true;
    });

    it("timeUntilEscape returns correct values", async function () {
      // Before any batch execution
      expect(await bridge.timeUntilEscape(enterprise.address))
        .to.equal(ethers.MaxUint256);

      // After batch execution
      await bridge.connect(admin).recordBatchExecution(enterprise.address);
      const timeLeft = await bridge.timeUntilEscape(enterprise.address);
      // Should be approximately ESCAPE_TIMEOUT (within a few seconds)
      expect(timeLeft).to.be.closeTo(BigInt(ESCAPE_TIMEOUT), 5n);

      // After timeout
      await advanceTime(ESCAPE_TIMEOUT + 1);
      expect(await bridge.timeUntilEscape(enterprise.address)).to.equal(0n);
    });
  });

  // =====================================================================
  // INVARIANT CROSS-CHECKS
  // [Spec: BasisBridge.tla, BalanceConservation]
  // =====================================================================

  describe("Balance Conservation (INV-B2)", function () {
    it("contract balance equals totalDeposited - totalWithdrawn", async function () {
      // Deposit
      await bridge.connect(user1).deposit(
        enterprise.address, user1.address, { value: ethers.parseEther("5") }
      );
      await bridge.connect(user2).deposit(
        enterprise.address, user2.address, { value: ethers.parseEther("3") }
      );

      // Claim withdrawal
      await bridge.connect(admin).submitWithdrawRoot(
        enterprise.address, 0n, MOCK_WITHDRAW_ROOT
      );
      await bridge.connect(outsider).claimWithdrawal(
        enterprise.address, 0n, user1.address, ONE_ETH, 0n, []
      );

      const deposited = await bridge.totalDeposited(enterprise.address);
      const withdrawn = await bridge.totalWithdrawn(enterprise.address);
      const contractBalance = await ethers.provider.getBalance(await bridge.getAddress());

      // INV-B2: deposited - withdrawn == contract balance
      expect(deposited - withdrawn).to.equal(contractBalance);
    });

    it("conservation holds after escape withdrawal", async function () {
      await bridge.connect(user1).deposit(
        enterprise.address, user1.address, { value: ethers.parseEther("5") }
      );

      // Trigger escape
      await bridge.connect(admin).recordBatchExecution(enterprise.address);
      await advanceTime(ESCAPE_TIMEOUT + 1);
      await bridge.connect(outsider).activateEscapeHatch(enterprise.address);

      // Escape withdraw
      await bridge.connect(user2).escapeWithdraw(
        enterprise.address, user1.address, ONE_ETH, [], 0n
      );

      const deposited = await bridge.totalDeposited(enterprise.address);
      const withdrawn = await bridge.totalWithdrawn(enterprise.address);
      const contractBalance = await ethers.provider.getBalance(await bridge.getAddress());

      expect(deposited - withdrawn).to.equal(contractBalance);
    });
  });
});
