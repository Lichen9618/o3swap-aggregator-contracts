// SPDX-License-Identifier: GPL-3.0

pragma solidity =0.6.12;

import "./utils/Ownable.sol";
import "./oec/interfaces/IUniswapV2Factory.sol";
import "./oec/libraries/UniswapV2Library.sol";
import './libraries/TransferHelper.sol';
import "./oec/interfaces/IWOKT.sol";
import "./oec/interfaces/IKIP20.sol";
import "./libraries/SafeMath.sol";
import "./interfaces/ISwapper.sol";
import "./libraries/Convert.sol";

contract O3SwapOECswapBridge is Ownable {
    using SafeMath for uint256;
    using Convert for bytes;

    event LOG_AGG_SWAP (
        uint256 amountOut, // Raw swapped token amount out without aggFee
        uint256 fee
    );

    address public WOKT;
    mapping(uint => address) swapFactoryMap;
    mapping(uint => bytes32) swapCodeHash;
    address public polySwapper;
    uint public polySwapperId;

    uint256 public aggregatorFee = 3 * 10 ** 7; // Default to 0.3%
    uint256 public constant FEE_DENOMINATOR = 10 ** 10;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'O3SwapOECswapBridge: EXPIRED');
        _;
    }

    constructor (
        address _wokt,
        address _factory,
        address _swapper,
        uint _swapperId
    ) public {
        require(_wokt != address(0), "O3SwapOECswapBridge: ZERO_WETH_ADDRESS");
        require(_factory != address(0), "O3SwapOECswapBridge: ZERO_FACTORY_ADDRESS");
        require(_swapper != address(0), "O3SwapOECswapBridge: ZERO_SWAPPER_ADDRESS");

        WOKT = _wokt;
        uniswapFactory = _factory;
        polySwapper = _swapper;
        polySwapperId = _swapperId;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint swapAmountOutMin,
        address[] calldata path,
        address to,
        uint deadline,
        uint swapIndex
    ) external virtual ensure(deadline) {
        uint amountOut = _swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, swapAmountOutMin, path, swapIndex);
        uint feeAmount = amountOut.mul(aggregatorFee).div(FEE_DENOMINATOR);

        emit LOG_AGG_SWAP(amountOut, feeAmount);

        uint adjustedAmountOut = amountOut.sub(feeAmount);
        TransferHelper.safeTransfer(path[path.length - 1], to, adjustedAmountOut);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokensCrossChain(
        uint amountIn,
        uint swapAmountOutMin,
        address[] calldata path,
        bytes memory to,
        uint deadline,
        uint64 toPoolId,
        uint64 toChainId,
        bytes memory toAssetHash,
        uint polyMinOutAmount,
        uint fee,
        uint swapIndex
    ) external virtual payable ensure(deadline) returns (bool) {
        uint polyAmountIn;
        {
            uint amountOut = _swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, swapAmountOutMin, path, swapIndex);
            uint feeAmount = amountOut.mul(aggregatorFee).div(FEE_DENOMINATOR);
            emit LOG_AGG_SWAP(amountOut, feeAmount);
            polyAmountIn = amountOut.sub(feeAmount);
        }

        return _cross(
            path[path.length - 1],
            toPoolId,
            toChainId,
            toAssetHash,
            to,
            polyAmountIn,
            polyMinOutAmount,
            fee
        );
    }

    function _swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        uint swapIndex
    ) internal virtual returns (uint) {
        require(swapFactoryMap[swapIndex] != address(0), "O3SwapOECswapBridge: ZERO_FACTORY_ADDRESS");
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(swapFactoryMap[swapIndex] , path[0], path[1], swapCodeHash[swapIndex]), amountIn
        );
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(address(this));
        _swapSupportingFeeOnTransferTokens(path, address(this), swapIndex);
        uint amountOut = IERC20(path[path.length - 1]).balanceOf(address(this)).sub(balanceBefore);
        require(amountOut >= amountOutMin, 'O3SwapOECswapBridge: INSUFFICIENT_OUTPUT_AMOUNT');
        return amountOut;
    }

    function swapExactOKTForTokensSupportingFeeOnTransferTokens(
        uint swapAmountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual payable ensure(deadline) {
        uint amountOut = _swapExactOKTForTokensSupportingFeeOnTransferTokens(swapAmountOutMin, path, 0);
        uint feeAmount = amountOut.mul(aggregatorFee).div(FEE_DENOMINATOR);

        emit LOG_AGG_SWAP(amountOut, feeAmount);

        uint adjustedAmountOut = amountOut.sub(feeAmount);
        TransferHelper.safeTransfer(path[path.length - 1], to, adjustedAmountOut);
    }

    function swapExactOKTForTokensSupportingFeeOnTransferTokensCrossChain(
        uint swapAmountOutMin,
        address[] calldata path,
        bytes memory to,
        uint deadline,
        uint64 toPoolId,
        uint64 toChainId,
        bytes memory toAssetHash,
        uint polyMinOutAmount,
        uint fee
    ) external virtual payable ensure(deadline) returns (bool) {
        uint polyAmountIn;
        {
            uint amountOut = _swapExactOKTForTokensSupportingFeeOnTransferTokens(swapAmountOutMin, path, fee);
            uint feeAmount = amountOut.mul(aggregatorFee).div(FEE_DENOMINATOR);
            emit LOG_AGG_SWAP(amountOut, feeAmount);
            polyAmountIn = amountOut.sub(feeAmount);
        }

        return _cross(
            path[path.length - 1],
            toPoolId,
            toChainId,
            toAssetHash,
            to,
            polyAmountIn,
            polyMinOutAmount,
            fee
        );
    }

    function _swapExactOKTForTokensSupportingFeeOnTransferTokens(
        uint swapAmountOutMin,
        address[] calldata path,
        uint fee,
        uint swapIndex
    ) internal virtual returns (uint) {
        require(path[0] == WOKT, 'O3SwapOECswapBridge: INVALID_PATH');
        uint amountIn = msg.value.sub(fee);
        require(amountIn > 0, 'O3SwapOECswapBridge: INSUFFICIENT_INPUT_AMOUNT');
        IWOKT(WOKT).deposit{value: amountIn}();
        require(swapFactoryMap[swapIndex] != address(0), "O3SwapOECswapBridge: ZERO_FACTORY_ADDRESS");
        assert(IWOKT(WOKT).transfer(UniswapV2Library.pairFor(swapFactoryMap[swapIndex], path[0], path[1]), amountIn, swapCodeHash[swapIndex]));
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(address(this));
        _swapSupportingFeeOnTransferTokens(path, address(this), swapIndex);
        uint amountOut = IERC20(path[path.length - 1]).balanceOf(address(this)).sub(balanceBefore);
        require(amountOut >= swapAmountOutMin, 'O3SwapOECswapBridge: INSUFFICIENT_OUTPUT_AMOUNT');
        return amountOut;
    }

    function swapExactTokensForOKTSupportingFeeOnTransferTokens(
        uint amountIn,
        uint swapAmountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual ensure(deadline) {
        uint amountOut = _swapExactTokensForOKTSupportingFeeOnTransferTokens(amountIn, swapAmountOutMin, path);
        uint feeAmount = amountOut.mul(aggregatorFee).div(FEE_DENOMINATOR);

        emit LOG_AGG_SWAP(amountOut, feeAmount);

        IWOKT(WOKT).withdraw(amountOut);
        uint adjustedAmountOut = amountOut.sub(feeAmount);
        TransferHelper.safeTransferETH(to, adjustedAmountOut);
    }

    function _swapExactTokensForOKTSupportingFeeOnTransferTokens(
        uint amountIn,
        uint swapAmountOutMin,
        address[] calldata path,
        uint swapIndex
    ) internal virtual returns (uint) {
        require(path[path.length - 1] == WOKT, 'O3SwapOECswapBridge: INVALID_PATH');
        require(swapFactoryMap[swapIndex] != address(0), "O3SwapOECswapBridge: ZERO_FACTORY_ADDRESS");
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(swapFactoryMap[swapIndex], path[0], path[1], swapCodeHash[swapIndex]), amountIn
        );
        uint balanceBefore = IERC20(WOKT).balanceOf(address(this));
        _swapSupportingFeeOnTransferTokens(path, address(this), swapIndex);
        uint amountOut = IERC20(WOKT).balanceOf(address(this)).sub(balanceBefore);
        require(amountOut >= swapAmountOutMin, 'O3SwapOECswapBridge: INSUFFICIENT_OUTPUT_AMOUNT');
        return amountOut;
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to, uint swapIndex) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            require(swapFactoryMap[swapIndex] != address(0), "O3SwapOECswapBridge: ZERO_FACTORY_ADDRESS");
            require(swapFactoryMap[swapIndex].getPair(input, output) != address(0), "O3SwapOECswapBridge: PAIR_NOT_EXIST");
            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(swapFactoryMap[swapIndex], input, output, swapCodeHash[swapIndex]));
            uint amountInput;
            uint amountOutput;
            { // scope to avoid stack too deep errors
            (uint reserve0, uint reserve1,) = pair.getReserves();
            (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
            amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(swapFactoryMap[swapIndex], output, path[i + 2], swapCodeHash[swapIndex]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function _cross(
        address fromAssetHash,
        uint64 toPoolId,
        uint64 toChainId,
        bytes memory toAssetHash,
        bytes memory toAddress,
        uint amount,
        uint minOutAmount,
        uint fee
    ) internal returns (bool) {
        // Allow `swapper contract` to transfer `amount` of `fromAssetHash` on belaof of this contract.
        TransferHelper.safeApprove(fromAssetHash, polySwapper, amount);

        bool result = ISwapper(polySwapper).swap{value: fee}(
            fromAssetHash,
            toPoolId,
            toChainId,
            toAssetHash,
            toAddress,
            amount,
            minOutAmount,
            fee,
            polySwapperId
        );
        require(result, "POLY CROSSCHAIN ERROR");

        return result;
    }

    receive() external payable { }

    function setPolySwapperId(uint _id) external onlyOwner {
        polySwapperId = _id;
    }

    function collect(address token) external {
        if (token == WOKT) {
            uint256 woktBalance = IERC20(token).balanceOf(address(this));
            if (woktBalance > 0) {
                IWOKT(WOKT).withdraw(woktBalance);
            }
            TransferHelper.safeTransferETH(owner(), address(this).balance);
        } else {
            TransferHelper.safeTransfer(token, owner(), IERC20(token).balanceOf(address(this)));
        }
    }

    function setAggregatorFee(uint _fee) external onlyOwner {
        aggregatorFee = _fee;
    }

    function setSwapFactory(uint index, address _factory) external onlyOwner {
        swapFactoryMap[index] = _factory;
    }

    function setSwapInitCodeHash(uint index, bytes32 _codeHash) external onlyOwner{
        swapCodeHash[index] = _codeHash;
    }

    function setPolySwapper(address _swapper) external onlyOwner {
        polySwapper = _swapper;
    }

    function setWOKT(address _wokt) external onlyOwner {
        WOKT = _wokt;
    }
}
