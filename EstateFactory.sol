// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Estate.sol";

/// @title EstateFactory
/// @notice Deploys Estate vaults and keeps a registry so a dashboard can list every estate
///         a given address owns, or is a beneficiary of, without scanning the chain.
///         This contract is permissionless and unowned: it holds no funds, has no admin
///         controls over any Estate, and never touches an estate's balance. It exists purely
///         to deploy estates and index them by owner/beneficiary.
contract EstateFactory {
    struct EstateInfo {
        address estateAddress;
        address owner;
        string name;
        address token;
        uint256 createdAt;
    }

    mapping(address => EstateInfo) public estateInfo; // estate address => info
    mapping(address => bool) public isEstate;
    address[] public allEstates;

    mapping(address => address[]) internal estatesByOwner;
    mapping(address => address[]) internal estatesByBeneficiary;

    event EstateCreated(address indexed estateAddress, address indexed owner, string name, address token);
    event BeneficiariesSynced(address indexed estateAddress);

    error NotAnEstate();

    /// @notice Deploy a new Estate owned by the caller.
    function createEstate(
        string calldata estateName,
        address token,
        address[] calldata initialBeneficiaries,
        uint16[] calldata initialBps,
        uint256 inactivityPeriod
    ) external payable returns (address estateAddress) {
        Estate estate = new Estate{value: msg.value}(
            msg.sender,
            estateName,
            token,
            initialBeneficiaries,
            initialBps,
            inactivityPeriod,
            address(this)
        );
        estateAddress = address(estate);

        estateInfo[estateAddress] = EstateInfo({
            estateAddress: estateAddress,
            owner: msg.sender,
            name: estateName,
            token: token,
            createdAt: block.timestamp
        });
        isEstate[estateAddress] = true;
        allEstates.push(estateAddress);
        estatesByOwner[msg.sender].push(estateAddress);

        for (uint256 i = 0; i < initialBeneficiaries.length; i++) {
            estatesByBeneficiary[initialBeneficiaries[i]].push(estateAddress);
        }

        emit EstateCreated(estateAddress, msg.sender, estateName, token);
    }

    /// @notice Called by an Estate when its beneficiary list changes, to keep the registry in sync.
    function syncBeneficiaries(address[] calldata oldAddrs, address[] calldata newAddrs) external {
        if (!isEstate[msg.sender]) revert NotAnEstate();

        for (uint256 i = 0; i < oldAddrs.length; i++) {
            _removeEstateFromBeneficiary(oldAddrs[i], msg.sender);
        }
        for (uint256 i = 0; i < newAddrs.length; i++) {
            address[] storage list = estatesByBeneficiary[newAddrs[i]];
            bool already;
            for (uint256 j = 0; j < list.length; j++) {
                if (list[j] == msg.sender) {
                    already = true;
                    break;
                }
            }
            if (!already) list.push(msg.sender);
        }

        emit BeneficiariesSynced(msg.sender);
    }

    function _removeEstateFromBeneficiary(address beneficiary, address estateAddress) internal {
        address[] storage list = estatesByBeneficiary[beneficiary];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == estateAddress) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
    }

    // ------------------------------- Views -------------------------------

    function getEstatesByOwner(address ownerAddr) external view returns (address[] memory) {
        return estatesByOwner[ownerAddr];
    }

    function getEstatesByBeneficiary(address beneficiaryAddr) external view returns (address[] memory) {
        return estatesByBeneficiary[beneficiaryAddr];
    }

    function getAllEstatesCount() external view returns (uint256) {
        return allEstates.length;
    }

    function getAllEstates() external view returns (address[] memory) {
        return allEstates;
    }
}
