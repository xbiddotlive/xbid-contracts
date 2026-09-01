// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFeeVault} from "../../src/interfaces/IFeeVault.sol";

contract MockFeeVault is IFeeVault {
    error CreditRejected();
    error ReentryUnexpectedlySucceeded();

    uint32 public constant SPLIT_VERSION = 1;

    bool public rejectCredit;
    bool public reenter;
    bytes public reentryCalldata;
    uint256 public totalCredited;
    mapping(address beneficiary => uint256 units) public creditOf;

    function setRejectCredit(bool value) external {
        rejectCredit = value;
    }

    function setReentry(bool value, bytes calldata callData) external {
        reenter = value;
        reentryCalldata = callData;
    }

    function creditFee(bytes32, address creator, address referrer, uint256 feeUnits)
        external
        returns (uint256 protocolUnits, uint256 creatorUnits, uint256 referrerUnits, uint32 feeSplitVersion)
    {
        if (rejectCredit) revert CreditRejected();
        if (reenter) {
            (bool success, bytes memory data) = msg.sender.call(reentryCalldata);
            if (success) revert ReentryUnexpectedlySucceeded();
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }

        creatorUnits = feeUnits * 2_000 / 10_000;
        if (referrer == address(0)) {
            protocolUnits = feeUnits - creatorUnits;
        } else {
            referrerUnits = feeUnits * 1_000 / 10_000;
            protocolUnits = feeUnits - creatorUnits - referrerUnits;
            creditOf[referrer] += referrerUnits;
        }
        creditOf[creator] += creatorUnits;
        creditOf[address(this)] += protocolUnits;
        totalCredited += feeUnits;
        feeSplitVersion = SPLIT_VERSION;
    }
}
