// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.4;

import "./TokenTracker.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ONEWallet is TokenTracker {
    event InsufficientFund(uint256 amount, uint256 balance, address dest);
    event ExceedDailyLimit(uint256 amount, uint256 limit, uint256 current, address dest);
    event UnknownTransferError(address dest);
    event LastResortAddressNotSet();
    event PaymentReceived(uint256 amount, address from);
    event PaymentSent(uint256 amount, address dest);
    event AutoRecoveryTriggered(address from);
    event RecoveryFailure();

    /// In future versions, it is planned that we may allow the user to extend the wallet's life through a function call. When that is implemented, the following variables may no longer be immutable, with the exception of root which shall serve as an identifier of the wallet
    bytes32 immutable root; // Note: @ivan brought up a good point in reducing this to 16-bytes so hash of two consecutive nodes can be done in a single word (to save gas and reduce blockchain clutter). Let's not worry about that for now and re-evalaute this later.
    uint8 immutable height; // including the root. e.g. for a tree with 4 leaves, the height is 3.
    uint8 immutable interval; // otp interval in seconds, default is 30
    uint32 immutable t0; // starting time block (effectiveTime (in ms) / interval)
    uint32 immutable lifespan;  // in number of block (e.g. 1 block per [interval] seconds)
    uint8 immutable maxOperationsPerInterval; // number of transactions permitted per OTP interval. Each transaction shall have a unique nonce. The nonce is auto-incremented within each interval

    /// global mutable variables
    address payable lastResortAddress; // where money will be sent during a recovery process (or when the wallet is beyond its lifespan)
    uint256 dailyLimit; // uint128 is sufficient, but uint256 is more efficient since EVM works with 32-byte words.
    uint256 spentToday; // note: instead of tracking the money spent for the last 24h, we are simply tracking money spent per 24h block based on UTC time. It is good enough for now, but we may want to change this later.
    uint32 lastTransferDay;

    /// nonce tracking
    mapping(uint32 => uint8) nonces; // keys: otp index (=timestamp in seconds / interval - t0); values: the expected nonce for that otp interval. An reveal with a nonce less than the expected value will be rejected
    uint32[] nonceTracker; // list of nonces keys that have a non-zero value. keys cannot possibly result a successful reveal (indices beyond REVEAL_MAX_DELAY old) are auto-deleted during a clean up procedure that is called every time the nonces are incremented for some key. For each deleted key, the corresponding key in nonces will also be deleted. So the size of nonceTracker and nonces are both bounded.

    // constants
    uint32 constant REVEAL_MAX_DELAY = 60;
    uint32 constant SECONDS_PER_DAY = 86400;
    uint256 constant AUTO_RECOVERY_TRIGGER_AMOUNT = 1 ether;
    uint32 constant MAX_COMMIT_SIZE = 120;

    uint32 constant majorVersion = 0x7; // a change would require client to migrate
    uint32 constant minorVersion = 0x2; // a change would not require the client to migrate

    enum OperationType {
        TRACK, UNTRACK, TRANSFER_TOKEN, OVERRIDE_TRACK, TRANSFER, SET_RECOVERY_ADDRESS, RECOVER
    }
    /// commit management
    struct Commit {
        bytes32 hash;
        bytes32 paramsHash;
        bytes32 verificationHash;
        uint32 timestamp;
        bool completed;
    }

    bytes32[] commits; // self-clean on commit (auto delete commits that are beyond REVEAL_MAX_DELAY), so it's bounded by the number of commits an attacker can spam within REVEAL_MAX_DELAY time in the worst case, which is not too bad.
    mapping(bytes32 => Commit[]) commitLocker;


    constructor(bytes32 root_, uint8 height_, uint8 interval_, uint32 t0_, uint32 lifespan_, uint8 maxOperationsPerInterval_,
        address payable lastResortAddress_, uint256 dailyLimit_)
    {
        root = root_;
        height = height_;
        interval = interval_;
        t0 = t0_;
        lifespan = lifespan_;
        lastResortAddress = lastResortAddress_;
        dailyLimit = dailyLimit_;
        maxOperationsPerInterval = maxOperationsPerInterval_;
    }

    receive() external payable {
        emit PaymentReceived(msg.value, msg.sender);
        if (msg.value != AUTO_RECOVERY_TRIGGER_AMOUNT) {
            return;
        }
        if (msg.sender != lastResortAddress) {
            return;
        }
        if (lastResortAddress == address(0)) {
            return;
        }
        if (msg.sender == address(this)) {
            return;
        }
        emit AutoRecoveryTriggered(msg.sender);
        require(_drain());
    }


    function retire() external returns (bool)
    {
        require(uint32(block.timestamp / interval) - t0 > lifespan, "Too early to retire");
        require(lastResortAddress != address(0), "Last resort address is not set");
        require(_drain(), "Recovery failed");
        return true;
    }

    function getInfo() external view returns (bytes32, uint8, uint8, uint32, uint32, uint8, address, uint256)
    {
        return (root, height, interval, t0, lifespan, maxOperationsPerInterval, lastResortAddress, dailyLimit);
    }

    function getVersion() external pure returns (uint32, uint32)
    {
        return (majorVersion, minorVersion);
    }

    function getCurrentSpending() external view returns (uint256, uint256)
    {
        return (spentToday, lastTransferDay);
    }

    function getNonce() external view returns (uint8)
    {
        uint32 index = uint32(block.timestamp) / interval - t0;
        return nonces[index];
    }

    function getCommits() external pure returns (bytes32[] memory, bytes32[] memory, uint32[] memory, bool[] memory){
        revert("Deprecated");
    }

    function getAllCommits() external view returns (bytes32[] memory, bytes32[] memory, bytes32[] memory, uint32[] memory, bool[] memory)
    {
        uint32 numCommits = 0;
        for (uint32 i = 0; i < commits.length; i++) {
            Commit[] storage cc = commitLocker[commits[i]];
            numCommits += uint32(cc.length);
        }
        bytes32[] memory hashes = new bytes32[](numCommits);
        bytes32[] memory paramHashes = new bytes32[](numCommits);
        bytes32[] memory verificationHashes = new bytes32[](numCommits);
        uint32[] memory timestamps = new uint32[](numCommits);
        bool[] memory completed = new bool[](numCommits);
        uint32 index = 0;
        for (uint32 i = 0; i < commits.length; i++) {
            Commit[] storage cc = commitLocker[commits[i]];
            for (uint32 j = 0; j < cc.length; j++) {
                Commit storage c = cc[j];
                hashes[index] = c.hash;
                paramHashes[index] = c.paramsHash;
                verificationHashes[index] = c.verificationHash;
                timestamps[index] = c.timestamp;
                completed[index] = c.completed;
                index++;
            }
        }
        return (hashes, paramHashes, verificationHashes, timestamps, completed);
    }

    function findCommit(bytes32 /*hash*/) external pure returns (bytes32, bytes32, uint32, bool){
        revert("Deprecated");
    }

    function lookupCommit(bytes32 hash) external view returns (bytes32[] memory, bytes32[] memory, bytes32[] memory, uint32[] memory, bool[] memory){
        Commit[] storage cc = commitLocker[hash];
        bytes32[] memory hashes = new bytes32[](cc.length);
        bytes32[] memory paramHashes = new bytes32[](cc.length);
        bytes32[] memory verificationHashes = new bytes32[](cc.length);
        uint32[] memory timestamps = new uint32[](cc.length);
        bool[] memory completed = new bool[](cc.length);
        for (uint32 i = 0; i < cc.length; i++) {
            Commit storage c = cc[i];
            hashes[i] = c.hash;
            paramHashes[i] = c.paramsHash;
            verificationHashes[i] = c.verificationHash;
            timestamps[i] = c.timestamp;
            completed[i] = c.completed;
        }
        return (hashes, paramHashes, verificationHashes, timestamps, completed);
    }

    function commit(bytes32 hash, bytes32 paramsHash, bytes32 verificationHash) external {
        _cleanupCommits();
        Commit memory nc = Commit(hash, paramsHash, verificationHash, uint32(block.timestamp), false);
        require(commits.length < MAX_COMMIT_SIZE, "Too many commits");
        commits.push(hash);
        commitLocker[hash].push(nc);
    }

    /// This function sends all remaining funds of the wallet to `lastResortAddress`. The caller should verify that `lastResortAddress` is not null.
    /// TODO: also transfer all tracked ERC20, 721, 1155 tokens to `lastResortAddress`
    function _drain() internal returns (bool) {
        // this may be triggered after revealing the proof, and we must prevent revert in all cases
        (bool success,) = lastResortAddress.call{value : address(this).balance}("");
        return success;
    }

    function _transfer(address payable dest, uint256 amount) internal returns (bool) {
        uint32 day = uint32(block.timestamp / SECONDS_PER_DAY);
        if (day > lastTransferDay) {
            spentToday = 0;
            lastTransferDay = day;
        }
        if (spentToday + amount > dailyLimit) {
            emit ExceedDailyLimit(amount, dailyLimit, spentToday, dest);
            return false;
        }
        if (address(this).balance < amount) {
            emit InsufficientFund(amount, address(this).balance, dest);
            return false;
        }
        spentToday += amount;
        (bool success,) = dest.call{value : amount}("");
        // we do not want to revert the whole transaction if this operation fails, since EOTP is already revealed
        if (!success) {
            spentToday -= amount;
            emit UnknownTransferError(dest);
            return false;
        }

        emit PaymentSent(amount, dest);
        return true;
    }

    function _recover() internal returns (bool){
        if (lastResortAddress == address(0)) {
            emit LastResortAddressNotSet();
            return false;
        }
        if (!_drain()) {
            emit RecoveryFailure();
            return false;
        }
        return true;
    }

    function _setRecoveryAddress(address payable lastResortAddress_) internal {
        require(lastResortAddress == address(0), "Last resort address is already set");
        lastResortAddress = lastResortAddress_;
    }

    function _transferToken(TokenType tokenType, address contractAddress, uint256 tokenId, address dest, uint256 amount, bytes memory data) internal {
        if (tokenType == TokenType.ERC20) {
            try IERC20(contractAddress).transfer(dest, amount) returns (bool success){
                if (success) {
                    _trackToken(tokenType, contractAddress, tokenId);
                    emit TokenTransferSucceeded(tokenType, contractAddress, tokenId, dest, amount);
                    return;
                }
                emit TokenTransferFailed(tokenType, contractAddress, tokenId, dest, amount);
            } catch Error(string memory reason){
                emit TokenTransferError(tokenType, contractAddress, tokenId, dest, amount, reason);
            } catch {
                emit TokenTransferError(tokenType, contractAddress, tokenId, dest, amount, "");
            }
        } else if (tokenType == TokenType.ERC721) {
            try IERC721(contractAddress).safeTransferFrom(address(this), dest, tokenId, data){
                emit TokenTransferSucceeded(tokenType, contractAddress, tokenId, dest, amount);
            } catch Error(string memory reason){
                emit TokenTransferError(tokenType, contractAddress, tokenId, dest, amount, reason);
            } catch {
                emit TokenTransferError(tokenType, contractAddress, tokenId, dest, amount, "");
            }
        } else if (tokenType == TokenType.ERC1155) {
            try IERC1155(contractAddress).safeTransferFrom(address(this), dest, tokenId, amount, data) {
                emit TokenTransferSucceeded(tokenType, contractAddress, tokenId, dest, amount);
            } catch Error(string memory reason){
                emit TokenTransferError(tokenType, contractAddress, tokenId, dest, amount, reason);
            } catch {
                emit TokenTransferError(tokenType, contractAddress, tokenId, dest, amount, "");
            }
        }
    }

    /// Provides commitHash, paramsHash, and verificationHash given the parameters
    function _getRevealHash(bytes32 neighbor, uint32 indexWithNonce, bytes32 eotp,
        OperationType operationType, TokenType tokenType, address contractAddress, uint256 tokenId, address dest, uint256 amount, bytes calldata data) pure internal returns (bytes32, bytes32) {
        bytes32 hash = keccak256(bytes.concat(neighbor, bytes32(bytes4(indexWithNonce)), eotp));
        bytes32 paramsHash = bytes32(0);
        if (operationType == OperationType.TRANSFER) {
            paramsHash = keccak256(bytes.concat(bytes32(bytes20(address(dest))), bytes32(amount)));
        } else if (operationType == OperationType.RECOVER) {
            paramsHash = bytes32(0);
        } else if (operationType == OperationType.SET_RECOVERY_ADDRESS) {
            paramsHash = keccak256(bytes.concat(bytes32(bytes20(address(dest)))));
        } else {
            bytes memory packed = bytes.concat(
                bytes32(uint256(operationType)),
                bytes32(uint256(tokenType)),
                bytes32(bytes20(contractAddress)),
                bytes32(tokenId),
                bytes32(bytes20(dest)),
                bytes32(amount),
                data
            );
            paramsHash = keccak256(bytes.concat(packed));
        }
        return (hash, paramsHash);
    }


    function reveal(bytes32[] calldata neighbors, uint32 indexWithNonce, bytes32 eotp,
        OperationType operationType, TokenType tokenType, address contractAddress, uint256 tokenId, address payable dest, uint256 amount, bytes calldata data)
    external {
        _isCorrectProof(neighbors, indexWithNonce, eotp);
        (bytes32 commitHash, bytes32 paramsHash) = _getRevealHash(neighbors[0], indexWithNonce, eotp,
            operationType, tokenType, contractAddress, tokenId, dest, amount, data);
        uint32 commitIndex = _verifyReveal(commitHash, indexWithNonce, paramsHash, eotp);
        _completeReveal(commitHash, commitIndex);
        // No revert should occur below this point
        if (operationType == OperationType.TRACK) {
            if (data.length > 0) {
                _multiTrack(data);
            } else {
                _trackToken(tokenType, contractAddress, tokenId);
            }
        } else if (operationType == OperationType.UNTRACK) {
            if (data.length > 0) {
                _untrackToken(tokenType, contractAddress, tokenId);
            } else {
                _multiUntrack(data);
            }
        } else if (operationType == OperationType.TRANSFER_TOKEN) {
            _transferToken(tokenType, contractAddress, tokenId, dest, amount, data);
        } else if (operationType == OperationType.OVERRIDE_TRACK) {
            _overrideTrackWithBytes(data);
        } else if (operationType == OperationType.TRANSFER) {
            _transfer(dest, amount);
        } else if (operationType == OperationType.RECOVER) {
            _recover();
        } else if (operationType == OperationType.SET_RECOVERY_ADDRESS) {
            _setRecoveryAddress(dest);
        }
    }

    /// This is just a wrapper around a modifier previously called `isCorrectProof`, to avoid "Stack too deep" error. Duh.
    function _isCorrectProof(bytes32[] calldata neighbors, uint32 position, bytes32 eotp) view internal {
        require(neighbors.length == height - 1, "Not enough neighbors provided");
        bytes32 h = sha256(bytes.concat(eotp));
        for (uint8 i = 0; i < height - 1; i++) {
            if ((position & 0x01) == 0x01) {
                h = sha256(bytes.concat(neighbors[i], h));
            } else {
                h = sha256(bytes.concat(h, neighbors[i]));
            }
            position >>= 1;
        }
        require(root == h, "Proof is incorrect");
        return;
    }

    /// Remove old commits from storage, where the commit's timestamp is older than block.timestamp - REVEAL_MAX_DELAY. The purpose is to remove dangling data from blockchain, and prevent commits grow unbounded. This is executed at commit time. The committer pays for the gas of this cleanup. Therefore, any attacker who intend to spam commits would be disincentivized. The attacker would not succeed in preventing any normal operation by the user.
    function _cleanupCommits() internal {
        uint32 timelyIndex = 0;
        uint32 bt = uint32(block.timestamp);
        // go through past commits chronologically, starting from the oldest, and find the first commit that is not older than block.timestamp - REVEAL_MAX_DELAY.
        for (; timelyIndex < commits.length; timelyIndex++) {
            bytes32 hash = commits[timelyIndex];
            Commit[] storage cc = commitLocker[hash];
            // We may skip because the commit is already cleaned up and is considered "untimely".
            if (cc.length == 0) {
                continue;
            }
            // We take the first entry in `cc` as the timestamp for all commits under commit hash `hash`, because the first entry represents the oldest commit and only commit if an attacker is not attacking this wallet. If an attacker is front-running commits, the first entry may be from the attacker, but its timestamp should be identical to the user's commit (or close enough to the user's commit, if network is a bit congested)
            Commit storage c = cc[0];
        unchecked {
            if (c.timestamp >= bt - REVEAL_MAX_DELAY) {
                break;
            }
        }
        }
        // Now `timelyIndex` holds the index of the first commit that is timely. All commits at an index less than `timelyIndex` must be deleted;
        if (timelyIndex == 0) {
            // no commit is older than block.timestamp - REVEAL_MAX_DELAY. Nothing needs to be cleaned up
            return;
        }
        // Delete Commit instances for commits that are are older than block.timestamp - REVEAL_MAX_DELAY
        for (uint32 i = 0; i < timelyIndex; i++) {
            bytes32 hash = commits[i];
            Commit[] storage cc = commitLocker[hash];
            for (uint32 j = 0; j < cc.length; j++) {
                delete cc[j];
            }
            delete commitLocker[hash];
        }
        // Shift all commit hashes up by `timelyIndex` positions, and discard `commitIndex` number of hashes at the end of the array
        // This process erases old commits
        uint32 len = uint32(commits.length);
        for (uint32 i = timelyIndex; i < len; i++) {
        unchecked{
            commits[i - timelyIndex] = commits[i];
        }
        }
        for (uint32 i = 0; i < timelyIndex; i++) {
            commits.pop();
        }
        // TODO (@polymorpher): upgrade the above code after solidity implements proper support for struct-array memory-storage copy operation.
    }

    function _isRevealTimely(uint32 commitTime) view internal returns (bool)
    {
        return uint32(block.timestamp) - commitTime < REVEAL_MAX_DELAY;
    }

    /// This function verifies that the first valid entry with respect to the given `eotp` in `commitLocker[hash]` matches the provided `paramsHash` and `verificationHash`. An entry is valid with respect to `eotp` iff `h3(entry.paramsHash . eotp)` equals `entry.verificationHash`
    function _verifyReveal(bytes32 hash, uint32 indexWithNonce, bytes32 paramsHash, bytes32 eotp) view internal returns (uint32)
    {
        uint32 index = indexWithNonce / maxOperationsPerInterval;
        uint8 nonce = uint8(indexWithNonce % maxOperationsPerInterval);
        Commit[] storage cc = commitLocker[hash];
        require(cc.length > 0, "No commit found");
        for (uint32 i = 0; i < cc.length; i++) {
            Commit storage c = cc[i];
            bytes32 expectedVerificationHash = keccak256(bytes.concat(c.paramsHash, eotp));
            if (c.verificationHash != expectedVerificationHash) {
                // Invalid entry. Ignore
                continue;
            }
            require(c.paramsHash == paramsHash, "Parameter hash mismatch");
            uint32 counter = c.timestamp / interval - t0;
            require(counter == index, "Index - timestamp mismatch");
            uint8 expectedNonce = nonces[counter];
            require(nonce >= expectedNonce, "Nonce too low");
            require(!c.completed, "Commit already completed");
            // This normally should not happen, but when the network is congested (regardless of whether due to an attacker's malicious acts or not), the legitimate reveal may become untimely. This may happen before the old commit is cleaned up by another fresh commit. We enforce this restriction so that the attacker would not have a lot of time to reverse-engineer a single EOTP or leaf using an old commit.
            require(_isRevealTimely(c.timestamp), "Reveal too late");
            return i;
        }
        revert("No valid commit");
    }

    function _completeReveal(bytes32 commitHash, uint32 commitIndex) internal {
        Commit[] storage cc = commitLocker[commitHash];
        require(cc.length > 0, "Invalid commit hash");
        require(cc.length > commitIndex, "Invalid commitIndex");
        Commit storage c = cc[commitIndex];
        require(c.timestamp > 0, "Invalid commit timestamp");
        // should not happen
        uint32 index = uint32(c.timestamp) / interval - t0;
        _incrementNonce(index);
        _cleanupNonces();
        c.completed = true;
    }

    /// This function removes all tracked nonce values correspond to interval blocks that are older than block.timestamp - REVEAL_MAX_DELAY. In doing so, extraneous data in the blockchain is removed, and both nonces and nonceTracker are bounded in size.
    function _cleanupNonces() internal {
        uint32 tMin = uint32(block.timestamp) - REVEAL_MAX_DELAY;
        uint32 indexMinUnadjusted = tMin / interval;
        uint32 indexMin = 0;
        if (indexMinUnadjusted > t0) {
            indexMin = indexMinUnadjusted - t0;
        }
        uint32[] memory nonZeroNonces = new uint32[](nonceTracker.length);
        uint32 numValidIndices = 0;
        for (uint8 i = 0; i < nonceTracker.length; i++) {
            uint32 index = nonceTracker[i];
            if (index < indexMin) {
                delete nonces[index];
            } else {
                nonZeroNonces[numValidIndices] = index;
            unchecked {
                numValidIndices++;
            }
            }
        }
        // TODO (@polymorpher): This can be later made more efficient by inline assembly. https://ethereum.stackexchange.com/questions/51891/how-to-pop-from-decrease-the-length-of-a-memory-array-in-solidity
        uint32[] memory reducedArray = new uint32[](numValidIndices);
        for (uint8 i = 0; i < numValidIndices; i++) {
            reducedArray[i] = nonZeroNonces[i];
        }
        nonceTracker = reducedArray;
    }

    function _incrementNonce(uint32 index) internal {
        uint8 v = nonces[index];
        if (v == 0) {
            nonceTracker.push(index);
        }
    unchecked{
        nonces[index] = v + 1;
    }
    }
}
