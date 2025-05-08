// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {AutomationBase} from "./AutomationBase.sol";
import {AutomationCompatibleInterface} from "../interfaces/AutomationCompatibleInterface.sol";

abstract contract AutomationCompatible is AutomationBase, AutomationCompatibleInterface {}
