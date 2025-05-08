// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

interface IPoRFactory {
    function createFeed(address asset) external returns (address);
    function getFeed(address asset) external view returns (address);
}
