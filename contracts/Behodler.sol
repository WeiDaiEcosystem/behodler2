// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "./openzeppelin/Ownable.sol";
import "./Scarcity.sol";
import "./facades/LachesisLike.sol";
import "./facades/Burnable.sol";
import "./openzeppelin/SafeMath.sol";
import "./openzeppelin/IERC20.sol";
import "./flashLoans/FlashLoanReceiver.sol";
import "./flashLoans/FlashLoanArbiter.sol";
import "./WETH10.sol";

library AddressBalanceCheck {
    function tokenBalance(address token) public view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function shiftedBalance(address token, uint256 factor)
        public
        view
        returns (uint256)
    {
        return IERC20(token).balanceOf(address(this)) / factor;
    }

    function transferIn(
        address token,
        address sender,
        uint256 value
    ) public {
        IERC20(token).transferFrom(sender, address(this), value);
    }

    function transferOut(
        address token,
        address recipient,
        uint256 value
    ) public {
        IERC20(token).transfer(recipient, value);
    }
}

/*To following code is sourced from the ABDK library for assistance in dealing with precision logarithms in Ethereum.
 * ABDK Math 64.64 Smart Contract Library.  Copyright © 2019 by ABDK Consulting.
 * Author: Mikhail Vladimirov <mikhail.vladimirov@gmail.com>
 * Source: https://github.com/abdk-consulting/abdk-libraries-solidity/blob/master/ABDKMath64x64.sol#L366
 */
library ABDK {
    /*
     * Minimum value signed 64.64-bit fixed point number may have.
     */
    int128 private constant MIN_64x64 = -0x80000000000000000000000000000000;

    /*
     * Maximum value signed 64.64-bit fixed point number may have.
     */
    int128 private constant MAX_64x64 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /**
     * Convert unsigned 256-bit integer number into signed 64.64-bit fixed point
     * number.  Revert on overflow.
     *
     * @param x unsigned 256-bit integer number
     * @return signed 64.64-bit fixed point number
     */
    function fromUInt(uint256 x) internal pure returns (int128) {
        require(x <= 0x7FFFFFFFFFFFFFFF);
        return int128(x << 64);
    }

    /**
     * Calculate x + y.  Revert on overflow.
     *
     * @param x signed 64.64-bit fixed point number
     * @param y signed 64.64-bit fixed point number
     * @return signed 64.64-bit fixed point number
     */
    function add(int128 x, int128 y) internal pure returns (int128) {
        int256 result = int256(x) + y;
        require(result >= MIN_64x64 && result <= MAX_64x64);
        return int128(result);
    }

    /**
     * Calculate binary logarithm of x.  Revert if x <= 0.
     *
     * @param x signed 64.64-bit fixed point number
     * @return signed 64.64-bit fixed point number
     */
    function log_2(uint256 x) internal pure returns (uint256) {
        require(x > 0);

        uint256 msb = 0;
        uint256 xc = x;
        if (xc >= 0x10000000000000000) {
            xc >>= 64;
            msb += 64;
        }
        if (xc >= 0x100000000) {
            xc >>= 32;
            msb += 32;
        }
        if (xc >= 0x10000) {
            xc >>= 16;
            msb += 16;
        }
        if (xc >= 0x100) {
            xc >>= 8;
            msb += 8;
        }
        if (xc >= 0x10) {
            xc >>= 4;
            msb += 4;
        }
        if (xc >= 0x4) {
            xc >>= 2;
            msb += 2;
        }
        if (xc >= 0x2) msb += 1; // No need to shift xc anymore

        uint256 result = (msb - 64) << 64;
        uint256 ux = uint256(x) << uint256(127 - msb);
        for (uint256 bit = 0x8000000000000000; bit > 0; bit >>= 1) {
            ux *= ux;
            uint256 b = ux >> 255;
            ux >>= 127 + b;
            result += bit * b;
        }

        return result;
    }
}

