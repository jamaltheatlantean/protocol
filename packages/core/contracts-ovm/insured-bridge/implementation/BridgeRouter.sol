// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// Importing local copies of OVM contracts is a temporary fix until the @eth-optimism/contracts package exports 0.8.x
// contracts. These contracts are relatively small and should have no problems porting from 0.7.x to 0.8.x, and
// changing their version is preferable to changing this contract to 0.7.x and defining compatible interfaces for all
// of the imported DVM contracts below.
import "./OVM_CrossDomainEnabled.sol";
import "../../../contracts/oracle/interfaces/OptimisticOracleInterface.sol";
import "../../../contracts/oracle/interfaces/IdentifierWhitelistInterface.sol";
import "../../../contracts/oracle/interfaces/StoreInterface.sol";
import "../../../contracts/oracle/interfaces/FinderInterface.sol";
import "../../../contracts/oracle/implementation/Constants.sol";
import "../../../contracts/common/interfaces/AddressWhitelistInterface.sol";
import "../../../contracts/common/implementation/AncillaryData.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice Contract deployed on L1 that has an implicit reference to a DepositBox on L2 and provides methods for
 * "Relayers" to fulfill deposit orders to that contract. The Relayers can either post capital to fulfill the deposit
 * instantly, or request that the funds are taken out of the passive liquidity provider pool following a challenge period.
 * @dev A "Deposit" is an order to send capital from L2 to L1, and a "Relay" is a fulfillment attempt of that order.
 */
