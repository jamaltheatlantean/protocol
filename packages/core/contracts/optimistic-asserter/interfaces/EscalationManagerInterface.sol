// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.16;

import "./OptimisticAsserterCallbackRecipientInterface.sol";
import "./OptimisticAsserterInterface.sol";

interface EscalationManagerInterface is OptimisticAsserterCallbackRecipientInterface {
    struct AssertionPolicy {
        bool blockAssertion;
        bool arbitrateViaEscalationManager;
        bool discardOracle;
        bool validateDisputers;
    }

    function getAssertionPolicy(bytes32 assertionId) external view returns (AssertionPolicy memory);

    function isDisputeAllowed(bytes32 assertionId, address disputeCaller) external view returns (bool);

    function getPrice(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData
    ) external returns (int256);

    function requestPrice(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData
    ) external;
}
