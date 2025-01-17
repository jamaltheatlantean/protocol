pragma solidity 0.8.16;

import "./BaseEscalationManager.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../../interfaces/OptimisticAsserterInterface.sol";

// This EscalationManager allows to arbitrate for each assertion based on its bond via the DVM or the EscalationManager.
// If the bond is greater than the superbond, it is arbitrated automatically through the EscalationManager; otherwise,
// it is arbitrated through the DVM.
contract SuperbondEscalationManager is BaseEscalationManager, Ownable {
    uint256 public superbond;
    address public superbondCurrency;

    function setSuperbond(uint256 newSuperbond) public onlyOwner {
        superbond = newSuperbond;
    }

    function setSuperbondCurrency(address newSuperbondCurrency) public onlyOwner {
        superbondCurrency = newSuperbondCurrency;
    }

    function getAssertionPolicy(bytes32 assertionId) public view override returns (AssertionPolicy memory) {
        OptimisticAsserterInterface optimisticAsserter = OptimisticAsserterInterface(msg.sender);
        OptimisticAsserterInterface.Assertion memory assertion = optimisticAsserter.getAssertion(assertionId);
        bool isSuperbondCurrency = address(assertion.currency) == superbondCurrency;
        return
            AssertionPolicy({
                blockAssertion: false,
                arbitrateViaEscalationManager: isSuperbondCurrency ? assertion.bond > superbond : false,
                discardOracle: false,
                validateDisputers: false
            });
    }
}
