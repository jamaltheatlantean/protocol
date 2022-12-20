import { VotingV2Ethers } from "@uma/contracts-node";
import { BigNumber } from "ethers";
import { increaseEvmTime } from "../utils/utils";

const hre = require("hardhat");
const { ethers } = hre;

export const getUniqueVoters = async (votingV2: VotingV2Ethers): Promise<string[]> => {
  const stakedEvents = await votingV2.queryFilter(votingV2.filters.Staked(null, null, null));
  const uniqueVoters = new Set<string>(stakedEvents.map((event) => event.args.voter));
  return Array.from(uniqueVoters);
};

export const updateTrackers = async (votingV2: VotingV2Ethers, voters: string[]): Promise<void> => {
  console.log("Updating trackers for all voters");
  const tx = await votingV2.multicall(
    voters.map((voter) => votingV2.interface.encodeFunctionData("updateTrackers", [voter]))
  );
  await tx.wait();
  console.log("Done updating trackers for all voters");
};

export const getSumSlashedEvents = async (votingV2: VotingV2Ethers): Promise<BigNumber> => {
  const voterSlashedEvents = await votingV2.queryFilter(votingV2.filters.VoterSlashed(), 0, "latest");
  return voterSlashedEvents
    .map((voterSlashedEvent) => voterSlashedEvent.args.slashedTokens)
    .reduce((a, b) => a.add(b), ethers.BigNumber.from(0));
};

export const unstakeFromStakedAccount = async (votingV2: VotingV2Ethers, voter: string): Promise<void> => {
  let stakeBalance = await votingV2.callStatic.getVoterStakePostUpdate(voter);

  if (stakeBalance.gt(ethers.BigNumber.from(0))) {
    console.log("Unstaking from", voter, stakeBalance.toString());
    const impersonatedSigner = await ethers.getImpersonatedSigner(voter);
    const voterStake = await votingV2.voterStakes(voter);
    if (voterStake.pendingUnstake.gt(ethers.BigNumber.from(0))) {
      console.log("Staker", voter, "has a pending unstake. Executing then re-unstaking");
      const unstakeTime = voterStake.unstakeRequestTime.add(await votingV2.unstakeCoolDown());
      const currentTime = await votingV2.getCurrentTime();
      const pendingStakeRemainingTime = unstakeTime.gt(currentTime) ? unstakeTime.sub(currentTime) : BigNumber.from(0);
      await increaseEvmTime(pendingStakeRemainingTime.toNumber());
      const tx = await votingV2.connect(impersonatedSigner).executeUnstake();
      await tx.wait();
    }

    // Move time to the next commit phase if in active reveal phase.
    const inActiveRevealPhase = (await votingV2.currentActiveRequests()) && (await votingV2.getVotePhase()) == 1;
    if (inActiveRevealPhase) {
      const phaseLength = (await votingV2.voteTiming()).phaseLength;
      const currentTime = await votingV2.getCurrentTime();
      let newTime = currentTime;
      const isCommitPhase = newTime.div(phaseLength).mod(2).eq(0);
      if (!isCommitPhase) {
        newTime = newTime.add(phaseLength.sub(newTime.mod(phaseLength)));
      }
      await increaseEvmTime(newTime.sub(currentTime).toNumber());
    }

    stakeBalance = await votingV2.callStatic.getVoterStakePostUpdate(voter);
    const tx = await votingV2.connect(impersonatedSigner).requestUnstake(stakeBalance);
    await tx.wait();
  }

  await increaseEvmTime((await votingV2.unstakeCoolDown()).toNumber());

  const pendingUnstake = (await votingV2.voterStakes(voter)).pendingUnstake;
  if (pendingUnstake.gt(ethers.BigNumber.from(0))) {
    console.log("Executing unstake from", voter, pendingUnstake.toString());
    const impersonatedSigner = await ethers.getImpersonatedSigner(voter);
    const tx = await votingV2.connect(impersonatedSigner).executeUnstake();
    await tx.wait();
  }
};
