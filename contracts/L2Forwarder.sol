// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {IERC20Inbox} from "@arbitrum/nitro-contracts/src/bridge/IERC20Inbox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {L2ForwarderPredictor} from "./L2ForwarderPredictor.sol";

/// @title  L2Forwarder
/// @notice L2 contract that receives ERC20 tokens and ETH from a token bridge retryable,
///         forwards them to a recipient on L3, optionally pays a relayer,
///         and allows the owner to make arbitrary calls.
/// @dev    The parameters of the bridge transaction are encoded in the L2Forwarder address. See L2ForwarderPredictor and L2ForwarderFactory.
contract L2Forwarder is L2ForwarderPredictor {
    using SafeERC20 for IERC20;

    /// @notice Address that owns this L2Forwarder and can make arbitrary calls
    address public owner;

    /// @notice Emitted after a successful call to rescue
    /// @param  targets Addresses that were called
    /// @param  values  Values that were sent
    /// @param  datas   Calldata that was sent
    event Rescued(address[] targets, uint256[] values, bytes[] datas);

    /// @notice Emitted after a successful call to bridgeToL3
    event BridgedToL3(uint256 tokenAmount, uint256 ethBalance);

    /// @notice Thrown when initialize is called after initialization
    error AlreadyInitialized();
    /// @notice Thrown when a non-owner calls rescue
    error OnlyOwner();
    /// @notice Thrown when the length of targets, values, and datas are not equal in a call to rescue
    error LengthMismatch();
    /// @notice Thrown when an external call in rescue fails
    error CallFailed(address to, uint256 value, bytes data, bytes returnData);
    /// @notice Thrown when the relayer payment fails
    error RelayerPaymentFailed();
    /// @notice Thrown when bridgeToL3 is called with incorrect parameters
    error IncorrectParams();

    constructor(address _factory) L2ForwarderPredictor(_factory, address(this)) {}

    /// @notice Initialize this L2Forwarder
    /// @param  _owner Address that owns this L2Forwarder
    /// @dev    Can only be called once. Failing to set owner properly could result in loss of funds.
    function initialize(address _owner) external {
        if (owner != address(0)) revert AlreadyInitialized();
        owner = _owner;
    }

    function _bridgeToEthFeeL3(L2ForwarderParams memory params) internal {
        // get gateway
        address l2l3Gateway = L1GatewayRouter(params.routerOrInbox).getGateway(params.token);

        uint256 tokenBalance = IERC20(params.token).balanceOf(address(this));

        // approve gateway
        IERC20(params.token).safeApprove(l2l3Gateway, tokenBalance);

        // send tokens through the bridge to intended recipient
        // (send all the ETH we have too, we could have more than msg.value b/c of fee refunds)
        // overestimate submission cost to ensure all ETH is sent through
        uint256 ethBalance = address(this).balance;
        uint256 balanceSubRelayerPayment = address(this).balance - params.relayerPayment;
        uint256 submissionCost = balanceSubRelayerPayment - params.gasLimit * params.gasPrice;
        L1GatewayRouter(params.routerOrInbox).outboundTransferCustomRefund{value: balanceSubRelayerPayment}(
            params.token,
            params.to,
            params.to,
            tokenBalance,
            params.gasLimit,
            params.gasPrice,
            abi.encode(submissionCost, bytes(""))
        );

        _trySendRelayerPayment(params.relayerPayment);

        emit BridgedToL3(tokenBalance, ethBalance);
    }

    function _bridgeFeeTokenToCustomFeeL3(L2ForwarderParams memory params) internal {
        uint256 tokenBalance = IERC20(params.token).balanceOf(address(this));

        // approve inbox
        IERC20(params.token).safeApprove(params.routerOrInbox, tokenBalance);

        IERC20Inbox(params.routerOrInbox).depositERC20(tokenBalance);

        // if there is a relayer payment, send it to the relayer
        _trySendRelayerPayment(params.relayerPayment);       
    }

    function _bridgeNonFeeTokenToCustomFeeL3(L2ForwarderParams memory params) internal {
        // get gateway
        address l2l3Gateway = L1GatewayRouter(params.routerOrInbox).getGateway(params.token);

        uint256 tokenBalance = IERC20(params.token).balanceOf(address(this));
        uint256 feeTokenBalance = IERC20(params.l2FeeToken).balanceOf(address(this));

        // approve gateway
        IERC20(params.token).safeApprove(l2l3Gateway, tokenBalance);

        // send feeToken to the inbox
        address inbox = L1GatewayRouter(params.routerOrInbox).inbox();
        IERC20(params.l2FeeToken).safeTransfer(inbox, feeTokenBalance);

        // send tokens through the bridge to intended recipient
        // overestimate submission cost to ensure all feeToken is sent through
        uint256 submissionCost = IERC20(params.l2FeeToken).balanceOf(inbox) - params.gasLimit * params.gasPrice;
        L1GatewayRouter(params.routerOrInbox).outboundTransferCustomRefund(
            params.token,
            params.to,
            params.to,
            tokenBalance,
            params.gasLimit,
            params.gasPrice,
            abi.encode(submissionCost, bytes(""))
        );

        _trySendRelayerPayment(params.relayerPayment);
    }

    function _trySendRelayerPayment(uint256 relayerPayment) internal {
        if (relayerPayment > 0) {
            (bool paymentSuccess,) = tx.origin.call{value: relayerPayment}("");
            if (!paymentSuccess) revert RelayerPaymentFailed();
        }
    }

    /// @notice Send tokens and ETH through the bridge to a recipient on L3 and optionally pay a relayer.
    /// @param  params Parameters of the bridge transaction. There is only one combination of valid parameters for a given L2Forwarder.
    /// @dev    The params are encoded in the L2Forwarder address. Will revert if params do not match.
    function bridgeToL3(L2ForwarderParams memory params) external {
        // check parameters
        if (address(this) != l2ForwarderAddress(params)) revert IncorrectParams();

        if (params.l2FeeToken == address(0)) {
            _bridgeToEthFeeL3(params);
        }
        else if (params.l2FeeToken == params.token) {
            _bridgeFeeTokenToCustomFeeL3(params);
        }
        else {
            _bridgeNonFeeTokenToCustomFeeL3(params);
        }
    }

    /// @notice Allows the owner of this L2Forwarder to make arbitrary calls.
    ///         If bridgeToL3 cannot succeed, the owner can call this to rescue their tokens and ETH.
    /// @param  targets Addresses to call
    /// @param  values  Values to send
    /// @param  datas   Calldata to send
    function rescue(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas) external payable {
        if (msg.sender != owner) revert OnlyOwner();
        if (targets.length != values.length || values.length != datas.length) revert LengthMismatch();

        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, bytes memory retData) = targets[i].call{value: values[i]}(datas[i]);
            if (!success) revert CallFailed(targets[i], values[i], datas[i], retData);
        }

        emit Rescued(targets, values, datas);
    }

    receive() external payable {}
}
