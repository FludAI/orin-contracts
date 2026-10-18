// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentVestingPool — founder/cohort agent vesting with forfeit-to-pool
 *
 * @notice Holds the founder allocation set at deployment and releases it to
 *   agents on individual vesting schedules. Each schedule has a cliff and then
 *   vests linearly; a recipient claims whatever has vested and not yet been
 *   claimed. If a schedule is revoked, the unvested remainder returns to the
 *   pool's grantable balance rather than being burned, so it can be allocated
 *   to another agent later.
 *
 * @dev Funding: grantable capacity is registered only by depositNews(), which
 *   pulls an approved balance and credits `availableForGrant`. A direct
 *   transfer into this contract raises its balance without creating capacity,
 *   and no function converts one into the other. Always fund with
 *   depositNews().
 *
 * @dev The immutable token getter is named `wnews` for continuity with earlier
 *   deployments of this contract. It returns whichever ERC-20 this pool was
 *   constructed with — for ORIN, the ORIN token.
 *
 * @dev Authorities:
 *   - owner: creates schedules and may revoke them
 *   - reputationFactory (optional): may also call revoke(), so revocation can
 *     be driven by an external reputation contract rather than only by the owner
 *
 * @dev Vesting: linear from startedAt to vestEnd, with nothing claimable
 *   before cliffEnd. Every parameter is per-schedule; the contract imposes no
 *   standard term.
 *
 * @dev Revocation splits the schedule. The unvested portion returns to
 *   availableForGrant. Whatever had already vested stays claimable by the
 *   recipient, whether or not they had claimed it yet.
 */
