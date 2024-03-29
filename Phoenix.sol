// SPDX-License-Identifier: MIT
pragma solidity = 0.8.12;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

interface IBEP20 {
    function totalSupply() view external returns (uint256);
    function balanceOf(address account) view external returns (uint256);
    function allowance(address owner, address spender) view external returns (uint256);

    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IPhoenixNFT {
    function getAccountReflectionPerc(address addr) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);
}

contract Phoenix is IBEP20 {
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    uint256 private _minTokensToAddLiquidity;
    uint256 private _minBnbToBuyback;

    IUniswapV2Router02 private immutable _uniswapV2Router;
    address private immutable _uniswapV2Pair;

    bool private _inSwapAndLiquify;
    bool private _inSwapTokenForETH;
    address private _owner;
    address private _miner;

    IPhoenixNFT private _NFTContract;
    
    bool private _launched;
    uint256 private _launchedAt;
    uint256 private _deadBlocks;

    uint256 public totalHoldersFeesAmount = 0;
    uint256 public totalBuyBackFeesAmount = 0;
    uint256 public totalLiquidityFeesAmount = 0;
    uint8 private _holdersFees = 3;
    uint8 private _buyBackFees = 3;
    uint8 private _liquidityFees = 2;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    modifier onlyOwner() {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }
    modifier onlyMiner() {
        require(_miner == msg.sender, "Ownable: caller is not the miner");
        _;
    }

    uint8 private calledTimes = 0;
    modifier onlyOnce() {
        require(calledTimes == 0, "onlyOnce: function can be called only once");
        _;
        calledTimes ++;
    }

    modifier lockSwapTokenForETH {
        _inSwapTokenForETH = true;
        _;
        _inSwapTokenForETH = false;

    }
    modifier lockTheSwap {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;

    }

    constructor(address multiSignWallet, address NFTaddr) {
        _name = "Phoenix";
        _symbol = "FNX";
        _totalSupply = 10**9 * 10**decimals();
        _minTokensToAddLiquidity = 5**6 * 10**decimals();
        _minBnbToBuyback = 10 * 10**18;    
        _launched = false;

        _owner = multiSignWallet;
        _NFTContract = IPhoenixNFT(NFTaddr);
        _balances[_owner] = _totalSupply;
        emit Transfer(address(0), _owner, _totalSupply);

        // MAINNET: 0x10ED43C718714eb63d5aA57B78B54704E256024E
        _uniswapV2Router = IUniswapV2Router02(0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3);
        _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this), _uniswapV2Router.WETH());
    }

    function approvePrivateSale(address privateSale) external onlyOwner returns (bool) {
        _approve(msg.sender, privateSale, type(uint256).max);
        return true;
    }

    function setMiner(address miner) external onlyOnce returns (bool) {
        _miner = miner;
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transferFeesCheck(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = allowance(from, msg.sender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "BEP20: insufficient allowance");
            unchecked {
                _approve(from, msg.sender, currentAllowance - amount);
            }
        }
    
        _transferFeesCheck(from, to, amount);
        return true;
    }

    function setMinBnbToBuyback(uint256 value) external onlyOwner {
        _minBnbToBuyback = value;
    }

    function distributeNFTFees(uint256 amount) external onlyMiner {
        for(uint16 i = 0; i < _NFTContract.totalSupply(); i++){
            address holder = _NFTContract.ownerOf(i);
            uint256 reflection = _NFTContract.getAccountReflectionPerc(holder);

            _balances[holder] += amount * reflection / 1000;
        }
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }


    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }
    
    function decimals() public pure returns (uint8) {
        return 2;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function balanceOf(address account) public view override returns (uint256) {
        if(account == address(this) || account == _uniswapV2Pair || account == address(0)){
            return _balances[account];
        }

        uint256 accountPerc = _balances[account] * 1000 / _totalSupply;
        return _balances[account] + (totalHoldersFeesAmount * accountPerc / 1000);
    }

    function totalSupply() external view virtual override returns (uint256) {
        return _totalSupply;
    }

    function launch(uint256 deadBlocks) external onlyOwner {
        require(_launched == false);
        _launched = true;
        _launchedAt = block.number;
        _deadBlocks = deadBlocks;
    }

    function _transferFeesCheck(address from, address to, uint256 amount) private {
        uint256 holdersFeeValue = 0;
        uint256 buyBackValue = 0;
        uint256 liquidityFeeValue = 0;

        if(_isSniper(from, amount))
            return;

        if (!(_inSwapAndLiquify || _inSwapTokenForETH) && from != _owner && to != _owner){       
            holdersFeeValue = amount * _holdersFees / 100;
            buyBackValue = amount * _buyBackFees / 100;
            liquidityFeeValue = amount * _liquidityFees / 100;
            totalHoldersFeesAmount += holdersFeeValue;
            totalBuyBackFeesAmount += buyBackValue;
            totalLiquidityFeesAmount += liquidityFeeValue;
            
            // BUG: why cannot be from equals to uniswap pair? Check it out:
            // https://dashboard.tenderly.co/tx/bsc-testnet/0x47f9495843ba7305cc2b9d76f3ff5da4f12eee215ac184ef583738840197294a
            // https://dashboard.tenderly.co/tx/bsc-testnet/0xe92bdfcd1ddab59d909e47d40f25c200e5c90801e6297aff75720f6df5d37aa4
            if (from != _uniswapV2Pair) {
                if(totalLiquidityFeesAmount >= _minTokensToAddLiquidity){
                    if(_swapAndLiquify(totalLiquidityFeesAmount))
                        totalLiquidityFeesAmount = 0;
                }

                if(IBEP20(_uniswapV2Router.WETH()).balanceOf(_uniswapV2Pair) < _minBnbToBuyback)
                    _buyBackAndBurn();

                if(_swapTokensForEth(totalBuyBackFeesAmount))
                    totalBuyBackFeesAmount = 0;
            }   

            _transfer(from, address(this), holdersFeeValue + buyBackValue + liquidityFeeValue);
            _transfer(from, to, amount - holdersFeeValue - buyBackValue - liquidityFeeValue);
            emit Transfer(from, to, amount - holdersFeeValue - buyBackValue - liquidityFeeValue);
        }
        else{
            _transfer(from, to, amount);
            emit Transfer(from, to, amount);
        }
    }

    function _swapAndLiquify(uint256 tokenAmount) private lockTheSwap returns(bool){
        uint256 half;
        uint256 otherHalf;
        uint256 newBalance;

        unchecked{
            half = tokenAmount / 2;
            otherHalf = tokenAmount - half;
        }

        uint256 initialBalance = address(this).balance;
        if (_swapTokensForEth(half)){
            unchecked{
                newBalance = address(this).balance - initialBalance;
            }

            return _addLiquidity(otherHalf, newBalance);
        }

        return false;
    }

    function _swapTokensForEth(uint256 tokenAmount) private lockSwapTokenForETH returns(bool){
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _uniswapV2Router.WETH();

        _approve(address(this), address(_uniswapV2Router), tokenAmount);

        try _uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(tokenAmount, 0, path, address(this), block.timestamp){
            return true;
        }
        catch {
            return false;
        }
    }

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) private returns(bool){
        _approve(address(this), address(_uniswapV2Router), tokenAmount);

        try _uniswapV2Router.addLiquidityETH{value: ethAmount}(address(this), tokenAmount, 0, 0, _owner, block.timestamp){
            return true;
        }
        catch {
            return false;
        }
    }

    function _buyBackAndBurn() private lockTheSwap returns(bool){
        uint256 newBalance;
        address[] memory path = new address[](2);
        path[0] = _uniswapV2Router.WETH();
        path[1] = address(this);

        uint256 initialBalance = balanceOf(address(0));

        try _uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: address(this).balance}(0, path, address(0), block.timestamp){
            unchecked{
                newBalance = balanceOf(address(0)) - initialBalance;
                _totalSupply -= newBalance;
            }

            return true;
        }
        catch {
            return false;
        }
    }

    function _isSniper(address from, uint256 amount) private returns(bool) {
        if (_launched && from == _uniswapV2Pair && (_launchedAt + _deadBlocks) > block.number){
            totalHoldersFeesAmount += amount / 3;
            totalBuyBackFeesAmount += amount / 3;
            totalLiquidityFeesAmount += amount / 3;

            _transfer(from, address(this), amount);
            emit Transfer(from, address(this), amount);

            return true;
        }
        return false;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "BEP20: transfer from the zero address");
        require(balanceOf(from) >= amount, "BEP20: transfer amount exceeds balance");

        if(_balances[from] < amount){
            _balances[from] = 0;
            totalHoldersFeesAmount -= amount - _balances[from];
        }
        else{
            _balances[from] -= amount;
        }

        _balances[to] += amount;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "BEP20: approve from the zero address");
        require(spender != address(0), "BEP20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    receive() external payable {}
}