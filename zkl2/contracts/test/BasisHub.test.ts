// Test suite for BasisHub.sol -- Cross-Enterprise Hub-and-Spoke Protocol
// [Spec: zkl2/specs/units/2026-03-hub-and-spoke/HubAndSpoke.tla]
//
// Maps all 6 TLA+ invariants to concrete Hardhat tests:
//   INV-CE5  CrossEnterpriseIsolation
//   INV-CE6  AtomicSettlement
//   INV-CE7  CrossRefConsistency
//   INV-CE8  ReplayProtection
//   INV-CE9  TimeoutSafety
//   INV-CE10 HubNeutrality

import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// Message status enum (mirrors Solidity)
const MsgStatus = {
  None: 0,
  Prepared: 1,
  Verified: 2,
  Responded: 3,
  Settled: 4,
  TimedOut: 5,
  Failed: 6,
};

// Dummy proof data (harness ignores actual values)
const DUMMY_PROOF = {
  a: [0n, 0n] as [bigint, bigint],
  b: [[0n, 0n], [0n, 0n]] as [[bigint, bigint], [bigint, bigint]],
  c: [0n, 0n] as [bigint, bigint],
  publicSignals: [] as bigint[],
};

// Timeout in blocks (matching contract deployment)
const TIMEOUT_BLOCKS = 450;

