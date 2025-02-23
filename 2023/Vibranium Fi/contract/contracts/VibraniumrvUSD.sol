// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.17;

import "./RVUSD.sol";
import "./Governable.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "./AggregatorV3Interface.sol";
import "./Ireth.sol";
import "./VibStakingPool.sol";
import "./esVIBMinter.sol";
import "./ISwap.sol";

contract VibraniumrvUSD is RVUSD, Governable {
    uint256 public totalDepositedEther;
    uint256 public lastReportTime;
    uint256 public totalRVUSDCirculation;
    uint256 year = 86400 * 365;

    uint256 public mintFeeApy = 150;
    uint256 public safeCollateralRate = 160 * 1e18;
    uint256 public immutable badCollateralRate = 140 * 1e18;
    uint256 public redemptionFee = 50;
    uint8 public keeperRate = 1;

    mapping(address => uint256) public depositedEther;
    mapping(address => uint256) borrowed;
    mapping(address => bool) redemptionProvider;
    uint256 public feeStored;

    bool public initializer;

    Ireth reth;
    AggregatorV3Interface internal priceFeed;
    esVIBMinter public esvibMinter;
    VibStakingPool public serviceFeePool;
    address public vUSD;

    event DepositEther(
        address sponsor,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 timestamp
    );
    event WithdrawEther(
        address sponsor,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 timestamp
    );
    event Mint(
        address sponsor,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 timestamp
    );
    event Burn(
        address sponsor,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 timestamp
    );
    event LiquidationRecord(
        address provider,
        address keeper,
        address indexed onBehalfOf,
        uint256 rvusdamount,
        uint256 LiquidateEtherAmount,
        uint256 keeperReward,
        bool superLiquidation,
        uint256 timestamp
    );
    event LSDistribution(
        uint256 rETHAdded,
        uint256 payoutRVUSD,
        uint256 timestamp
    );
    
    event RedemptionProvider(address user, bool status);
    event RigidRedemption(
        address indexed caller,
        address indexed provider,
        uint256 rvusdAmount,
        uint256 etherAmount,
        uint256 timestamp
    );
    event FeeDistribution(
        address indexed feeAddress,
        uint256 feeAmount,
        uint256 timestamp
    );

    constructor(address _reth, address _priceFeed) {
        gov = msg.sender;
        reth = Ireth(_reth);
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    function initialize(address _vUSD) public {
        require(!initializer);
        vUSD = _vUSD;
        initializer = true;
    } 
    function setBorrowApy(uint256 newApy) external onlyGov {
        require(newApy <= 150, "Borrow APY > 1.5%");
        _saveReport();
        mintFeeApy = newApy;
    }

    /**
     * @notice  safeCollateralRate can be decided by DAO,starts at 160%
     */
    function setSafeCollateralRate(uint256 newRatio) external onlyGov {
        require(
            newRatio >= 160 * 1e18,
            "Safe CollateralRate > 160%"
        );
        safeCollateralRate = newRatio;
    }

    /**
     * @notice KeeperRate can be decided by DAO,1 means 1% of revenue
     */
    function setKeeperRate(uint8 newRate) external onlyGov {
        require(newRate <= 5, "Max Keeper reward is 5%");
        keeperRate = newRate;
    }

    /**
     * @notice DAO sets RedemptionFee, 100 means 1%
     */
    function setRedemptionFee(uint8 newFee) external onlyGov {
        require(newFee <= 500, "Max Redemption Fee is 5%");
        redemptionFee = newFee;
    }

    function setVibStakingPool(address addr) external onlyGov {
        serviceFeePool = VibStakingPool(addr);
    }

    function setESVIBMinter(address addr) external onlyGov {
        esvibMinter = esVIBMinter(addr);
    }

     /**
     * @notice User chooses to become a Redemption Provider
     */
    function becomeRedemptionProvider(bool _bool) external {
        esvibMinter.refreshReward(msg.sender);
        redemptionProvider[msg.sender] = _bool;
        emit RedemptionProvider(msg.sender, _bool);
    }
    /**
     * @notice Deposit rETH on behalf of an address, update the interest distribution and deposit record the this address, can mint RVUSD directly
     * Emits a `DepositEther` event.
     *
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `rETHamount` Must be higher than 0.
     * - `mintAmount` Send 0 if doesn't mint RVUSD
     * @dev Record the deposited rETH in the ratio of 1:1.
     */
    function depositrETHToMint(
        address onBehalfOf,
        uint256 rETHamount,
        uint256 mintAmount
    ) external {
        require(onBehalfOf != address(0) && rETHamount >= 5 * 1e17, "INPUT_WRONG");
        reth.transferFrom(msg.sender, address(this), rETHamount);

        totalDepositedEther += rETHamount;
        depositedEther[onBehalfOf] += rETHamount;
        if (mintAmount > 0) {
            _mintRVUSD(onBehalfOf, onBehalfOf, mintAmount);
        }
        emit DepositEther(msg.sender, onBehalfOf, rETHamount, block.timestamp);
    }

    /**
     * @notice Withdraw collateral assets to an address
     * Emits a `WithdrawEther` event.
     *
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0.
     *
     * @dev Withdraw rETH. Check user’s collateral rate after withdrawal, should be higher than `safeCollateralRate`
     */
    function withdraw(address onBehalfOf, uint256 amount) external {
        require(onBehalfOf != address(0) && amount > 0 && depositedEther[msg.sender] >= amount, "INPUT_WRONG");
        totalDepositedEther -= amount;
        depositedEther[msg.sender] -= amount;

        reth.transfer(onBehalfOf, amount);
        if (borrowed[msg.sender] > 0) {
            _checkHealth(msg.sender);
        }
        emit WithdrawEther(msg.sender, onBehalfOf, amount, block.timestamp);
    }

    /**
     * @notice The mint amount number of RVUSD is minted to the address
     * Emits a `Mint` event.
     *
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0. Individual mint amount shouldn't surpass 10% when the circulation reaches 10_000_000
     */
    function mint(address onBehalfOf, uint256 amount) public {
        require(onBehalfOf != address(0) && amount > 0 , "INPUT_WRONG");
        _mintRVUSD(msg.sender, onBehalfOf, amount);
        if (
            (borrowed[msg.sender] * 100) / totalSupply() > 10 &&
            totalSupply() > 10_000_000 * 1e18
        ) revert("Mint Amount > 10% of total circulation");
    }

    /**
     * @notice Burn the amount of RVUSD and payback the amount of minted RVUSD
     * Emits a `Burn` event.
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0.
     * @dev Calling the internal`_repay`function.
     */
    function burn(address onBehalfOf, uint256 amount) external {
        require(onBehalfOf != address(0), "BURN_ZERO_ADDRESS");
        _repay(msg.sender, onBehalfOf, amount);
    }

    /**
     * @notice When overallCollateralRate is above 150%, Keeper liquidates borrowers whose collateral rate is below badCollateralRate, using RVUSD provided by Liquidation Provider.
     *
     * Requirements:
     * - onBehalfOf Collateral Rate should be below badCollateralRate
     * - etherAmount should be less than 50% of collateral
     * - provider should authorize Vibranium to utilize RVUSD
     * @dev After liquidation, borrower's debt is reduced by etherAmount * etherPrice, collateral is reduced by the etherAmount corresponding to 110% of the value. Keeper gets keeperRate / 110 of Liquidation Reward and Liquidator gets the remaining rETH.
     */
    function liquidation(
        address provider,
        address onBehalfOf,
        uint256 etherAmount
    ) external {
        uint256 etherPrice = _etherPrice();
        uint256 onBehalfOfCollateralRate = (depositedEther[onBehalfOf] *
            etherPrice *
            100) / borrowed[onBehalfOf];
        require(
            onBehalfOfCollateralRate < badCollateralRate,
            "Borrowers collateral rate should below badCollateralRate"
        );

        require(
            etherAmount * 2 <= depositedEther[onBehalfOf],
            "a max of 50% collateral can be liquidated"
        );
        uint256 rvusdAmount = (etherAmount * etherPrice) / 1e18;

        _repay(provider, onBehalfOf, rvusdAmount);
        uint256 reducedEther = (etherAmount * 11) / 10;
        totalDepositedEther -= reducedEther;
        depositedEther[onBehalfOf] -= reducedEther;
        uint256 reward2keeper;
        if (provider == msg.sender) {
            reth.transfer(msg.sender, reducedEther);
        } else {
            reward2keeper = (reducedEther * keeperRate) / 110;
            reth.transfer(provider, reducedEther - reward2keeper);
            reth.transfer(msg.sender, reward2keeper);
        }
        emit LiquidationRecord(
            provider,
            msg.sender,
            onBehalfOf,
            rvusdAmount,
            reducedEther,
            reward2keeper,
            false,
            block.timestamp
        );
    }

    /**
     * @notice When overallCollateralRate is below badCollateralRate, borrowers with collateralRate below 125% could be fully liquidated.
     * Emits a `LiquidationRecord` event.
     *
     * Requirements:
     * - Current overallCollateralRate should be below badCollateralRate
     * - `onBehalfOf`collateralRate should be below 125%
     * @dev After Liquidation, borrower's debt is reduced by etherAmount * etherPrice, deposit is reduced by etherAmount * borrower's collateralRate. Keeper gets a liquidation reward of `keeperRate / borrower's collateralRate
     */
    function superLiquidation(
        address provider,
        address onBehalfOf,
        uint256 etherAmount
    ) external {
        uint256 etherPrice = _etherPrice();
        require(
            (totalDepositedEther * etherPrice * 100) / totalSupply() <
                badCollateralRate,
            "overallCollateralRate > 150%"
        );
        uint256 onBehalfOfCollateralRate = (depositedEther[onBehalfOf] *
            etherPrice *
            100) / borrowed[onBehalfOf];
        require(
            onBehalfOfCollateralRate < 125 * 1e18,
            "borrowers collateralRate > 125%"
        );
        require(
            etherAmount <= depositedEther[onBehalfOf],
            "total of collateral can be liquidated at most"
        );
        uint256 rvusdAmount = (etherAmount * etherPrice) / 1e18;
        if (onBehalfOfCollateralRate >= 1e20) {
            rvusdAmount = (rvusdAmount * 1e20) / onBehalfOfCollateralRate;
        }
        require(
            allowance(provider, address(this)) >= rvusdAmount,
            "provider should authorize to provide liquidation RVUSD"
        );

        _repay(provider, onBehalfOf, rvusdAmount);

        totalDepositedEther -= etherAmount;
        depositedEther[onBehalfOf] -= etherAmount;
        uint256 reward2keeper;
        if (
            msg.sender != provider &&
            onBehalfOfCollateralRate >= 1e20 + keeperRate * 1e18
        ) {
            reward2keeper =
                ((etherAmount * keeperRate) * 1e18) /
                onBehalfOfCollateralRate;
            reth.transfer(msg.sender, reward2keeper);
        }
        reth.transfer(provider, etherAmount - reward2keeper);

        emit LiquidationRecord(
            provider,
            msg.sender,
            onBehalfOf,
            rvusdAmount,
            etherAmount,
            reward2keeper,
            true,
            block.timestamp
        );
    }

    /**
     * @notice When rETH balance increases through LSD or other reasons, the excess income is sold for RVUSD, allocated to RVUSD holders through rebase mechanism.
     * Emits a `LSDistribution` event.
     *
     * *Requirements:
     * - rETH balance in the contract cannot be less than totalDepositedEther after exchange.
     * @dev Income is used to cover accumulated Service Fee first.
     */
    function excessIncomeDistribution(uint256 payAmount) external {
        uint256 payoutEther = (payAmount * 1e18) / _etherPrice();
        require(
            payoutEther <=
                reth.balanceOf(address(this)) - totalDepositedEther &&
                payoutEther > 0,
            "Only LSD excess income can be exchanged"
        );

        uint256 income = feeStored + _newFee();

        if (payAmount > income) {
            _transfer(msg.sender, address(serviceFeePool), income);
            serviceFeePool.notifyRewardAmount(income);

            uint256 sharesAmount = getSharesByMintedVUSD(payAmount - income);
            if (sharesAmount == 0) {
                //RVUSD totalSupply is 0: assume that shares correspond to RVUSD 1-to-1
                sharesAmount = payAmount - income;
            }
            //Income is distributed to VIB staker.
            _burnShares(msg.sender, sharesAmount);
            feeStored = 0;
            emit FeeDistribution(
                address(serviceFeePool),
                income,
                block.timestamp
            );
        } else {
            _transfer(msg.sender, address(serviceFeePool), payAmount);
            serviceFeePool.notifyRewardAmount(payAmount);
            feeStored = income - payAmount;
            emit FeeDistribution(
                address(serviceFeePool),
                payAmount,
                block.timestamp
            );
        }

        lastReportTime = block.timestamp;
        reth.transfer(msg.sender, payoutEther);

        emit LSDistribution(payoutEther, payAmount, block.timestamp);
    }

    /**
     * @notice Choose a Redemption Provider, Rigid Redeem `rvusdAmount` of RVUSD and get 1:1 value of rETH
     * Emits a `RigidRedemption` event.
     *
     * *Requirements:
     * - `provider` must be a Redemption Provider
     * - `provider`debt must equal to or above`rvusdAmount`
     * @dev Service Fee for rigidRedemption `redemptionFee` is set to 0.5% by default, can be revised by DAO.
     */
    function rigidRedemption(address provider, uint256 rvusdAmount) external {
        uint256 etherPrice = _etherPrice();
        uint256 providerCollateralRate = (depositedEther[provider] *
            etherPrice *
            100) / borrowed[provider];
        require(
            !redemptionProvider[provider] && borrowed[provider] >= rvusdAmount && providerCollateralRate >= 100 * 1e18,
            "provider's collateral rate should more than 100%"
        );
        _repay(msg.sender, provider, rvusdAmount);
        uint256 etherAmount = (((rvusdAmount * 1e18) / etherPrice) *
            (10000 - redemptionFee)) / 10000;
        depositedEther[provider] -= etherAmount;
        totalDepositedEther -= etherAmount;
        reth.transfer(msg.sender, etherAmount);
        emit RigidRedemption(
            msg.sender,
            provider,
            rvusdAmount,
            etherAmount,
            block.timestamp
        );
    }

    /**
     * @dev Refresh VIB reward before adding providers debt. Refresh Vibranium generated service fee before adding totalRVUSDCirculation. Check providers collateralRate cannot below `safeCollateralRate`after minting.
     */
    function _mintRVUSD(
        address _provider,
        address _onBehalfOf,
        uint256 _amount
    ) internal {
        uint256 sharesAmount = getSharesByMintedVUSD(_amount);
        if (sharesAmount == 0) {
            //RVUSD totalSupply is 0: assume that shares correspond to RVUSD 1-to-1
            sharesAmount = _amount;
        }
        esvibMinter.refreshReward(_provider);
        borrowed[_provider] += _amount;

        _mintShares(_onBehalfOf, sharesAmount);

        _saveReport();
        totalRVUSDCirculation += _amount;
        _checkHealth(_provider);
        emit Mint(msg.sender, _onBehalfOf, _amount, block.timestamp);
    }

    /**
     * @notice Burn _provideramount RVUSD to payback minted RVUSD for _onBehalfOf.
     *
     * @dev Refresh VIB reward before reducing providers debt. Refresh Vibranium generated service fee before reducing totalRVUSDCirculation.
     */
    function _repay(
        address _provider,
        address _onBehalfOf,
        uint256 _amount
    ) internal {
        require(
            borrowed[_onBehalfOf] >= _amount,
            "Repaying Amount Surpasses Borrowing Amount"
        );

        uint256 sharesAmount = getSharesByMintedVUSD(_amount);
        _burnShares(_provider, sharesAmount);

        esvibMinter.refreshReward(_onBehalfOf);

        borrowed[_onBehalfOf] -= _amount;
        _saveReport();
        totalRVUSDCirculation -= _amount;

        emit Burn(_provider, _onBehalfOf, _amount, block.timestamp);
    }

    function _saveReport() internal {
        feeStored += _newFee();
        lastReportTime = block.timestamp;
    }

    function mintSwap(address _account, uint _amount) external {
        require(msg.sender == vUSD, "INPUT_WRONG");
        uint256 sharesAmount = getSharesByMintedVUSD(_amount);
        if (sharesAmount == 0) {
            //VUSD totalSupply is 0: assume that shares correspond to VUSD 1-to-1
            sharesAmount = _amount;
        }
        esvibMinter.refreshReward(_account);
        _mintShares(_account, sharesAmount);
        _saveReport();
        totalRVUSDCirculation += _amount;
    }

    function swap(uint _amount) external{
        uint256 sharesAmount = getSharesByMintedVUSD(_amount);
        _burnShares(msg.sender, sharesAmount);
        esvibMinter.refreshReward(msg.sender);
        _saveReport();
        totalRVUSDCirculation -= _amount;
        ISwap(vUSD).mintSwap(msg.sender, _amount);
        emit Burn(msg.sender, msg.sender, _amount, block.timestamp);
    }

    /**
     * @dev Get USD value of current collateral asset and minted RVUSD through price oracle / Collateral asset USD value must higher than safe Collateral Rate.
     */
    function _checkHealth(address user) internal {
        if (
            ((depositedEther[user] * _etherPrice() * 100) / borrowed[user]) <
            safeCollateralRate
        ) revert("collateralRate is Below safeCollateralRate");
    }

    /**
     * @dev Return USD value of current ETH through Liquity PriceFeed Contract.
     * https://etherscan.io/address/0x4c517D4e2C851CA76d7eC94B805269Df0f2201De#code
     */
    function _etherPrice() internal returns (uint256) {
         // prettier-ignore
        (
            /* uint80 roundID */,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();
        return uint256(price) * 1e10;
    }

    function _newFee() internal view returns (uint256) {
        return
            (totalRVUSDCirculation *
                mintFeeApy *
                (block.timestamp - lastReportTime)) /
            year /
            10000;
    }

    /**
     * @dev total circulation of RVUSD
     */
    function _getTotalMintedVUSD() internal view override returns (uint256) {
        return totalRVUSDCirculation;
    }

    function getBorrowedOf(address user) external view returns (uint256) {
        return borrowed[user];
    }

    function isRedemptionProvider(address user) external view returns (bool) {
        return redemptionProvider[user];
    }

}