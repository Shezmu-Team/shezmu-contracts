// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';

contract ShezUSDStabilityPool is
    ERC20Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    event Deposit(address user, uint256 amount, uint256 share);
    event Withdraw(address user, uint256 amount, uint256 share);
    event BorrowForLiquidation(address indexed liquidator, uint256 amount);
    event RepayFromLiquidation(
        address indexed liquidator,
        uint256 borrowed,
        uint256 repaid
    );
    event RescueToken(
        address indexed owner,
        address indexed token,
        uint256 amount
    );

    bytes32 private constant LIQUIDATOR_ROLE = keccak256('LIQUIDATOR_ROLE');

    IERC20Upgradeable public shezUSD;
    uint256 public totalAssets;
    uint256 public totalDebt;
    mapping(address => uint256) public debtOf;

    function initialize(address _shezUSD) external initializer {
        __ERC20_init('ShezmuUSD Stability Pool', 'sShezUSD');
        __AccessControl_init();
        __ReentrancyGuard_init();

        shezUSD = IERC20Upgradeable(_shezUSD);
    }

    function amountToShare(uint256 amount) public view returns (uint256 share) {
        if (totalAssets == 0) return amount;

        share = (amount * totalSupply()) / totalAssets;
    }

    function shareToAmount(uint256 share) public view returns (uint256 amount) {
        if (totalSupply() == 0) return share;

        amount = (share * totalAssets) / totalSupply();
    }

    function deposit(uint256 amount) external nonReentrant {
        uint256 share = amountToShare(amount);

        shezUSD.safeTransferFrom(msg.sender, address(this), amount);
        totalAssets += amount;

        _mint(msg.sender, share);

        emit Deposit(msg.sender, amount, share);
    }

    function withdraw(uint256 share) external nonReentrant {
        uint256 amount = shareToAmount(share);

        require(
            shezUSD.balanceOf(address(this)) >= amount,
            'wait for the liquidation repayment'
        );

        _burn(msg.sender, share);

        totalAssets -= amount;
        shezUSD.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, share);
    }

    function borrowForLiquidation(uint256 amount) external {
        _checkRole(LIQUIDATOR_ROLE, msg.sender);

        debtOf[msg.sender] += amount;
        totalDebt += amount;

        shezUSD.safeTransfer(msg.sender, amount);

        emit BorrowForLiquidation(msg.sender, amount);
    }

    function repayFromLiquidation(uint256 borrowed, uint256 repaid) external {
        _checkRole(LIQUIDATOR_ROLE, msg.sender);

        require(repaid >= borrowed, 'not enough repayment');

        shezUSD.safeTransferFrom(msg.sender, address(this), repaid);

        totalAssets += repaid - borrowed;
        totalDebt -= borrowed;
        debtOf[msg.sender] -= borrowed;

        emit RepayFromLiquidation(msg.sender, borrowed, repaid);
    }

    /// @notice withdraw tokens sent by accident
    function rescueToken(address token) external {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);

        uint256 amount = IERC20Upgradeable(token).balanceOf(address(this));
        if (token == address(shezUSD)) {
            amount -= totalAssets;
        }

        IERC20Upgradeable(token).safeTransfer(msg.sender, amount);

        emit RescueToken(msg.sender, token, amount);
    }
}