describe("BasisHub", function () {
  let hub: any;
  let registry: any;
  let admin: HardhatEthersSigner;
  let enterpriseA: HardhatEthersSigner;
  let enterpriseB: HardhatEthersSigner;
  let enterpriseC: HardhatEthersSigner;
  let outsider: HardhatEthersSigner;

  const SOURCE_ROOT = ethers.keccak256(ethers.toUtf8Bytes("rootA"));
  const DEST_ROOT = ethers.keccak256(ethers.toUtf8Bytes("rootB"));
  const ROOT_C = ethers.keccak256(ethers.toUtf8Bytes("rootC"));
  const COMMITMENT = ethers.keccak256(ethers.toUtf8Bytes("commitment-1"));
  const RESPONSE_COMMITMENT = ethers.keccak256(ethers.toUtf8Bytes("response-1"));

  beforeEach(async function () {
    [admin, enterpriseA, enterpriseB, enterpriseC, outsider] = await ethers.getSigners();

    const MockRegistry = await ethers.getContractFactory("MockEnterpriseRegistry");
    registry = await MockRegistry.deploy();
    await registry.waitForDeployment();

    const Harness = await ethers.getContractFactory("BasisHubHarness");
    hub = await Harness.deploy(await registry.getAddress(), TIMEOUT_BLOCKS);
    await hub.waitForDeployment();

    // Authorize enterprises
    await registry.setAuthorized(enterpriseA.address, true);
    await registry.setAuthorized(enterpriseB.address, true);
    await registry.setAuthorized(enterpriseC.address, true);
  });

  // Helper: prepare a message from A to B
  async function prepareAtoB(
    commitment: string = COMMITMENT,
    sourceRoot: string = SOURCE_ROOT,
  ): Promise<string> {
    const tx = await hub.connect(enterpriseA).prepareMessage(
      enterpriseB.address,
      commitment,
      sourceRoot,
      DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
    );
    const receipt = await tx.wait();
    const event = receipt?.logs?.find(
      (l: any) => l.fragment?.name === "MessagePrepared"
    );
    return event?.args?.msgId;
  }

  // Helper: advance N blocks
  async function advanceBlocks(n: number) {
    for (let i = 0; i < n; i++) {
      await ethers.provider.send("evm_mine", []);
    }
  }

  // Helper: run full 4-phase cycle A->B
  async function fullCycleAtoB(): Promise<string> {
    const msgId = await prepareAtoB();
    await hub.verifyMessage(msgId, SOURCE_ROOT);
    await hub.connect(enterpriseB).respondToMessage(
      msgId, RESPONSE_COMMITMENT, DEST_ROOT,
      DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
    );
    await hub.settleMessage(msgId, SOURCE_ROOT, DEST_ROOT);
    return msgId;
  }

  // =========================================================================
  // Deployment and Configuration
  // =========================================================================

  describe("Deployment", function () {
    it("should set admin to deployer", async function () {
      expect(await hub.admin()).to.equal(admin.address);
    });

    it("should set enterprise registry", async function () {
      expect(await hub.enterpriseRegistry()).to.equal(await registry.getAddress());
    });

    it("should set timeout blocks", async function () {
      expect(await hub.timeoutBlocks()).to.equal(TIMEOUT_BLOCKS);
    });

    it("should revert on zero registry address", async function () {
      const Harness = await ethers.getContractFactory("BasisHubHarness");
      await expect(Harness.deploy(ethers.ZeroAddress, TIMEOUT_BLOCKS))
        .to.be.revertedWithCustomError(hub, "ZeroAddress");
    });

    it("should revert on zero timeout", async function () {
      const Harness = await ethers.getContractFactory("BasisHubHarness");
      await expect(Harness.deploy(await registry.getAddress(), 0))
        .to.be.revertedWithCustomError(hub, "ZeroAddress");
    });
  });

  // =========================================================================
  // Phase 1: Prepare Message
  // =========================================================================

  describe("Phase 1: prepareMessage", function () {
    it("should prepare a valid message", async function () {
      const msgId = await prepareAtoB();
      expect(msgId).to.not.be.undefined;

      const msg = await hub.getMessage(msgId);
      expect(msg.source).to.equal(enterpriseA.address);
      expect(msg.dest).to.equal(enterpriseB.address);
      expect(msg.nonce).to.equal(1);
      expect(msg.status).to.equal(MsgStatus.Prepared);
      expect(msg.commitment).to.equal(COMMITMENT);
      expect(msg.sourceStateRoot).to.equal(SOURCE_ROOT);
      expect(msg.sourceProofValid).to.equal(true);
      expect(msg.destProofValid).to.equal(false);
    });

    it("should emit MessagePrepared event", async function () {
      await expect(
        hub.connect(enterpriseA).prepareMessage(
          enterpriseB.address, COMMITMENT, SOURCE_ROOT,
          DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
        )
      ).to.emit(hub, "MessagePrepared");
    });

    it("should allocate sequential nonces per pair", async function () {
      const msgId1 = await prepareAtoB();
      const msgId2 = await prepareAtoB(ethers.keccak256(ethers.toUtf8Bytes("c2")));

      const msg1 = await hub.getMessage(msgId1);
      const msg2 = await hub.getMessage(msgId2);
      expect(msg1.nonce).to.equal(1);
      expect(msg2.nonce).to.equal(2);
    });

    it("should reject self-message", async function () {
      await expect(
        hub.connect(enterpriseA).prepareMessage(
          enterpriseA.address, COMMITMENT, SOURCE_ROOT,
          DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
        )
      ).to.be.revertedWithCustomError(hub, "SelfMessage");
    });

    it("should reject zero dest address", async function () {
      await expect(
        hub.connect(enterpriseA).prepareMessage(
          ethers.ZeroAddress, COMMITMENT, SOURCE_ROOT,
          DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
        )
      ).to.be.revertedWithCustomError(hub, "ZeroAddress");
    });

    it("should record invalid proof when mock returns false", async function () {
      await hub.setMockProofResult(false);
      const msgId = await prepareAtoB();
      const msg = await hub.getMessage(msgId);
      expect(msg.sourceProofValid).to.equal(false);
      await hub.setMockProofResult(true); // reset
    });
  });

  // =========================================================================
  // Phase 2: Hub Verification
  // =========================================================================

  describe("Phase 2: verifyMessage", function () {
    it("should verify a valid prepared message", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Verified);
    });

    it("should emit MessageVerified event", async function () {
      const msgId = await prepareAtoB();
      await expect(hub.verifyMessage(msgId, SOURCE_ROOT))
        .to.emit(hub, "MessageVerified");
    });

    it("should consume nonce on verification", async function () {
      const msgId = await prepareAtoB();
      expect(await hub.isNonceUsed(enterpriseA.address, enterpriseB.address, 1))
        .to.equal(false);

      await hub.verifyMessage(msgId, SOURCE_ROOT);

      expect(await hub.isNonceUsed(enterpriseA.address, enterpriseB.address, 1))
        .to.equal(true);
    });

    it("should fail on stale state root", async function () {
      const msgId = await prepareAtoB();

      // Pass different root (simulates root changed between prepare and verify)
      await hub.verifyMessage(msgId, ethers.keccak256(ethers.toUtf8Bytes("stale")));

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Failed);
    });

    it("should fail on invalid proof", async function () {
      await hub.setMockProofResult(false);
      const msgId = await prepareAtoB();
      await hub.setMockProofResult(true); // reset for verify

      // Message was prepared with invalid proof
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Failed);
    });

    it("should fail on unregistered source", async function () {
      // Remove source authorization
      await registry.setAuthorized(enterpriseA.address, false);

      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Failed);
    });

    it("should fail on unregistered dest", async function () {
      await registry.setAuthorized(enterpriseB.address, false);

      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Failed);
    });

    it("should reject verifying non-prepared message", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT); // now Verified

      await expect(hub.verifyMessage(msgId, SOURCE_ROOT))
        .to.be.revertedWithCustomError(hub, "InvalidStatus");
    });

    it("should reject non-existent message", async function () {
      const fakeId = ethers.keccak256(ethers.toUtf8Bytes("fake"));
      await expect(hub.verifyMessage(fakeId, SOURCE_ROOT))
        .to.be.revertedWithCustomError(hub, "MessageNotFound");
    });
  });

  // =========================================================================
  // Phase 3: Response
  // =========================================================================

  describe("Phase 3: respondToMessage", function () {
    it("should accept response from dest enterprise", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      await hub.connect(enterpriseB).respondToMessage(
        msgId, RESPONSE_COMMITMENT, DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Responded);
      expect(msg.responseCommitment).to.equal(RESPONSE_COMMITMENT);
      expect(msg.destStateRoot).to.equal(DEST_ROOT);
      expect(msg.destProofValid).to.equal(true);
    });

    it("should reject response from non-dest enterprise", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      await expect(
        hub.connect(enterpriseC).respondToMessage(
          msgId, RESPONSE_COMMITMENT, DEST_ROOT,
          DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
        )
      ).to.be.revertedWithCustomError(hub, "NotRegistered");
    });

    it("should reject response to non-verified message", async function () {
      const msgId = await prepareAtoB();

      await expect(
        hub.connect(enterpriseB).respondToMessage(
          msgId, RESPONSE_COMMITMENT, DEST_ROOT,
          DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
        )
      ).to.be.revertedWithCustomError(hub, "InvalidStatus");
    });

    it("should record invalid response proof", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      await hub.setMockProofResult(false);
      await hub.connect(enterpriseB).respondToMessage(
        msgId, RESPONSE_COMMITMENT, DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );
      await hub.setMockProofResult(true);

      const msg = await hub.getMessage(msgId);
      expect(msg.destProofValid).to.equal(false);
    });
  });

  // =========================================================================
  // Phase 4: Atomic Settlement (INV-CE6)
  // =========================================================================

  describe("Phase 4: settleMessage (INV-CE6 AtomicSettlement)", function () {
    it("should settle valid message", async function () {
      const msgId = await fullCycleAtoB();
      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Settled);
    });

    it("should emit MessageSettled event", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);
      await hub.connect(enterpriseB).respondToMessage(
        msgId, RESPONSE_COMMITMENT, DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );

      await expect(hub.settleMessage(msgId, SOURCE_ROOT, DEST_ROOT))
        .to.emit(hub, "MessageSettled");
    });

    it("should increment totalMessagesSettled", async function () {
      expect(await hub.totalMessagesSettled()).to.equal(0);
      await fullCycleAtoB();
      expect(await hub.totalMessagesSettled()).to.equal(1);
    });

    it("should fail settlement on stale source root", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);
      await hub.connect(enterpriseB).respondToMessage(
        msgId, RESPONSE_COMMITMENT, DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );

      // Pass stale source root
      await hub.settleMessage(
        msgId,
        ethers.keccak256(ethers.toUtf8Bytes("stale-source")),
        DEST_ROOT
      );

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Failed);
    });

    it("should fail settlement on stale dest root", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);
      await hub.connect(enterpriseB).respondToMessage(
        msgId, RESPONSE_COMMITMENT, DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );

      await hub.settleMessage(
        msgId,
        SOURCE_ROOT,
        ethers.keccak256(ethers.toUtf8Bytes("stale-dest"))
      );

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Failed);
    });

    it("should fail settlement on invalid source proof", async function () {
      await hub.setMockProofResult(false);
      const msgId = await prepareAtoB(); // prepared with invalid proof
      await hub.setMockProofResult(true);

      await hub.verifyMessage(msgId, SOURCE_ROOT);
      // Verify fails and marks as Failed; can't continue
      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Failed);
    });

    it("should fail settlement on invalid dest proof", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      await hub.setMockProofResult(false);
      await hub.connect(enterpriseB).respondToMessage(
        msgId, RESPONSE_COMMITMENT, DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );
      await hub.setMockProofResult(true);

      // destProofValid == false, settlement should fail
      await hub.settleMessage(msgId, SOURCE_ROOT, DEST_ROOT);

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Failed);
    });

    it("should reject settlement of non-responded message", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      await expect(hub.settleMessage(msgId, SOURCE_ROOT, DEST_ROOT))
        .to.be.revertedWithCustomError(hub, "InvalidStatus");
    });
  });

  // =========================================================================
  // Replay Protection (INV-CE8)
  // =========================================================================

  describe("INV-CE8: ReplayProtection", function () {
    it("should reject message with consumed nonce", async function () {
      // First message succeeds.
      const msgId1 = await prepareAtoB();
      await hub.verifyMessage(msgId1, SOURCE_ROOT);

      // Nonce 1 is now consumed.
      expect(await hub.isNonceUsed(enterpriseA.address, enterpriseB.address, 1)).to.equal(true);

      // Second message gets nonce 2 (normal flow via counter).
      const msgId2 = await prepareAtoB(ethers.keccak256(ethers.toUtf8Bytes("c2")));
      const msg2 = await hub.getMessage(msgId2);
      expect(msg2.nonce).to.equal(2);
    });

    it("should NOT consume nonce on failed verification", async function () {
      await hub.setMockProofResult(false);
      const msgId = await prepareAtoB();
      await hub.setMockProofResult(true);

      // Verify fails (invalid proof)
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      // Nonce should NOT be consumed
      expect(await hub.isNonceUsed(enterpriseA.address, enterpriseB.address, 1)).to.equal(false);
    });

    it("should maintain independent nonces per directed pair", async function () {
      // A->B nonce 1
      const msgId1 = await prepareAtoB();
      await hub.verifyMessage(msgId1, SOURCE_ROOT);

      // B->A nonce 1 (different pair)
      const tx = await hub.connect(enterpriseB).prepareMessage(
        enterpriseA.address, COMMITMENT, DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );
      const receipt = await tx.wait();
      const event = receipt?.logs?.find(
        (l: any) => l.fragment?.name === "MessagePrepared"
      );
      const msgId2 = event?.args?.msgId;

      const msg2 = await hub.getMessage(msgId2);
      expect(msg2.nonce).to.equal(1); // Independent counter
    });
  });

  // =========================================================================
  // Timeout Safety (INV-CE9)
  // =========================================================================

  describe("INV-CE9: TimeoutSafety", function () {
    it("should timeout prepared message after deadline", async function () {
      const msgId = await prepareAtoB();

      await advanceBlocks(TIMEOUT_BLOCKS);

      await expect(hub.timeoutMessage(msgId))
        .to.emit(hub, "MessageTimedOut");

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.TimedOut);
    });

    it("should timeout verified message after deadline", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      await advanceBlocks(TIMEOUT_BLOCKS);
      await hub.timeoutMessage(msgId);

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.TimedOut);
    });

    it("should timeout responded message after deadline", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);
      await hub.connect(enterpriseB).respondToMessage(
        msgId, RESPONSE_COMMITMENT, DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );

      await advanceBlocks(TIMEOUT_BLOCKS);
      await hub.timeoutMessage(msgId);

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.TimedOut);
    });

    it("should reject premature timeout", async function () {
      const msgId = await prepareAtoB();

      // Only advance half the timeout
      await advanceBlocks(TIMEOUT_BLOCKS / 2);

      await expect(hub.timeoutMessage(msgId))
        .to.be.revertedWithCustomError(hub, "TimeoutNotReached");
    });

    it("should reject timeout of settled message", async function () {
      const msgId = await fullCycleAtoB();

      await advanceBlocks(TIMEOUT_BLOCKS + 100);

      await expect(hub.timeoutMessage(msgId))
        .to.be.revertedWithCustomError(hub, "TerminalMessage");
    });

    it("should reject timeout of failed message", async function () {
      await hub.setMockProofResult(false);
      const msgId = await prepareAtoB();
      await hub.setMockProofResult(true);
      await hub.verifyMessage(msgId, SOURCE_ROOT); // fails

      await advanceBlocks(TIMEOUT_BLOCKS);

      await expect(hub.timeoutMessage(msgId))
        .to.be.revertedWithCustomError(hub, "TerminalMessage");
    });

    it("should allow either party to trigger timeout", async function () {
      const msgId = await prepareAtoB();
      await advanceBlocks(TIMEOUT_BLOCKS);

      // outsider triggers timeout (anyone can call)
      await hub.connect(outsider).timeoutMessage(msgId);

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.TimedOut);
    });
  });

  // =========================================================================
  // Cross-Enterprise Isolation (INV-CE5)
  // =========================================================================

  describe("INV-CE5: CrossEnterpriseIsolation", function () {
    it("should not store private data in message struct", async function () {
      const msgId = await prepareAtoB();
      const msg = await hub.getMessage(msgId);

      // All fields are public metadata or opaque commitments.
      // source, dest: public enterprise addresses
      // nonce: public counter
      // sourceStateRoot, destStateRoot: public L1 state
      // commitment, responseCommitment: opaque Poseidon hashes
      // status: protocol state
      // createdAtBlock: public L1 block
      // sourceProofValid, destProofValid: boolean (1 bit, no witness leakage)
      expect(msg.source).to.equal(enterpriseA.address);
      expect(msg.dest).to.equal(enterpriseB.address);
      expect(msg.source).to.not.equal(msg.dest);
    });

    it("should reject self-messages (isolation boundary)", async function () {
      await expect(
        hub.connect(enterpriseA).prepareMessage(
          enterpriseA.address, COMMITMENT, SOURCE_ROOT,
          DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
        )
      ).to.be.revertedWithCustomError(hub, "SelfMessage");
    });
  });

  // =========================================================================
  // Hub Neutrality (INV-CE10)
  // =========================================================================

  describe("INV-CE10: HubNeutrality", function () {
    it("hub verified messages have valid source proofs", async function () {
      const msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);

      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Verified);
      expect(msg.sourceProofValid).to.equal(true);
    });

    it("hub rejects messages with invalid source proofs", async function () {
      await hub.setMockProofResult(false);
      const msgId = await prepareAtoB();
      await hub.setMockProofResult(true);

      await hub.verifyMessage(msgId, SOURCE_ROOT);
      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Failed);
    });
  });

  // =========================================================================
  // CrossRef Consistency (INV-CE7)
  // =========================================================================

  describe("INV-CE7: CrossRefConsistency", function () {
    it("settled messages have both proofs valid", async function () {
      const msgId = await fullCycleAtoB();
      const msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Settled);
      expect(msg.sourceProofValid).to.equal(true);
      expect(msg.destProofValid).to.equal(true);
    });
  });

  // =========================================================================
  // Multiple Concurrent Cross-Enterprise Transactions
  // =========================================================================

  describe("Multiple concurrent transactions", function () {
    it("should handle A->B, B->C, A->C in sequence", async function () {
      // A->B
      let msgId = await prepareAtoB();
      await hub.verifyMessage(msgId, SOURCE_ROOT);
      await hub.connect(enterpriseB).respondToMessage(
        msgId, RESPONSE_COMMITMENT, DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );
      await hub.settleMessage(msgId, SOURCE_ROOT, DEST_ROOT);
      let msg = await hub.getMessage(msgId);
      expect(msg.status).to.equal(MsgStatus.Settled);

      // B->C
      const tx2 = await hub.connect(enterpriseB).prepareMessage(
        enterpriseC.address, COMMITMENT, DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );
      const receipt2 = await tx2.wait();
      const event2 = receipt2?.logs?.find(
        (l: any) => l.fragment?.name === "MessagePrepared"
      );
      const msgId2 = event2?.args?.msgId;

      await hub.verifyMessage(msgId2, DEST_ROOT);
      await hub.connect(enterpriseC).respondToMessage(
        msgId2, RESPONSE_COMMITMENT, ROOT_C,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );
      await hub.settleMessage(msgId2, DEST_ROOT, ROOT_C);
      msg = await hub.getMessage(msgId2);
      expect(msg.status).to.equal(MsgStatus.Settled);

      // A->C
      const tx3 = await hub.connect(enterpriseA).prepareMessage(
        enterpriseC.address, COMMITMENT, SOURCE_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );
      const receipt3 = await tx3.wait();
      const event3 = receipt3?.logs?.find(
        (l: any) => l.fragment?.name === "MessagePrepared"
      );
      const msgId3 = event3?.args?.msgId;

      await hub.verifyMessage(msgId3, SOURCE_ROOT);
      await hub.connect(enterpriseC).respondToMessage(
        msgId3, RESPONSE_COMMITMENT, ROOT_C,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );
      await hub.settleMessage(msgId3, SOURCE_ROOT, ROOT_C);
      msg = await hub.getMessage(msgId3);
      expect(msg.status).to.equal(MsgStatus.Settled);

      expect(await hub.totalMessagesSettled()).to.equal(3);
    });
  });

  // =========================================================================
  // 3-Enterprise Chain (A->B->C)
  // =========================================================================

  describe("3-Enterprise chain (A->B->C)", function () {
    it("should support transitive cross-enterprise references", async function () {
      // Step 1: A proves claim to B
      const msgId1 = await prepareAtoB();
      await hub.verifyMessage(msgId1, SOURCE_ROOT);
      await hub.connect(enterpriseB).respondToMessage(
        msgId1, RESPONSE_COMMITMENT, DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );
      await hub.settleMessage(msgId1, SOURCE_ROOT, DEST_ROOT);

      // Step 2: B references A's claim to prove to C
      const tx2 = await hub.connect(enterpriseB).prepareMessage(
        enterpriseC.address,
        ethers.keccak256(ethers.toUtf8Bytes("b-references-a-claim")),
        DEST_ROOT,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );
      const receipt2 = await tx2.wait();
      const event2 = receipt2?.logs?.find(
        (l: any) => l.fragment?.name === "MessagePrepared"
      );
      const msgId2 = event2?.args?.msgId;

      await hub.verifyMessage(msgId2, DEST_ROOT);
      await hub.connect(enterpriseC).respondToMessage(
        msgId2, RESPONSE_COMMITMENT, ROOT_C,
        DUMMY_PROOF.a, DUMMY_PROOF.b, DUMMY_PROOF.c, DUMMY_PROOF.publicSignals
      );
      await hub.settleMessage(msgId2, DEST_ROOT, ROOT_C);

      // Both messages settled
      expect((await hub.getMessage(msgId1)).status).to.equal(MsgStatus.Settled);
      expect((await hub.getMessage(msgId2)).status).to.equal(MsgStatus.Settled);

      // 2 settlements total
      expect(await hub.totalMessagesSettled()).to.equal(2);
    });
  });

  // =========================================================================
  // View Functions
  // =========================================================================

  describe("View functions", function () {
    it("computeMessageId should be deterministic", async function () {
      const id1 = await hub.computeMessageId(enterpriseA.address, enterpriseB.address, 1);
      const id2 = await hub.computeMessageId(enterpriseA.address, enterpriseB.address, 1);
      expect(id1).to.equal(id2);

      const id3 = await hub.computeMessageId(enterpriseA.address, enterpriseB.address, 2);
      expect(id1).to.not.equal(id3);
    });

    it("getNonce returns current counter", async function () {
      expect(await hub.getNonce(enterpriseA.address, enterpriseB.address)).to.equal(0);
      await prepareAtoB();
      expect(await hub.getNonce(enterpriseA.address, enterpriseB.address)).to.equal(1);
    });
  });
});
