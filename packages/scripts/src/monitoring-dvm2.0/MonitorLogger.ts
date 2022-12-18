import { createEtherscanLinkMarkdown, createFormatFunction } from "@uma/common";
import { Logger } from "@uma/financial-templates-lib";
import type { BigNumber } from "ethers";

export const logLargeUnstake = (
  logger: typeof Logger,
  unstake: {
    tx: string;
    address: string;
    amount: string;
  },
  chainId: number
): void => {
  logger.warn({
    at: "DVMMonitorUnstake",
    message: "Large unstake requested 😟",
    mrkdwn:
      createEtherscanLinkMarkdown(unstake.address, chainId) +
      " requested unstake of " +
      createFormatFunction(2, 0, false, 18)(unstake.amount) +
      " UMA at " +
      createEtherscanLinkMarkdown(unstake.tx, chainId),
  });
};

export const logLargeStake = (
  logger: typeof Logger,
  stake: {
    tx: string;
    address: string;
    amount: string;
  },
  chainId: number
): void => {
  logger.warn({
    at: "DVMMonitorStake",
    message: "Large amount staked 🍖",
    mrkdwn:
      createEtherscanLinkMarkdown(stake.address, chainId) +
      " staked " +
      createFormatFunction(2, 0, false, 18)(stake.amount) +
      " UMA at " +
      createEtherscanLinkMarkdown(stake.tx, chainId),
  });
};

export const logGovernanceProposal = (
  logger: typeof Logger,
  proposal: {
    tx: string;
    id: string;
  },
  chainId: number
): void => {
  logger.warn({
    at: "DVMMonitorGovernance",
    message: "New governance proposal created 📜",
    mrkdwn: "New Admin " + proposal.id + " proposal created at " + createEtherscanLinkMarkdown(proposal.tx, chainId),
  });
};

export const logDeletionProposed = (
  logger: typeof Logger,
  proposal: {
    tx: string;
    proposalId: string;
    sender: string;
    spamRequestIndices: [BigNumber, BigNumber][];
  },
  chainId: number
): void => {
  const identifiers = proposal.spamRequestIndices
    .map((range) => (range[0].eq(range[1]) ? range[0].toString() : `${range[0]}-${range[1]}`))
    .join(", ");
  logger.warn({
    at: "DVMMonitorDeletion",
    message: "New spam deletion proposal created 🔇",
    mrkdwn:
      createEtherscanLinkMarkdown(proposal.sender, chainId) +
      " proposed deletion of requests with following indices: " +
      identifiers +
      " at " +
      createEtherscanLinkMarkdown(proposal.tx, chainId),
  });
};
