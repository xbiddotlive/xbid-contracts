// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IFeeVault {
    function creditFee(bytes32 contestId, address creator, address referrer, uint256 feeUnits)
        external
        returns (uint256 protocolUnits, uint256 creatorUnits, uint256 referrerUnits, uint32 feeSplitVersion);
}