/*
	Behodler orchestrates trades using an omnischedule bonding curve.
	The name is inspired by the Beholder of D&D, a monster with multiple arms ending in eyes peering in all directions.
	The Behodler is a smart contract that can see the prices of all tokens simultaneously without need for composition or delay.
	The hodl part of Behodler refers to the fact that with every trade of a token pair, the liquidity pool of each token held by Behodler increases

    Behodler 1 performed square root calculations which are gas intensive for fixed point arithmetic algorithms.
    To save gas, Behodler2 never performs square root calculations. It just checks the numbers passed in by the user and reverts if needs be.
    This techique is called invariant checking and offloads maximum calculation to clients while guaranteeing no cheating is possible.
    In Behodler 1 some operations were duplicated. For instance, a swap was a scarcity purchase followed by a scarcity sale. Instead, cutting out
    the middle scarcity allows the factor scaling to be dropped altogether.

    By bringing Scarcity, Janus, Kharon and Behodler together in one contract, Behodler 2 avoids the EXT_CALL gas fees and can take gas saving shortcuts with Scarcity
    transfers. The drawback to this approach is less flexibility with fees in the way that Kharon allowed.

    Behodler 2 now has Flashloan support. Instead of charging a liquidity growing fee, Behodler 2 requires the user fulfil some requirement
    such as holding an NFT or staking Scarcity. This allows for zero fee flash loans that are front runner resistant and
    allows a secondary flashloan market to evolve.
 */