contract AgentVestingPool is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable wnews;

    /// @notice Optional: address allowed to revoke (e.g. ReputationFactory).
    address public reputationFactory;

    struct Schedule {
        uint256 totalNews;       // total NEWS in this schedule
        address recipient;       // address that can claim
        uint64 startedAt;        // schedule clock start (typically agent registration)
        uint64 cliffEnd;         // no claims before this timestamp
        uint64 vestEnd;          // 100% vested at/after this timestamp
        uint256 claimed;         // running total of NEWS claimed by recipient
        bool revoked;            // true once revoked; freezes vesting at that point
        uint256 vestedAtRevoke;  // amount vested at revocation; stays claimable
    }

    /// @notice agentPeerId → Schedule (peerId is opaque; could be address or hash).
    mapping(bytes32 => Schedule) public schedules;

    /// @notice Tokens available for new grants (depositTotal − totalGranted + totalRevokedReturned).
    uint256 public availableForGrant;

    /// @notice Aggregate stats (events also fire for indexing).
    uint256 public totalDeposited;
    uint256 public totalGranted;
    uint256 public totalClaimed;
    uint256 public totalRevokedReturned;

    event Deposited(address indexed from, uint256 amount, uint256 newAvailable);
    event ScheduleCreated(
        bytes32 indexed agentId,
        address indexed recipient,
        uint256 totalNews,
        uint64 cliffEnd,
        uint64 vestEnd
    );
    event Claimed(bytes32 indexed agentId, address indexed recipient, uint256 amount);
    event Revoked(bytes32 indexed agentId, uint256 unvestedReturned, address indexed by);
    event ReputationFactoryUpdated(address indexed oldAddr, address indexed newAddr);

    error ZeroAddress();
    error InsufficientPool();
    error NotAuthorized();
    error ScheduleExists();
    error ScheduleNotFound();
    error InvalidVesting();
    error AlreadyRevoked();
    error NothingToClaim();
    error NotRecipient();

    constructor(address initialOwner, address _wnews) Ownable(initialOwner) {
        if (_wnews == address(0)) revert ZeroAddress();
        wnews = IERC20(_wnews);
    }

    // ============ Admin =====================================================

    function setReputationFactory(address _factory) external onlyOwner {
        address old = reputationFactory;
        reputationFactory = _factory;
        emit ReputationFactoryUpdated(old, _factory);
    }

    /// @notice Deposit tokens into the pool. Typically called at deploy with the
    ///         100M founder allocation. Caller must approve first.
    function depositNews(uint256 amount) external onlyOwner {
        wnews.safeTransferFrom(msg.sender, address(this), amount);
        availableForGrant += amount;
        totalDeposited += amount;
        emit Deposited(msg.sender, amount, availableForGrant);
    }

    // ============ Grants ====================================================

    /// @notice Create a vesting schedule for an agent. Pulls from availableForGrant.
    /// @param agentId opaque per-agent identifier (e.g. peerId hash)
    /// @param recipient address that can claim the vested tokens
    /// @param totalNews total tokens allocated to this schedule
    /// @param cliffSeconds delay from now until cliff (e.g. 6 months)
    /// @param vestSeconds total vest duration from now (e.g. 24 months) — must exceed cliffSeconds
    function grantToAgent(
        bytes32 agentId,
        address recipient,
        uint256 totalNews,
        uint64 cliffSeconds,
        uint64 vestSeconds
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (totalNews == 0) revert InvalidVesting();
        if (vestSeconds <= cliffSeconds) revert InvalidVesting();
        if (totalNews > availableForGrant) revert InsufficientPool();
        if (schedules[agentId].totalNews != 0) revert ScheduleExists();

        uint64 nowTs = uint64(block.timestamp);
        schedules[agentId] = Schedule({
            totalNews: totalNews,
            recipient: recipient,
            startedAt: nowTs,
            cliffEnd: nowTs + cliffSeconds,
            vestEnd: nowTs + vestSeconds,
            claimed: 0,
            revoked: false,
            vestedAtRevoke: 0
        });
        availableForGrant -= totalNews;
        totalGranted += totalNews;
        emit ScheduleCreated(agentId, recipient, totalNews, nowTs + cliffSeconds, nowTs + vestSeconds);
    }

    // ============ Claims ====================================================

    /// @notice Vested amount for an agent at the current block.
    function vestedAmount(bytes32 agentId) public view returns (uint256) {
        Schedule storage s = schedules[agentId];
        if (s.totalNews == 0) return 0;
        if (s.revoked) {
            // Frozen at the amount vested at the moment of revocation, so a
            // recipient keeps what they had already earned but not yet claimed.
            // Returning s.claimed here instead would leave that difference
            // owed to nobody: unclaimable by the recipient and never returned
            // to availableForGrant.
            return s.vestedAtRevoke;
        }
        if (block.timestamp < s.cliffEnd) return 0;
        if (block.timestamp >= s.vestEnd) return s.totalNews;
        // Linear from startedAt to vestEnd.
        uint256 elapsed = block.timestamp - s.startedAt;
        uint256 duration = s.vestEnd - s.startedAt;
        return (s.totalNews * elapsed) / duration;
    }

    /// @notice Claimable tokens for an agent right now (vested minus already claimed).
    function claimableAmount(bytes32 agentId) external view returns (uint256) {
        uint256 vested = vestedAmount(agentId);
        Schedule storage s = schedules[agentId];
        return vested > s.claimed ? vested - s.claimed : 0;
    }

    /// @notice Recipient claims whatever is currently claimable.
    function claim(bytes32 agentId) external returns (uint256 claimable) {
        Schedule storage s = schedules[agentId];
        if (s.totalNews == 0) revert ScheduleNotFound();
        if (msg.sender != s.recipient) revert NotRecipient();

        uint256 vested = vestedAmount(agentId);
        if (vested <= s.claimed) revert NothingToClaim();
        claimable = vested - s.claimed;
        s.claimed += claimable;
        totalClaimed += claimable;
        wnews.safeTransfer(s.recipient, claimable);
        emit Claimed(agentId, s.recipient, claimable);
    }

    // ============ Revocation (forfeit-to-pool) ==============================

    /// @notice Revoke an agent's schedule. The unvested remainder returns to
    ///         availableForGrant. Tokens that had already vested stay
    ///         claimable by recipient (they earned it).
    /// @dev Callable by owner OR by reputationFactory if set.
    function revoke(bytes32 agentId) external returns (uint256 returned) {
        if (msg.sender != owner() && msg.sender != reputationFactory) revert NotAuthorized();

        Schedule storage s = schedules[agentId];
        if (s.totalNews == 0) revert ScheduleNotFound();
        if (s.revoked) revert AlreadyRevoked();

        uint256 vested = vestedAmount(agentId);
        // Unvested = total minus vested. (Vested-but-unclaimed remains owed to recipient.)
        returned = s.totalNews - vested;
        s.vestedAtRevoke = vested;
        s.revoked = true;

        // Adjust accounting
        availableForGrant += returned;
        totalRevokedReturned += returned;
        // Reduce totalGranted by the returned amount so accounting reflects
        // current outstanding grants (vested + still-vesting on non-revoked).
        totalGranted -= returned;

        emit Revoked(agentId, returned, msg.sender);
    }
}
