// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "libraries/BoringMath.sol";
import "BoringSolidity/BoringBatchable.sol";
import "BoringSolidity/BoringOwnable.sol";
import "BoringSolidity/libraries/BoringERC20.sol";
import "libraries/SignedSafeMath.sol";
import "interfaces/IRewarder.sol";
import "interfaces/IMasterChef.sol";

/// @notice The (older) MasterChef contract gives out a constant number of SUSHI tokens per block.
/// It is the only address with minting rights for SUSHI.
/// The idea for this MasterChef V2 (MCV2) contract is therefore to be the owner of a dummy token
/// that is deposited into the MasterChef V1 (MCV1) contract.
/// The allocation point for this pool on MCV1 is the total allocation point for all pools that receive double incentives.
contract MiniChefV2 is BoringOwnable, BoringBatchable {
    using BoringMath for uint256;
    using BoringMath128 for uint128;
    using BoringERC20 for IERC20;
    using SignedSafeMath for int256;

    /// @notice Info of each MCV2 user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of SUSHI entitled to the user.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
    }

    /// @notice Info of each MCV2 pool.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of SUSHI to distribute per block.
    struct PoolInfo {
        uint128 accSushiPerShare;
        uint64 lastRewardTime;
        uint64 allocPoint;
        uint16 depositFeeBP;
    }

    /// @notice Address of SUSHI contract.
    IERC20 public immutable SUSHI;

    /// @notice Info of each MCV2 pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each MCV2 pool.
    IERC20[] public lpToken;
    /// @notice Address of each `IRewarder` contract in MCV2.
    IRewarder[] public rewarder;

    /// @notice Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    /// @dev Tokens added
    mapping(address => bool) public addedTokens;

    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 public sushiPerSecond;
    uint256 private constant ACC_SUSHI_PRECISION = 1e12;

    // Deposit Fee address
    address public feeAddress;
    /// @notice Maximum deposit fee rate: 2%
    uint16 public constant MAXIMUM_DEPOSIT_FEE_RATE = 200;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(uint256 indexed pid, uint256 allocPoint, IERC20 indexed lpToken, IRewarder indexed rewarder, uint16 depositFeeBP);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint, IRewarder indexed rewarder, bool overwrite, uint16 depositFeeBP);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardTime, uint256 lpSupply, uint256 accSushiPerShare);
    event LogSushiPerSecond(uint256 sushiPerSecond);
    event SetFeeAddress(address indexed user, address indexed newAddress);

    /// @param _sushi The SUSHI token contract address.
    constructor(IERC20 _sushi, address _feeAddress) {
        SUSHI = _sushi;
        feeAddress = _feeAddress;
    }

    /// @notice Returns the number of MCV2 pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _lpToken Address of the LP ERC-20 token.
    /// @param _rewarder Address of the rewarder delegate.
    function add(uint256 allocPoint, IERC20 _lpToken, IRewarder _rewarder, uint16 _depositFeeBP) public onlyOwner {
        require(addedTokens[address(_lpToken)] == false, "Token already added");
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_RATE, "add: invalid deposit fee basis points");
        totalAllocPoint = totalAllocPoint.add(allocPoint);
        lpToken.push(_lpToken);
        rewarder.push(_rewarder);

        poolInfo.push(PoolInfo({allocPoint: allocPoint.to64(), lastRewardTime: block.timestamp.to64(), accSushiPerShare: 0, depositFeeBP : _depositFeeBP}));
        addedTokens[address(_lpToken)] = true;
        emit LogPoolAddition(lpToken.length.sub(1), allocPoint, _lpToken, _rewarder, _depositFeeBP);
    }

    /// @notice Update the given pool's SUSHI allocation point and `IRewarder` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param overwrite True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
    function set(uint256 _pid, uint256 _allocPoint, IRewarder _rewarder, bool overwrite, uint16 _depositFeeBP) public onlyOwner {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE_RATE, "set: deposit fee too high");
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint.to64();
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        if (overwrite) {
            rewarder[_pid] = _rewarder;
        }
        emit LogSetPool(_pid, _allocPoint, overwrite ? _rewarder : rewarder[_pid], overwrite, _depositFeeBP);
    }

    /// @notice Sets the sushi per second to be distributed. Can only be called by the owner.
    /// @param _sushiPerSecond The amount of Sushi to be distributed per second.
    function setSushiPerSecond(uint256 _sushiPerSecond) public onlyOwner {
        sushiPerSecond = _sushiPerSecond;
        emit LogSushiPerSecond(_sushiPerSecond);
    }

    /// @notice View function to see pending SUSHI on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending SUSHI reward for a given user.
    function pendingSushi(uint256 _pid, address _user) external view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSushiPerShare = pool.accSushiPerShare;
        uint256 lpSupply = lpToken[_pid].balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 time = block.timestamp.sub(pool.lastRewardTime);
            uint256 sushiReward = time.mul(sushiPerSecond).mul(pool.allocPoint) / totalAllocPoint;
            accSushiPerShare = accSushiPerShare.add(sushiReward.mul(ACC_SUSHI_PRECISION) / lpSupply);
        }
        pending = int256(user.amount.mul(accSushiPerShare) / ACC_SUSHI_PRECISION).sub(user.rewardDebt).toUInt256();
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (block.timestamp > pool.lastRewardTime) {
            uint256 lpSupply = lpToken[pid].balanceOf(address(this));
            if (lpSupply > 0) {
                uint256 time = block.timestamp.sub(pool.lastRewardTime);
                uint256 sushiReward = time.mul(sushiPerSecond).mul(pool.allocPoint) / totalAllocPoint;
                pool.accSushiPerShare = pool.accSushiPerShare.add((sushiReward.mul(ACC_SUSHI_PRECISION) / lpSupply).to128());
            }
            pool.lastRewardTime = block.timestamp.to64();
            poolInfo[pid] = pool;
            emit LogUpdatePool(pid, pool.lastRewardTime, lpSupply, pool.accSushiPerShare);
        }
    }

    /// @notice Deposit LP tokens to MCV2 for SUSHI allocation.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function deposit(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][to];

        lpToken[pid].safeTransferFrom(msg.sender, address(this), amount);

        uint256 amountAfterFee = amount;
        if (pool.depositFeeBP > 0) {
            uint256 depositFee = amount.mul(pool.depositFeeBP) / 10000;
            lpToken[pid].safeTransfer(feeAddress, depositFee);
            amountAfterFee = amountAfterFee.sub(depositFee);
        }

        // Effects
        user.amount = user.amount.add(amountAfterFee);
        user.rewardDebt = user.rewardDebt.add(int256(amountAfterFee.mul(pool.accSushiPerShare) / ACC_SUSHI_PRECISION));

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSushiReward(pid, to, to, 0, user.amount);
        }

        emit Deposit(msg.sender, pid, amount, to);
    }

    /// @notice Withdraw LP tokens from MCV2.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens.
    function withdraw(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];

        // Effects
        user.rewardDebt = user.rewardDebt.sub(int256(amount.mul(pool.accSushiPerShare) / ACC_SUSHI_PRECISION));
        user.amount = user.amount.sub(amount);

        // Interactions
        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSushiReward(pid, msg.sender, to, 0, user.amount);
        }

        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of SUSHI rewards.
    function harvest(uint256 pid, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedSushi = int256(user.amount.mul(pool.accSushiPerShare) / ACC_SUSHI_PRECISION);
        uint256 _pendingSushi = accumulatedSushi.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedSushi;

        // Interactions
        if (_pendingSushi != 0) {
            SUSHI.safeTransfer(to, _pendingSushi);
        }

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSushiReward(pid, msg.sender, to, _pendingSushi, user.amount);
        }

        emit Harvest(msg.sender, pid, _pendingSushi);
    }

    /// @notice Withdraw LP tokens from MCV2 and harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens and SUSHI rewards.
    function withdrawAndHarvest(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedSushi = int256(user.amount.mul(pool.accSushiPerShare) / ACC_SUSHI_PRECISION);
        uint256 _pendingSushi = accumulatedSushi.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedSushi.sub(int256(amount.mul(pool.accSushiPerShare) / ACC_SUSHI_PRECISION));
        user.amount = user.amount.sub(amount);

        // Interactions
        SUSHI.safeTransfer(to, _pendingSushi);

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSushiReward(pid, msg.sender, to, _pendingSushi, user.amount);
        }

        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
        emit Harvest(msg.sender, pid, _pendingSushi);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 pid, address to) public {
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onSushiReward(pid, msg.sender, to, 0, 0);
        }

        // Note: transfer can fail or succeed if `amount` is zero.
        lpToken[pid].safeTransfer(to, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, to);
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }
}
