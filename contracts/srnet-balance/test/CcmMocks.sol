// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @notice USDC with a blacklist: transfers to a blocked address revert (like real USDC).
contract BlacklistUSDC {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!blocked[to] && !blocked[msg.sender], "blacklisted");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(!blocked[to] && !blocked[from], "blacklisted");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Token whose transfer can be switched to revert, return false, or burn all gas.
contract NastyToken {
    uint8 public mode; // 0 ok, 1 revert, 2 return false, 3 burn gas, 4 return huge data
    mapping(address => uint256) public balanceOf;

    function setMode(uint8 m) external {
        mode = m;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (mode == 1) revert("nope");
        if (mode == 2) return false;
        if (mode == 3) {
            while (true) {}
        }
        if (mode == 4) {
            assembly {
                return(0, 100000)
            }
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice ETH receiver that rejects, burns gas, or tries to re-enter the balance contract.
contract EthSink {
    uint8 public mode; // 0 accept, 1 reject, 2 burn gas, 3 re-enter `target` with `payload`
    address public target;
    bytes public payload;
    bool public reentryOk;

    function setMode(uint8 m, address t, bytes calldata p) external {
        mode = m;
        target = t;
        payload = p;
    }

    receive() external payable {
        if (mode == 1) revert("no eth");
        if (mode == 2) {
            while (true) {}
        }
        if (mode == 3) {
            (bool ok,) = target.call(payload);
            reentryOk = ok;
            if (!ok) revert("reentry blocked");
        }
    }
}
