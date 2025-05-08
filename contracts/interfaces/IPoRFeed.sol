// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

// Add interface for PoR feed
interface IPoRFeed {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function updateAnswer(uint80 _roundId, int256 _answer) external;
    function updateReserves(uint256 _answer) external;
    function latestRoundId() external view returns (uint80);
}
