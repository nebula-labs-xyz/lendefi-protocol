// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "../vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title LendefiPoRFeed
 * @notice Proof of Reserve feed implementing Chainlink's AggregatorV3Interface
 * @dev Tracks and exposes reserve data for a specific asset in the Lendefi protocol
 */
contract LendefiPoRFeed is AggregatorV3Interface {
    // Core state variables
    address public immutable asset;
    address public immutable lendefiProtocol;
    address public updater;
    address public owner;

    // Struct to store round data
    struct Round {
        int256 answer; // Reserve or supply value (e.g., USD in escrow or TUSD total supply)
        uint256 startedAt; // Timestamp when the round started
        uint256 updatedAt; // Timestamp when the round was updated
        uint80 answeredInRound; // Round ID when the answer was computed
    }

    // Mapping of round ID to round data
    mapping(uint80 => Round) private rounds;
    uint80 public latestRoundId; // Tracks the latest round ID

    // Events
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event UpdaterChanged(address indexed previousUpdater, address indexed newUpdater);
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event ReservesUpdated(uint80 roundId, int256 amount);

    // Errors
    error Unauthorized();
    error ZeroAddress();
    error RoundNotAvailable();
    error InvalidRoundId();

    constructor(address _asset, address _lendefiProtocol, address _updater, address _owner) {
        if (_asset == address(0) || _lendefiProtocol == address(0) || _updater == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }

        asset = _asset;
        lendefiProtocol = _lendefiProtocol;
        updater = _updater;
        owner = _owner;

        // Initialize with round ID 1
        latestRoundId = 1;
        rounds[latestRoundId] =
            Round({answer: 0, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 1});
    }

    /**
     * @notice Updates the feed with a specific round ID
     * @param _roundId The round ID for this update
     * @param _answer The reserve value
     */
    function updateAnswer(uint80 _roundId, int256 _answer) external {
        if (msg.sender != updater) revert Unauthorized();
        if (_roundId <= latestRoundId) revert InvalidRoundId();

        uint256 timestamp = block.timestamp;

        // Update round data
        latestRoundId = _roundId;
        rounds[_roundId] =
            Round({answer: _answer, startedAt: timestamp, updatedAt: timestamp, answeredInRound: _roundId});

        emit AnswerUpdated(_answer, _roundId, timestamp);
    }

    /**
     * @notice Updates the reserve amount for the asset
     * @param reserveAmount Current reserve amount of the asset
     */
    function updateReserves(uint256 reserveAmount) external {
        if (msg.sender != updater) revert Unauthorized();

        // Create new round
        latestRoundId++;
        uint256 timestamp = block.timestamp;

        // Store round data
        rounds[latestRoundId] = Round({
            answer: int256(reserveAmount),
            startedAt: timestamp,
            updatedAt: timestamp,
            answeredInRound: latestRoundId
        });

        emit ReservesUpdated(latestRoundId, int256(reserveAmount));
    }

    /// @notice Retrieves data for a specific round
    /// @param _roundId The round ID to query
    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round memory round = rounds[_roundId];
        require(round.updatedAt > 0, "Round does not exist");
        return (_roundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound);
    }

    /// @notice Retrieves the latest round data
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round memory round = rounds[latestRoundId];
        require(round.updatedAt > 0, "No data available");
        return (latestRoundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound);
    }

    function decimals() external view override returns (uint8) {
        try IERC20Metadata(asset).decimals() returns (uint8 assetDecimals) {
            return assetDecimals;
        } catch {
            return 18;
        }
    }

    function description() external view override returns (string memory) {
        string memory symbol = "UNKNOWN";

        try IERC20Metadata(asset).symbol() returns (string memory _symbol) {
            symbol = _symbol;
        } catch {}

        return string(abi.encodePacked("Lendefi Protocol Reserves for ", symbol));
    }

    function version() external pure override returns (uint256) {
        return 3; //AggregatorV3Interface
    }

    // Management functions
    function setUpdater(address newUpdater) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newUpdater == address(0)) revert ZeroAddress();

        address oldUpdater = updater;
        updater = newUpdater;

        emit UpdaterChanged(oldUpdater, newUpdater);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();

        address oldOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(oldOwner, newOwner);
    }
}
