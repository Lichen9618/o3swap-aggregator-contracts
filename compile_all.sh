#!/bin/bash

declare -a contracts=(
    "O3SwapETHUniswapBridge.sol"
    "O3SwapBSCPancakeBridge.sol"
    "O3SwapHecoMdexBridge.sol"
)

for contract in ${contracts[@]}; do
    solPath="./contracts/"
    solPath+=$contract
    printf "%-26s " "$contract"
    solc $solPath --bin --abi --evm-version istanbul --optimize --optimize-runs 200 -o ./build/contracts --allow-paths . --overwrite
done
