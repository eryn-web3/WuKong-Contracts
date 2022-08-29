// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./SafeMath.sol";
import "./IBEP20.sol";
import "./SafeBEP20.sol";
import "./Ownable.sol";
import "./IWukongReferral.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./WUKONGToken.sol";

// MasterChef is the master of Wukong. He can make Wukong and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once WUKONG is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        uint256 rewardLockedUp;  // Reward locked up.
        //
        // We do some fancy math here. Basically, any point in time, the amount of WUKONGs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accWukongPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accWukongPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. WUKONGs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that WUKONGs distribution occurs.
        uint256 accWukongPerShare;   // Accumulated WUKONGs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The WUKONG TOKEN!
    MonkeyKing public wukong;
    // Team address.
    address public teamAddr;
    // Deposit Fee address
    address public feeAddress;
    // WUKONG tokens created per block.
    uint256 public wukongPerBlock;
    // Bonus muliplier for early wukong makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Max harvest interval: 14 days.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when WUKONG mining starts.
    uint256 public startBlock;
    // Deposited amount WUKONG in MasterChef
    uint256 public depositedWukong;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // Wukong referral contract address.
    IWukongReferral public wukongReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 100;
    // Max referral commission rate: 10%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;

    uint256 public weekLockStartTime = 1631052001;
    uint256 public constant WEEK_DURATION = 7 days;
    uint256 public constant DAY_DURATION = 1 days;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);

    constructor(
        MonkeyKing _wukong,
        address _teamAddr,
        address _feeAddress,
        uint256 _wukongPerBlock,
        uint256 _startBlock
    ) public {
        wukong = _wukong;
        teamAddr = _teamAddr;
        feeAddress = _feeAddress;
        wukongPerBlock = _wukongPerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accWukongPerShare: 0,
            depositFeeBP: _depositFeeBP
        }));
    }

    // Update the given pool's WUKONG allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending WUKONGs on frontend.
    function pendingWukong(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accWukongPerShare = pool.accWukongPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (_pid == 0){
            lpSupply = depositedWukong;
        }
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 wukongReward = multiplier.mul(wukongPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accWukongPerShare = accWukongPerShare.add(wukongReward.mul(1e12).div(lpSupply));
        }
        uint256 pending = user.amount.mul(accWukongPerShare).div(1e12).sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest WUKONGs.
    function canHarvest() public view returns (bool) {
        if (block.timestamp < weekLockStartTime) 
            return false;

        uint256 weeksSec = block.timestamp.sub(weekLockStartTime).div(WEEK_DURATION).mul(WEEK_DURATION);
        return block.timestamp.sub(weekLockStartTime).sub(weeksSec) < DAY_DURATION;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));        
        if (_pid == 0){
            lpSupply = depositedWukong;
        }
        if (lpSupply <= 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 wukongReward = multiplier.mul(wukongPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        wukong.mint(teamAddr, wukongReward.div(10));
        wukong.mint(address(this), wukongReward);
        pool.accWukongPerShare = pool.accWukongPerShare.add(wukongReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for WUKONG allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) public nonReentrant {
        require (_pid != 0, 'deposit WUKONG by staking');

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (_amount > 0 && address(wukongReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            wukongReferral.recordReferral(msg.sender, _referrer);
        }
        payOrLockupPendingWukong(_pid);
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (address(pool.lpToken) == address(wukong)) {
                uint256 transferTax = _amount.mul(wukong.transferTaxRate()).div(10000);
                _amount = _amount.sub(transferTax);
            }
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            }else{
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accWukongPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        require (_pid != 0, 'withdraw WUKONG by unstaking');

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        payOrLockupPendingWukong(_pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accWukongPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Deposit LP tokens to MasterChef for WUKONG allocation.
    function enterStaking(uint256 _amount, address _referrer) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (_amount > 0 && address(wukongReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            wukongReferral.recordReferral(msg.sender, _referrer);
        }
        payOrLockupPendingWukong(0);
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (address(pool.lpToken) == address(wukong)) {
                uint256 transferTax = _amount.mul(wukong.transferTaxRate()).div(10000);
                _amount = _amount.sub(transferTax);
            }
            user.amount = user.amount.add(_amount);
            depositedWukong = depositedWukong.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accWukongPerShare).div(1e12);
        emit Deposit(msg.sender, 0, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function leaveStaking(uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(0);
        payOrLockupPendingWukong(0);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            depositedWukong = depositedWukong.sub(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accWukongPerShare).div(1e12);
        emit Withdraw(msg.sender, 0, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
    }

    function _weekHarvestTimeFromNow() private view returns (uint256) {
        if (block.timestamp <= weekLockStartTime) 
            return weekLockStartTime;

        uint256 weeks1 = block.timestamp.sub(weekLockStartTime).div(WEEK_DURATION).add(1);
        return weeks1.mul(WEEK_DURATION).add(weekLockStartTime);
    }

    // Pay or lockup pending WUKONGs.
    function payOrLockupPendingWukong(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 pending = user.amount.mul(pool.accWukongPerShare).div(1e12).sub(user.rewardDebt);
        if (canHarvest()) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;

                // send rewards
                safeWukongTransfer(msg.sender, totalRewards);
                payReferralCommission(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }
    // Safe wukong transfer function, just in case if rounding error causes pool to not have enough WUKONGs.
    function safeWukongTransfer(address _to, uint256 _amount) internal {
        uint256 wukongBal = wukong.balanceOf(address(this));
        if (_amount > wukongBal) {
            wukong.transfer(_to, wukongBal);
        } else {
            wukong.transfer(_to, _amount);
        }
    }

    // Update team address by the previous team address.
    function setTeamAddress(address _teamAddress) public {
        require(msg.sender == teamAddr, "team: FORBIDDEN");
        require(_teamAddress != address(0), "team: ZERO");
        teamAddr = _teamAddress;
    }

    function setFeeAddress(address _feeAddress) public{
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        feeAddress = _feeAddress;
    }

    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _wukongPerBlock) public onlyOwner {
        massUpdatePools();
        emit EmissionRateUpdated(msg.sender, wukongPerBlock, _wukongPerBlock);
        wukongPerBlock = _wukongPerBlock;
    }

    // Update the wukong referral contract address by the owner
    function setWukongReferral(IWukongReferral _wukongReferral) public onlyOwner {
        wukongReferral = _wukongReferral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    function setStartBlock(uint256 _startBlock) public onlyOwner {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {            
            PoolInfo storage pool = poolInfo[pid];
            if (pool.lastRewardBlock <= _startBlock) {
                pool.lastRewardBlock = _startBlock;
            }
        }

        startBlock = _startBlock;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(wukongReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = wukongReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                wukong.mint(referrer, commissionAmount);
                wukongReferral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    // Update weekLockStartTime by the owner
    function setWeekLockStartTime(uint256 _weekLockStartTime) public onlyOwner {
        weekLockStartTime = _weekLockStartTime;
    }
}