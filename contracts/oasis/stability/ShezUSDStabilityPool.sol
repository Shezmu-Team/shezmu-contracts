// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';
import '../../utils/RateLib.sol';

contract ShezUSDStabilityPool is
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using RateLib for RateLib.Rate;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    event WithdrawRequest(address indexed user, uint256 assets);
    event BorrowForLiquidation(address indexed liquidator, uint256 assets);
    event RepayFromLiquidation(
        address indexed liquidator,
        uint256 borrowed,
        uint256 repaid
    );
    event RescueToken(
        address indexed owner,
        address indexed token,
        uint256 assets
    );

    bytes32 private constant LIQUIDATOR_ROLE = keccak256('LIQUIDATOR_ROLE');

    uint256 private _totalAssets;
    uint256 public totalDebt;
    mapping(address => uint256) public debtOf;

    RateLib.Rate public maxBorrowRate;

    function initialize(
        IERC20Upgradeable _shezUSD,
        RateLib.Rate calldata _maxBorrowRate
    ) external initializer {
        __ERC4626_init(_shezUSD);
        __AccessControl_init();
        __ReentrancyGuard_init();
        maxBorrowRate = _maxBorrowRate;
    }

    function setMaxBorrowRate(RateLib.Rate calldata _maxBorrowRate) external {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);

        maxBorrowRate = _maxBorrowRate;
    }

    function totalAssets() public view override returns (uint256) {
        return _totalAssets;
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        IERC20Upgradeable(asset()).safeTransferFrom(
            caller,
            address(this),
            assets
        );
        _totalAssets += assets;
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // If _asset is ERC777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(owner, shares);
        _totalAssets -= assets;
        IERC20Upgradeable(asset()).safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function borrowForLiquidation(uint256 amount) external nonReentrant {
        _checkRole(LIQUIDATOR_ROLE, msg.sender);

        require(
            maxBorrowRate.calculate(_totalAssets) >= totalDebt,
            'not enough to borrow'
        );

        debtOf[msg.sender] += amount;
        totalDebt += amount;

        IERC20Upgradeable(asset()).safeTransfer(msg.sender, amount);

        emit BorrowForLiquidation(msg.sender, amount);
    }

    function repayFromLiquidation(
        uint256 borrowed,
        uint256 repaid
    ) external nonReentrant {
        _checkRole(LIQUIDATOR_ROLE, msg.sender);

        require(repaid >= borrowed, 'not enough repayment');

        IERC20Upgradeable(asset()).safeTransferFrom(
            msg.sender,
            address(this),
            repaid
        );

        _totalAssets += repaid - borrowed;
        totalDebt -= borrowed;
        debtOf[msg.sender] -= borrowed;

        emit RepayFromLiquidation(msg.sender, borrowed, repaid);
    }

    /// @notice withdraw tokens sent by accident
    function rescueToken(address token) external nonReentrant {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);

        uint256 amount = IERC20Upgradeable(token).balanceOf(address(this));
        if (token == asset()) {
            amount -= _totalAssets;
        }

        IERC20Upgradeable(token).safeTransfer(msg.sender, amount);

        emit RescueToken(msg.sender, token, amount);
    }
}