contract BridgeRouter is OVM_CrossDomainEnabled, Ownable {
    using SafeERC20 for IERC20;

    // Finder used to point to latest OptimisticOracle and other DVM contracts.
    address public finder;

    // L2 Deposit contract that originates deposits that can be fulfilled by this contract.
    address public depositContract;

    // L1 token addresses are mapped to their canonical token address on L2 and the BridgePool contract that houses
    // relay liquidity for any deposits of the canonical L2 token.
    struct L1TokenRelationships {
        address l2Token;
        address bridgePool;
        uint256 proposerReward;
        uint256 proposerBond;
    }
    mapping(address => L1TokenRelationships) public whitelistedTokens;

    // Set upon construction and can be reset by Owner.
    uint256 public optimisticOracleLiveness;
    uint256 public optimisticOracleProposalReward;
    bytes32 public identifier;

    // A Deposit represents a transfer that originated on an L2 DepositBox contract and can be bridged via this contract.
    enum DepositState { Uninitialized, PendingSlow, PendingInstant, FinalizedSlow, FinalizedInstant }
    enum DepositType { Slow, Instant }

    // @dev: There is a limit to how many params a struct can contain. Without encapsulating some of the Deposit params
    // inside the RelayAncillaryDataContents struct, the compiler throws an error related to this issue:
    // https://github.com/ethereum/solidity/issues/10930.
    struct RelayAncillaryDataContents {
        uint256 depositId;
        // The following params are inferred by the L2 deposit:
        address l2Sender;
        address recipient;
        uint256 depositTimestamp;
        address l1Token;
        uint256 amount;
        uint256 maxFee;
        // Relayer will compute the realized fee considering the amount of liquidity in this contract and the pending
        // withdrawals at the depositTimestamp.
        uint256 realizedFee;
        address relayer;
    }
    struct Deposit {
        DepositState depositState;
        DepositType depositType;
        // A deposit can have both a slow and an instant relayer if a slow relay is "sped up" from slow to instant. In
        // these cases, we want to store both addresses for separate payouts.
        address slowRelayer;
        address instantRelayer;
        // @dev: See @dev note above about why some Deposit params are collapsed into `RelayAncillaryDataContents`.
        RelayAncillaryDataContents relayData;
        // Custom ancillary data crafted from `RelayAncillaryDataContents` data.
        bytes priceRequestAncillaryData;
    }
    // Associates each deposit with a unique ID.
    mapping(uint256 => Deposit) public deposits;
    // If a deposit is disputed, it is removed from the `deposits` mapping and added to the `disputedDeposits` mapping.
    // There can only be one disputed deposit per relayer for each deposit ID.
    // @dev The mapping is `depositId-->disputer-->Deposit`
    mapping(uint256 => mapping(address => Deposit)) public disputedDeposits;

    event SetDepositContract(address indexed l2DepositContract);
    event WhitelistToken(
        address indexed l1Token,
        address indexed l2Token,
        address indexed bridgePool,
        uint256 proposalReward,
        uint256 proposalBond
    );
    event DepositRelayed(
        address indexed sender,
        address recipient,
        address indexed l2Token,
        address indexed l1Token,
        address relayer,
        uint256 amount,
        address depositContract,
        uint256 realizedFee,
        uint256 maxFee
    );
    event RelaySpedUp(uint256 indexed depositId, address indexed fastRelayer, address indexed slowRelayer);
    event FinalizedRelay(uint256 indexed depositId, address indexed caller);
    event RelayDisputeSettled(uint256 indexed depositId, address indexed caller, bool disputeSuccessful);

    constructor(
        address _finder,
        address _crossDomainMessenger,
        uint256 _optimisticOracleLiveness,
        uint256 _optimisticOracleProposalReward,
        bytes32 _identifier
    ) OVM_CrossDomainEnabled(_crossDomainMessenger) {
        finder = _finder;
        require(address(_getOptimisticOracle()) != address(0), "Invalid finder");
        optimisticOracleLiveness = _optimisticOracleLiveness;
        optimisticOracleProposalReward = _optimisticOracleProposalReward;
        _setIdentifier(_identifier);
    }

    // Admin functions

    /**
     * @dev Sets new price identifier to use for relayed deposits.
     * Can only be called by the current owner.
     */
    function setIdentifier(bytes32 _identifier) public onlyOwner {
        _setIdentifier(_identifier);
    }

    /**
     * @notice Privileged account can set L2 deposit contract that originates deposit orders to be fulfilled by this
     * contract.
     * @dev Only callable by Owner of this contract.
     * @param _depositContract Address of L2 deposit contract.
     */
    function setDepositContract(address _depositContract) public onlyOwner {
        depositContract = _depositContract;
        emit SetDepositContract(depositContract);
    }

    /**
     * @notice Privileged account can associate a whitelisted token with its linked token address on L2 and its
     * BridgePool address on this network. The linked L2 token can thereafter be deposited into the Deposit contract
     * on L2 and relayed via this contract denominated in the L1 token.
     * @dev Only callable by Owner of this contract. Also initiates a cross-chain call to the L2 Deposit contract to
     * whitelist the token mapping.
     * @param _l1Token Address of L1 token that can be used to relay L2 token deposits.
     * @param _l2Token Address of L2 token whose deposits are fulfilled by `_l1Token`.
     * @param _bridgePool Address of pool contract that stores passive liquidity with which to fulfill deposits.
     * @param _l2Gas Gas limit to set for relayed message on L2
     * @param _proposalReward Proposal reward to pay relayers of this L2->L1 relay.
     * @param _proposalBond Proposal bond that relayers must pay to relay deposits for this L2->L1 relay.
     */
    function whitelistToken(
        address _l1Token,
        address _l2Token,
        address _bridgePool,
        uint32 _l2Gas,
        uint256 _proposalReward,
        uint256 _proposalBond
    ) public onlyOwner {
        require(_getCollateralWhitelist().isOnWhitelist(address(_l1Token)), "Payment token not whitelisted");
        // We want to prevent any situation where a token mapping is whitelisted on this contract but not on the
        // corresponding L2 contract.
        require(depositContract != address(0), "Deposit contract not set");

        L1TokenRelationships storage whitelistedToken = whitelistedTokens[_l1Token];
        whitelistedToken.l2Token = _l2Token;
        whitelistedToken.bridgePool = _bridgePool;
        whitelistedToken.proposerReward = _proposalReward;
        whitelistedToken.proposerBond = _proposalBond;
        sendCrossDomainMessage(
            depositContract,
            _l2Gas,
            abi.encodeWithSignature("whitelistToken(address,address)", _l1Token, whitelistedToken.l2Token)
        );
        emit WhitelistToken(
            _l1Token,
            whitelistedToken.l2Token,
            whitelistedToken.bridgePool,
            whitelistedToken.proposerReward,
            whitelistedToken.proposerBond
        );
    }

    function pauseL2Deposits() public onlyOwner {}

    // Liquidity provider functions

    function deposit(address l1Token, uint256 amount) public {}

    function withdraw(address lpToken, uint256 amount) public {}

    // Relayer functions

    /**
     * @notice Called by Relayer to execute Slow relay from L2 to L1, fulfilling a corresponding deposit order.
     * @dev There can only be one pending Slow relay for a deposit ID.
     * @dev Caller must have approved this contract to spend the final fee + proposer reward + proposer bond for `l1Token`.
     * @param depositId Unique ID corresponding to deposit order that caller wants to relay.
     * @param depositTimestamp Timestamp of Deposit emitted by L2 contract when order was initiated.
     * @param recipient Address on this network who should receive the relayed deposit.
     * @param l1Token Token currency to pay recipient. This contract stores a mapping of
     * `l1Token` to the canonical token currency on the L2 network that was deposited to the Deposit contract.
     * @param amount Deposited amount.
     * @param realizedFee Computed offchain by caller, considering the amount of available liquidity for the token
     * currency needed to pay the recipient and the count of pending withdrawals at the `depositTimestamp`. This fee
     * will be subtracted from the `amount`. If this value is computed incorrectly, then the relay can be disputed.
     * @param maxFee Maximum fee that L2 Depositor can pay. `realizedFee` <= `maxFee`.
     */
    function relayDeposit(
        uint256 depositId,
        uint256 depositTimestamp,
        address recipient,
        address l2Sender,
        address l1Token,
        uint256 amount,
        uint256 realizedFee,
        uint256 maxFee
    ) public {
        require(realizedFee <= maxFee, "Invalid realized fee");
        Deposit storage newDeposit = deposits[depositId];
        require(newDeposit.depositState == DepositState.Uninitialized, "Pending relay for deposit ID exists");
        Deposit storage disputedDeposit = disputedDeposits[depositId][msg.sender];
        require(
            disputedDeposit.depositState == DepositState.Uninitialized,
            "Pending dispute by relayer for deposit ID exists"
        );

        // TODO: Revisit these OO price request params.
        uint256 requestTimestamp = block.timestamp;
        RelayAncillaryDataContents memory newRelayData =
            RelayAncillaryDataContents({
                depositId: depositId,
                l2Sender: l2Sender,
                recipient: recipient,
                depositTimestamp: depositTimestamp,
                l1Token: l1Token,
                amount: amount,
                maxFee: maxFee,
                realizedFee: realizedFee,
                relayer: msg.sender
            });
        bytes memory customAncillaryData = _createRelayAncillaryData(newRelayData, msg.sender);

        // Store new deposit:
        newDeposit.depositState = DepositState.PendingSlow;
        newDeposit.depositType = DepositType.Slow;
        newDeposit.relayData = newRelayData;
        newDeposit.priceRequestAncillaryData = customAncillaryData;
        newDeposit.slowRelayer = msg.sender;

        // Request a price for the relay identifier and propose "true" optimistically. These methods will pull the
        // (proposer reward + proposer bond + final fee) from the caller.
        _requestOraclePriceRelay(l1Token, requestTimestamp, customAncillaryData);
        _proposeOraclePriceRelay(l1Token, requestTimestamp, customAncillaryData);

        emit DepositRelayed(
            l2Sender,
            recipient,
            whitelistedTokens[l1Token].l2Token,
            l1Token,
            msg.sender,
            amount,
            depositContract,
            realizedFee,
            maxFee
        );
    }

    function speedUpRelay(uint256 depositId) public {}

    function finalizeRelay(uint256 depositId) public {}

    function settleDisputedRelay(uint256 depositId, address slowRelayer) public {}

    // Internal functions

    function _getOptimisticOracle() private view returns (OptimisticOracleInterface) {
        return
            OptimisticOracleInterface(
                FinderInterface(finder).getImplementationAddress(OracleInterfaces.OptimisticOracle)
            );
    }

    function _getIdentifierWhitelist() private view returns (IdentifierWhitelistInterface) {
        return
            IdentifierWhitelistInterface(
                FinderInterface(finder).getImplementationAddress(OracleInterfaces.IdentifierWhitelist)
            );
    }

    function _getCollateralWhitelist() private view returns (AddressWhitelistInterface) {
        return
            AddressWhitelistInterface(
                FinderInterface(finder).getImplementationAddress(OracleInterfaces.CollateralWhitelist)
            );
    }

    function _getStore() private view returns (StoreInterface) {
        return StoreInterface(FinderInterface(finder).getImplementationAddress(OracleInterfaces.Store));
    }

    function _setIdentifier(bytes32 _identifier) private {
        require(_getIdentifierWhitelist().isIdentifierSupported(_identifier), "Identifier not registered");
        // TODO: Should we validate this _identifier? Perhaps check that its not 0x?
        identifier = _identifier;
    }

    function _requestOraclePriceRelay(
        address l1Token,
        uint256 requestTimestamp,
        bytes memory customAncillaryData
    ) private {
        OptimisticOracleInterface optimisticOracle = _getOptimisticOracle();

        uint256 proposalReward = whitelistedTokens[l1Token].proposerReward;

        // TODO: Relayer should not have to pay the proposal reward, instead they should be receiving reward from the
        // Bridge Pool.
        if (proposalReward > 0) IERC20(l1Token).safeTransferFrom(msg.sender, address(optimisticOracle), proposalReward);
        optimisticOracle.requestPrice(
            identifier,
            requestTimestamp,
            customAncillaryData,
            IERC20(l1Token),
            proposalReward
        );

        // Set the Optimistic oracle liveness for the price request.
        optimisticOracle.setCustomLiveness(identifier, requestTimestamp, customAncillaryData, optimisticOracleLiveness);

        // Set the Optimistic oracle proposer bond for the price request.
        // TODO: Assume proposal reward == proposal bond
        optimisticOracle.setBond(identifier, requestTimestamp, customAncillaryData, proposalReward);
    }

    function _proposeOraclePriceRelay(
        address l1Token,
        uint256 requestTimestamp,
        bytes memory customAncillaryData
    ) private {
        OptimisticOracleInterface optimisticOracle = _getOptimisticOracle();

        uint256 proposalBond = whitelistedTokens[l1Token].proposerBond;
        uint256 finalFee = _getStore().computeFinalFee(address(l1Token)).rawValue;
        uint256 totalBond = proposalBond + finalFee;

        // This will pull the total bond from the caller.
        IERC20(l1Token).safeTransferFrom(msg.sender, address(optimisticOracle), totalBond);
        optimisticOracle.proposePriceFor(msg.sender, msg.sender, identifier, requestTimestamp, customAncillaryData, 1);
    }

    function _createRelayAncillaryData(RelayAncillaryDataContents memory _relayData, address relayer)
        internal
        view
        returns (bytes memory)
    {
        bytes memory intermediateAncillaryData = bytes("0x");

        // Add relay data inferred from the original deposit on L2:
        intermediateAncillaryData = AncillaryData.appendKeyValueUint(
            intermediateAncillaryData,
            "depositId",
            _relayData.depositId
        );
        intermediateAncillaryData = AncillaryData.appendKeyValueUint(
            intermediateAncillaryData,
            "depositTimestamp",
            _relayData.depositTimestamp
        );
        intermediateAncillaryData = AncillaryData.appendKeyValueAddress(
            intermediateAncillaryData,
            "recipient",
            _relayData.recipient
        );
        intermediateAncillaryData = AncillaryData.appendKeyValueAddress(
            intermediateAncillaryData,
            "l2Sender",
            _relayData.l2Sender
        );
        intermediateAncillaryData = AncillaryData.appendKeyValueAddress(
            intermediateAncillaryData,
            "l1Token",
            _relayData.l1Token
        );
        intermediateAncillaryData = AncillaryData.appendKeyValueUint(
            intermediateAncillaryData,
            "amount",
            _relayData.amount
        );
        intermediateAncillaryData = AncillaryData.appendKeyValueUint(
            intermediateAncillaryData,
            "realizedFee",
            _relayData.realizedFee
        );
        intermediateAncillaryData = AncillaryData.appendKeyValueUint(
            intermediateAncillaryData,
            "maxFee",
            _relayData.maxFee
        );

        // Add parameterized data:
        intermediateAncillaryData = AncillaryData.appendKeyValueAddress(intermediateAncillaryData, "relayer", relayer);

        // Add global state data stored by this contract:
        intermediateAncillaryData = AncillaryData.appendKeyValueAddress(
            intermediateAncillaryData,
            "depositContract",
            depositContract
        );

        return intermediateAncillaryData;
    }
}
