// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.16;

interface SlashingLibraryInterface {
    /**
     * @notice Calculates the wrong vote slash per token.
     * @param totalStaked The total amount of tokens staked.
     * @param totalVotes The total amount of votes.
     * @param totalCorrectVotes The total amount of correct votes.
     * @return uint256 The amount of tokens to slash per token staked.
     */
    function calcWrongVoteSlashPerToken(
        uint256 totalStaked,
        uint256 totalVotes,
        uint256 totalCorrectVotes
    ) external pure returns (uint256);

    /**
     * @notice Calculates the wrong vote slash per token for governance requests.
     * @param totalStaked The total amount of tokens staked.
     * @param totalVotes The total amount of votes.
     * @param totalCorrectVotes The total amount of correct votes.
     * @return uint256 The amount of tokens to slash per token staked.
     */
    function calcWrongVoteSlashPerTokenGovernance(
        uint256 totalStaked,
        uint256 totalVotes,
        uint256 totalCorrectVotes
    ) external pure returns (uint256);

    /**
     * @notice Calculates the no vote slash per token.
     * @param totalStaked The total amount of tokens staked.
     * @param totalVotes The total amount of votes.
     * @param totalCorrectVotes The total amount of correct votes.
     * @return uint256 The amount of tokens to slash per token staked.
     */
    function calcNoVoteSlashPerToken(
        uint256 totalStaked,
        uint256 totalVotes,
        uint256 totalCorrectVotes
    ) external pure returns (uint256);

    /**
     * @notice Calculates all slashing trackers in one go to decrease cross-contract calls needed.
     * @param totalStaked The total amount of tokens staked.
     * @param totalVotes The total amount of votes.
     * @param totalCorrectVotes The total amount of correct votes.
     * @return wrongVoteSlashPerToken The amount of tokens to slash for voting wrong.
     * @return noVoteSlashPerToken The amount of tokens to slash for not voting.
     */
    function calcSlashing(
        uint256 totalStaked,
        uint256 totalVotes,
        uint256 totalCorrectVotes,
        bool isGovernance
    ) external pure returns (uint256 wrongVoteSlashPerToken, uint256 noVoteSlashPerToken);
}
