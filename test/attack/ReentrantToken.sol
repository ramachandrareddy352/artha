// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// An ERC-777-shaped base asset: every transfer gives a registered hook the chance to
/// call back into the vault before the balance change settles.
contract ReentrantToken is ERC20 {
    uint8 private immutable _decimals;

    address public hook;
    bool public hookEnabled;
    bool private _inHook;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address _hook) external {
        hook = _hook;
    }

    function setHookEnabled(bool on) external {
        hookEnabled = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (hookEnabled && hook != address(0) && !_inHook) {
            _inHook = true;
            IReentrancyHook(hook).onTokenMoved();
            _inHook = false;
        }
    }
}

interface IReentrancyHook {
    function onTokenMoved() external;
}

/// Attempts to re-enter one chosen vault entry point from inside a token transfer.
contract ReentrancyAttacker is IReentrancyHook {
    enum Target {
        None,
        Deposit,
        Withdraw,
        Redeem,
        EmergencyWithdraw,
        Sync,
        Settle
    }

    address public immutable vault;
    address public immutable token;
    Target public target;
    bool public attempted;
    bool public succeeded;

    constructor(address _vault, address _token) {
        vault = _vault;
        token = _token;
    }

    function setTarget(Target t) external {
        target = t;
        attempted = false;
        succeeded = false;
    }

    function onTokenMoved() external override {
        if (target == Target.None) return;
        attempted = true;

        bytes memory data;
        if (target == Target.Deposit) {
            data = abi.encodeWithSignature("deposit(uint256,address,uint256)", uint256(1e6), address(this), uint256(0));
        } else if (target == Target.Withdraw) {
            data = abi.encodeWithSignature(
                "withdraw(uint256,address,address,uint256)",
                uint256(1e6),
                address(this),
                address(this),
                type(uint256).max
            );
        } else if (target == Target.Redeem) {
            data = abi.encodeWithSignature(
                "redeem(uint256,address,address,uint256)", uint256(1e6), address(this), address(this), uint256(0)
            );
        } else if (target == Target.EmergencyWithdraw) {
            data = abi.encodeWithSignature(
                "emergencyWithdraw(uint256,address,address)", uint256(1e6), address(this), address(this)
            );
        } else if (target == Target.Sync) {
            data = abi.encodeWithSignature("sync()");
        } else {
            data = abi.encodeWithSignature("settle()");
        }

        (bool ok,) = vault.call(data);
        succeeded = ok;
    }
}