contract Behodler is Scarcity {
    using SafeMath for uint256;
    using ABDK for int128;
    using ABDK for uint256;
    using AddressBalanceCheck for address;

    event LiquidityAdded(
        address sender,
        address token,
        uint256 tokenValue,
        uint256 scx
    );
    event LiquidityWithdrawn(
        address recipient,
        address token,
        uint256 tokenValue,
        uint256 scx
    );
    event Swap(
        address sender,
        address inputToken,
        address outputToken,
        uint256 inputValue,
        uint256 outputValue
    );

    struct WeidaiTokens {
        address dai;
        address reserve;
        address weiDai;
    }

    struct PrecisionFactors {
        uint8 swapPrecisionFactor;
        uint8 maxLiquidityExit; //percentage as number between 1 and 100
    }

    WeidaiTokens WD;
    PrecisionFactors safetyParameters;
    address public Weth;
    address public Lachesis;
    address pyroTokenLiquidityReceiver;
    FlashLoanArbiter public arbiter;
    address private inputSender;
    bool[3] unlocked;

    constructor() {
        safetyParameters.swapPrecisionFactor = 30; //approximately a billion
        safetyParameters.maxLiquidityExit = 90;
        for (uint8 i = 0; i < 3; i++) unlocked[i] = true;
    }

    function setSafetParameters(
        uint8 swapPrecisionFactor,
        uint8 maxLiquidityExit
    ) external onlyOwner {
        safetyParameters.swapPrecisionFactor = swapPrecisionFactor;
        safetyParameters.maxLiquidityExit = maxLiquidityExit;
    }

    function getMaxLiquidityExit() public view returns (uint8) {
        return safetyParameters.maxLiquidityExit;
    }

    function seed(
        address weth,
        address lachesis,
        address flashLoanArbiter,
        address _pyroTokenLiquidityReceiver,
        address weidaiReserve,
        address dai,
        address weiDai
    ) external onlyOwner {
        Weth = weth;
        Lachesis = lachesis;
        arbiter = FlashLoanArbiter(flashLoanArbiter);
        pyroTokenLiquidityReceiver = _pyroTokenLiquidityReceiver;
        WD.reserve = weidaiReserve;
        WD.dai = dai;
        WD.weiDai = weiDai;
    }

    //Logarithmic growth can get quite flat beyond the first chunk. We divide input amounts by
    uint256 public constant MIN_LIQUIDITY = 1e12;

    mapping(address => bool) public tokenBurnable;
    mapping(address => bool) public validTokens;
    mapping(address => bool) public whiteListUsers; // can trade on tokens that are disabled

    modifier onlyLachesis {
        require(msg.sender == Lachesis);
        _;
    }

    modifier onlyValidToken(address token) {
        require(
            whiteListUsers[msg.sender] ||
                validTokens[token] ||
                (token != address(0) && token == Weth),
            "BEHODLER: token invalid"
        );
        _;
    }

    modifier determineSender(address inputToken) {
        if (msg.value > 0) {
            require(
                inputToken == Weth,
                "BEHODLER: Eth only valid for Weth trades."
            );
            inputSender = address(this);
        } else {
            inputSender = msg.sender;
        }
        _;
    }

    enum Slot {Swap, Add, Withdraw}

    modifier lock(Slot slot) {
        uint256 index = uint256(slot);
        require(unlocked[index], "BEHODLER: Reentrancy guard active.");
        unlocked[index] = false;
        _;
        unlocked[index] = true;
    }

    /*
   Let config.burnFee be b.
    Let F = 1-b
    Let input token be I and Output token be O
    _i is initial and _f is final. Eg. I_i is initial input token balance
    The swap equation, when simplified, is given by
    √F(√I_f - √I_i) = (√O_i - √O_f)/(F)
    However, the gradient of square root becomes untenable when
    the value of tokens diverge too much. The gradient favours the addition of low
    value tokens disportionately. A gradient that favours tokens equally is given by
    a log. The lowest gas implementation is base 2.
    The new swap equation is thus
    log(I_f) - log(I_i) = log(O_i) - log(O_f)

    Technical note on ETH handling: we don't duplicate functions for accepting Eth as an input. Instead we wrap on receipt
    and apply a reentrancy guard. The determineSender modifier fixes an isse in Behodler 1 which required the user to approve
    both sending and receiving Eth because of the nature of Weth deposit and withdraw functionality.
 */
    function swap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    )
        external
        payable
        determineSender(inputToken)
        onlyValidToken(inputToken)
        lock(Slot.Swap)
        returns (bool success)
    {
        uint256 initialInputBalance = inputToken.tokenBalance();
        if (inputToken == Weth) {
            if (IERC20(Weth).balanceOf(msg.sender) >= inputAmount) {
                Weth.transferIn(msg.sender, inputAmount);
            } else {
                require(
                    msg.value == inputAmount,
                    "BEHODLER: Insufficient Ether sent"
                );
                IWETH10(Weth).deposit{value: msg.value}();
            }
        } else {
            inputToken.transferIn(inputSender, inputAmount);
        }

        uint256 netInputAmount =
            inputAmount.sub(burnToken(inputToken, inputAmount));
        uint256 initialOutputBalance = outputToken.tokenBalance();
        require(
            outputAmount.mul(100).div(initialOutputBalance) <=
                safetyParameters.maxLiquidityExit,
            "BEHODLER: liquidity withdrawal too large."
        );
        uint256 finalInputBalance = initialInputBalance.add(netInputAmount);
        uint256 finalOutputBalance = initialOutputBalance.sub(outputAmount);

        //new scope to avoid stack too deep errors.
        {
            //if the input balance after adding input liquidity is 1073741824 bigger than the initial balance, we revert.
            uint256 inputRatio =
                (initialInputBalance << safetyParameters.swapPrecisionFactor)
                    .div(finalInputBalance);
            uint256 outputRatio =
                (finalOutputBalance << safetyParameters.swapPrecisionFactor)
                    .div(initialOutputBalance);

            require(
                inputRatio != 0 && inputRatio == outputRatio,
                "BEHODLER: swap invariant."
            );
        }

        require(
            finalOutputBalance >= MIN_LIQUIDITY,
            "BEHODLER: min liquidity."
        );

        if (outputToken == Weth) {
            address payable sender = msg.sender;
            IWETH10(Weth).withdrawTo(sender, outputAmount);
        } else {
            outputToken.transferOut(msg.sender, outputAmount);
        }

        emit Swap(
            msg.sender,
            inputToken,
            outputToken,
            inputAmount,
            outputAmount
        );
        success = true;
    }

    /*
        ΔSCX = log(FinalBalance) - log(InitialBalance)

        The choice of base for the log isn't relevant from a mathematical point of view
        but from a computational point of view, base 2 is the cheapest for obvious reasons.
        "What I told you was true, from a certain point of view." - Obi-Wan Kenobi
     */
    function addLiquidity(address inputToken, uint256 amount)
        external
        payable
        determineSender(inputToken)
        onlyValidToken(inputToken)
        lock(Slot.Add)
        returns (uint256 deltaSCX)
    {
        uint256 initialBalance =
            uint256(inputToken.shiftedBalance(MIN_LIQUIDITY).fromUInt());
        if (inputToken == Weth) {
            if (IERC20(Weth).balanceOf(msg.sender) >= amount) {
                Weth.transferIn(msg.sender, amount);
            } else {
                require(
                    msg.value == amount,
                    "BEHODLER: Insufficient Ether sent"
                );
                IWETH10(Weth).deposit{value: msg.value}();
            }
        } else {
            inputToken.transferIn(inputSender, amount);
        }
        uint256 netInputAmount =
            uint256(
                amount
                    .sub(burnToken(inputToken, amount))
                    .div(MIN_LIQUIDITY)
                    .fromUInt()
            );

        uint256 finalBalance = uint256(initialBalance.add(netInputAmount));
        require(
            uint256(finalBalance) >= MIN_LIQUIDITY,
            "BEHODLER: min liquidity."
        );
        deltaSCX = uint256(
            finalBalance.log_2() -
                (initialBalance > 1 ? initialBalance.log_2() : 0)
        );
        mint(msg.sender, deltaSCX);
        emit LiquidityAdded(msg.sender, inputToken, amount, deltaSCX);
    }

    /*
        ΔSCX =  log(InitialBalance) - log(FinalBalance)
        tokensToRelease = InitialBalance -FinalBalance
        =>FinalBalance =  InitialBalance - tokensToRelease
        Then apply logs and deduct SCX from msg.sender

        The choice of base for the log isn't relevant from a mathematical point of view
        but from a computational point of view, base 2 is the cheapest for obvious reasons.
        "From my point of view, the Jedi are evil" - Darth Vader
     */
    function withdrawLiquidity(address outputToken, uint256 tokensToRelease)
        external
        payable
        determineSender(outputToken)
        onlyValidToken(outputToken)
        lock(Slot.Withdraw)
        returns (uint256 deltaSCX)
    {
        uint256 initialBalance = outputToken.tokenBalance();
        uint256 finalBalance = initialBalance.sub(tokensToRelease);
        require(finalBalance > MIN_LIQUIDITY, "BEHODLER: min liquidity");
        require(
            tokensToRelease.mul(100).div(initialBalance) <=
                safetyParameters.maxLiquidityExit,
            "BEHODLER: liquidity withdrawal too large."
        );

        uint256 logInitial = initialBalance.log_2();
        uint256 logFinal = finalBalance.log_2();

        deltaSCX = logInitial - (finalBalance > 1 ? logFinal : 0);
        uint256 scxBalance = balances[msg.sender];

        if (deltaSCX > scxBalance) {
            //rounding errors in scx creation and destruction. Err on the side of holders
            uint256 difference = deltaSCX - scxBalance;
            if ((difference * 10000) / deltaSCX == 0) deltaSCX = scxBalance;
        }
        burn(msg.sender, deltaSCX);

        if (outputToken == Weth) {
            address payable sender = msg.sender;
            IWETH10(Weth).withdrawTo(sender, tokensToRelease);
        } else {
            outputToken.transferOut(msg.sender, tokensToRelease);
        }
        emit LiquidityWithdrawn(
            msg.sender,
            outputToken,
            tokensToRelease,
            deltaSCX
        );
    }

    /*
        ΔSCX =  log(InitialBalance) - log(FinalBalance)
        tokensToRelease = InitialBalance -FinalBalance
        =>FinalBalance =  InitialBalance - tokensToRelease
        Then apply logs and deduct SCX from msg.sender

        The choice of base for the log isn't relevant from a mathematical point of view
        but from a computational point of view, base 2 is the cheapest for obvious reasons.
        "From my point of view, the Jedi are evil" - Darth Vader
     */
    function withdrawLiquidityFindSCX(
        address outputToken,
        uint256 tokensToRelease,
        uint256 scx,
        uint256 passes
    ) external view returns (uint256) {
        uint256 upperBoundary = outputToken.tokenBalance();
        uint256 lowerBoundary = 0;

        for (uint256 i = 0; i < passes; i++) {
            uint256 initialBalance = outputToken.tokenBalance();
            uint256 finalBalance = initialBalance.sub(tokensToRelease);

            uint256 logInitial = initialBalance.log_2();
            uint256 logFinal = finalBalance.log_2();

            int256 deltaSCX =
                int256(logInitial - (finalBalance > 1 ? logFinal : 0));
            int256 difference = int256(scx) - deltaSCX;
            // if (difference**2 < 1000000) return tokensToRelease;
            if (difference == 0) return tokensToRelease;
            if (difference < 0) {
                // too many tokens requested
                upperBoundary = tokensToRelease - 1;
            } else {
                //too few tokens requested
                lowerBoundary = tokensToRelease + 1;
            }
            tokensToRelease =
                ((upperBoundary - lowerBoundary) / 2) +
                lowerBoundary; //bitshift
            tokensToRelease = tokensToRelease > initialBalance
                ? initialBalance
                : tokensToRelease;
        }
        return tokensToRelease;
    }

    //TODO: possibly comply with the flash loan standard https://eips.ethereum.org/EIPS/eip-3156
    // - however, the more I reflect on this, the less keen I am due to gas and simplicity
    //example: a user must hold 10% of SCX total supply or user must hold an NFT
    //The initial arbiter will have no constraints.
    //The flashloan system on behodler is inverted. Instead of being able to borrow any individual token,
    //the borrower asks for SCX. Theoretically you can borrow more SCX than currently exists so long
    //as you can think of a clever way to pay it back.
    //Note: Borrower doesn't have to send scarcity back, they just need to have high enough balance.
    function grantFlashLoan(uint256 amount, address flashLoanContract)
        external
    {
        require(
            arbiter.canBorrow(msg.sender),
            "BEHODLER: cannot borrow flashloan"
        );
        balances[flashLoanContract] = balances[flashLoanContract].add(amount);
        FlashLoanReceiver(flashLoanContract).execute(msg.sender); 
        balances[flashLoanContract] = balances[flashLoanContract].sub(
            amount,
            "BEHODLER: Flashloan repayment failed"
        );
    }

    //useful for when we want the ability to add tokens without trading. For instance, the initial liquidity queueing event.
    function setWhiteListUser(address user, bool whiteList) external onlyOwner {
        whiteListUsers[user] = whiteList;
    }

    function burnToken(address token, uint256 amount)
        private
        returns (uint256 burnt)
    {
        if (token == WD.weiDai) {
            burnt = applyBurnFee(token, amount, true);
        } else if (tokenBurnable[token])
            burnt = applyBurnFee(token, amount, false);
        else if (token == WD.dai) {
            burnt = config.burnFee.mul(amount).div(1000);
            token.transferOut(WD.reserve, burnt);
        } else {
            burnt = config.burnFee.mul(amount).div(1000);
            token.transferOut(pyroTokenLiquidityReceiver, burnt);
        }
    }

    function setValidToken(
        address token,
        bool valid,
        bool burnable
    ) external onlyLachesis {
        validTokens[token] = valid;
        tokenBurnable[token] = burnable;
    }
}
