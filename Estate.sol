// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IEstateFactory {
    function syncBeneficiaries(address[] calldata oldAddrs, address[] calldata newAddrs) external;
}

/// @title Estate
/// @notice A single "dead man switch" vault: owner deposits funds (native coin or one ERC-20
///         token), names beneficiaries with percentage shares, and must check in periodically.
///         If the owner goes inactive past `inactivityPeriod`, any beneficiary can claim.
///         Normally created via EstateFactory, which keeps a registry for dashboards; can also
///         be deployed standalone by passing factory = address(0).
contract Estate {
    address public owner;
    address public factory;
    string public name;
    address public token; // address(0) = native coin

    uint256 public inactivityPeriod; // seconds
    uint256 public lastCheckIn;
    bool public claimed;

    struct Beneficiary {
        address addr;
        uint16 bps; // basis points of total, sums to 10000
    }
    Beneficiary[] public beneficiaries;

    event Deposited(address indexed from, uint256 amount);
    event CheckedIn(uint256 timestamp);
    event BeneficiariesUpdated();
    event InactivityPeriodUpdated(uint256 newPeriod);
    event Claimed(uint256 totalAmount);
    event OwnerWithdrew(address indexed owner, uint256 amount);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    error NotOwner();
    error NotBeneficiary();
    error AlreadyClaimed();
    error StillActive();
    error ZeroAddress();
    error InvalidPeriod();
    error InvalidBeneficiaries();
    error InvalidShares();
    error TransferFailed();
    error NothingToWithdraw();
    error NativeNotAccepted();
    error WrongAssetMode();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier notClaimed() {
        if (claimed) revert AlreadyClaimed();
        _;
    }

    /// @param _owner the estate owner (explicit, since factory is the deployer/msg.sender)
    /// @param _name a human-readable label for dashboards, e.g. "Family Trust"
    /// @param _token address(0) for native coin, or an ERC-20 token address
    /// @param _beneficiaries list of beneficiary addresses
    /// @param _bps matching list of basis-point shares; must sum to 10000
    /// @param _inactivityPeriod seconds of owner inactivity before claim is allowed
    /// @param _factory the EstateFactory that deployed this, or address(0) for standalone
    constructor(
        address _owner,
        string memory _name,
        address _token,
        address[] memory _beneficiaries,
        uint16[] memory _bps,
        uint256 _inactivityPeriod,
        address _factory
    ) payable {
        if (_owner == address(0)) revert ZeroAddress();

        owner = _owner;
        name = _name;
        token = _token;
        factory = _factory;

        if (_inactivityPeriod == 0) revert InvalidPeriod();
        inactivityPeriod = _inactivityPeriod;
        lastCheckIn = block.timestamp;

        _setBeneficiaries(_beneficiaries, _bps);

        if (_token != address(0) && msg.value > 0) revert NativeNotAccepted();
        if (msg.value > 0) emit Deposited(_owner, msg.value);
    }

    // ----------------------------- Owner actions -----------------------------

    /// @notice Deposit funds. For native mode, send value with the call and pass amount=0 (ignored).
    ///         For ERC-20 mode, approve this contract first, then call with `amount`.
    function deposit(uint256 amount) external payable onlyOwner notClaimed {
        if (token == address(0)) {
            if (amount != 0) revert WrongAssetMode();
            emit Deposited(msg.sender, msg.value);
        } else {
            if (msg.value != 0) revert NativeNotAccepted();
            bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
            if (!ok) revert TransferFailed();
            emit Deposited(msg.sender, amount);
        }
        lastCheckIn = block.timestamp;
        emit CheckedIn(lastCheckIn);
    }

    /// @notice Reset the inactivity timer without depositing.
    function checkIn() external onlyOwner notClaimed {
        lastCheckIn = block.timestamp;
        emit CheckedIn(lastCheckIn);
    }

    /// @notice Replace the beneficiary list & shares. Shares (bps) must sum to 10000.
    ///         Notifies the factory (if any) so its registry stays in sync.
    function setBeneficiaries(address[] calldata addrs, uint16[] calldata bps)
        external
        onlyOwner
        notClaimed
    {
        address[] memory oldAddrs = _currentBeneficiaryAddrs();
        _setBeneficiaries(addrs, bps);
        if (factory != address(0)) {
            IEstateFactory(factory).syncBeneficiaries(oldAddrs, addrs);
        }
    }

    function _currentBeneficiaryAddrs() internal view returns (address[] memory addrs) {
        uint256 n = beneficiaries.length;
        addrs = new address[](n);
        for (uint256 i = 0; i < n; i++) addrs[i] = beneficiaries[i].addr;
    }

    function _setBeneficiaries(address[] memory addrs, uint16[] memory bps) internal {
        if (addrs.length == 0 || addrs.length != bps.length) revert InvalidBeneficiaries();

        delete beneficiaries;
        uint256 total;
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i] == address(0)) revert ZeroAddress();
            total += bps[i];
            beneficiaries.push(Beneficiary(addrs[i], bps[i]));
        }
        if (total != 10000) revert InvalidShares();
        emit BeneficiariesUpdated();
    }

    /// @notice Update how long the owner may go inactive before beneficiaries can claim.
    function setInactivityPeriod(uint256 _inactivityPeriod) external onlyOwner notClaimed {
        if (_inactivityPeriod == 0) revert InvalidPeriod();
        inactivityPeriod = _inactivityPeriod;
        emit InactivityPeriodUpdated(_inactivityPeriod);
    }

    /// @notice Transfer estate ownership (does NOT change beneficiaries).
    function transferOwnership(address newOwner) external onlyOwner notClaimed {
        if (newOwner == address(0)) revert ZeroAddress();
        address old = owner;
        owner = newOwner;
        lastCheckIn = block.timestamp;
        emit OwnershipTransferred(old, newOwner);
        emit CheckedIn(lastCheckIn);
    }

    /// @notice Owner can withdraw anytime while active (also proves liveness).
    function ownerWithdraw(uint256 amount) external onlyOwner notClaimed {
        if (amount == 0 || amount > _balance()) revert NothingToWithdraw();
        lastCheckIn = block.timestamp;
        _send(owner, amount);
        emit OwnerWithdrew(owner, amount);
        emit CheckedIn(lastCheckIn);
    }

    // -------------------------- Beneficiary actions --------------------------

    /// @notice Any listed beneficiary can call this once the inactivity period has elapsed.
    ///         Splits the full balance across all beneficiaries per their bps share.
    function claim() external notClaimed {
        bool isBeneficiary;
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            if (beneficiaries[i].addr == msg.sender) {
                isBeneficiary = true;
                break;
            }
        }
        if (!isBeneficiary) revert NotBeneficiary();
        if (block.timestamp < lastCheckIn + inactivityPeriod) revert StillActive();

        claimed = true;
        uint256 total = _balance();
        uint256 distributed;
        uint256 n = beneficiaries.length;

        for (uint256 i = 0; i < n; i++) {
            uint256 share;
            if (i == n - 1) {
                share = total - distributed; // remainder to last beneficiary, avoids rounding dust
            } else {
                share = (total * beneficiaries[i].bps) / 10000;
            }
            distributed += share;
            if (share > 0) _send(beneficiaries[i].addr, share);
        }

        emit Claimed(total);
    }

    // ------------------------------- Views -------------------------------

    function timeUntilClaimable() external view returns (uint256) {
        uint256 deadline = lastCheckIn + inactivityPeriod;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    function isClaimable() external view returns (bool) {
        return !claimed && block.timestamp >= lastCheckIn + inactivityPeriod;
    }

    function beneficiariesCount() external view returns (uint256) {
        return beneficiaries.length;
    }

    function getAllBeneficiaries() external view returns (address[] memory addrs, uint16[] memory bps) {
        uint256 n = beneficiaries.length;
        addrs = new address[](n);
        bps = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            addrs[i] = beneficiaries[i].addr;
            bps[i] = beneficiaries[i].bps;
        }
    }

    function balance() external view returns (uint256) {
        return _balance();
    }

    function _balance() internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            bool ok = IERC20(token).transfer(to, amount);
            if (!ok) revert TransferFailed();
        }
    }

    /// @notice Accept plain native transfers as deposits + check-in (native mode only).
    receive() external payable {
        if (token != address(0)) revert NativeNotAccepted();
        if (msg.sender == owner && !claimed) {
            lastCheckIn = block.timestamp;
            emit CheckedIn(lastCheckIn);
        }
        emit Deposited(msg.sender, msg.value);
    }
}
