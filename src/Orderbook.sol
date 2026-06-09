// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IOrderbook} from "./IOrderbook.sol";

/// @dev Minimal ERC20 surface the orderbook needs. The provided `MockERC20`
///      implements all of these methods (plus `mint`).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @title Orderbook
/// @notice Simple on-chain limit orderbook trading a base ERC20 against a
///         quote ERC20. Limit orders escrow funds in the contract (quote for
///         bids, base for asks) and rest until a market order matches them.
contract Orderbook is IOrderbook {
    IERC20 public immutable baseToken;
    IERC20 public immutable quoteToken;

    uint256 private constant ONE = 1e18;

    struct Order {
        uint256 id;
        address maker;
        uint256 price; // quote wei per one whole (1e18 wei) base token
        uint256 amount; // remaining base wei
    }

    Order[] private bids;
    Order[] private asks;
    uint256 private nextOrderId = 1;

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        Side side,
        uint256 price,
        uint256 amount
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed taker,
        uint256 fillAmount,
        uint256 fillPrice
    );
    event OrderCleared();

    constructor(address _baseToken, address _quoteToken) {
        require(_baseToken != address(0), "baseToken=0");
        require(_quoteToken != address(0), "quoteToken=0");
        require(_baseToken != _quoteToken, "base==quote");
        baseToken = IERC20(_baseToken);
        quoteToken = IERC20(_quoteToken);
    }

    function getBaseToken() external view returns (address) {
        return address(baseToken);
    }

    function getQuoteToken() external view returns (address) {
        return address(quoteToken);
    }

    function placeLimitOrder(Side side, uint256 price, uint256 amount) external returns (uint256) {
        require(price > 0, "price=0");
        require(amount > 0, "amount=0");

        uint256 orderId = nextOrderId++;
        if (side == Side.BUY) {
            // Lock the quote needed to pay for `amount` base at `price`.
            require(quoteToken.transferFrom(msg.sender, address(this), _quoteAmount(amount, price)), "quote transfer failed");
            bids.push(Order(orderId, msg.sender, price, amount));
        } else {
            // Lock the base being sold.
            require(baseToken.transferFrom(msg.sender, address(this), amount), "base transfer failed");
            asks.push(Order(orderId, msg.sender, price, amount));
        }

        emit OrderPlaced(orderId, msg.sender, side, price, amount);
        return orderId;
    }

    function placeMarketOrder(Side side, uint256 amount) external {
        uint256 remaining = amount;
        if (side == Side.BUY) {
            // Walk the asks from lowest price up; fill whatever is available.
            while (remaining > 0 && asks.length > 0) {
                uint256 i = _bestAskIndex();
                Order storage o = asks[i];
                uint256 fill = remaining < o.amount ? remaining : o.amount;

                require(quoteToken.transferFrom(msg.sender, o.maker, _quoteAmount(fill, o.price)), "quote transfer failed");
                require(baseToken.transfer(msg.sender, fill), "base transfer failed");

                emit OrderFilled(o.id, msg.sender, fill, o.price);
                o.amount -= fill;
                remaining -= fill;
                if (o.amount == 0) _removeOrder(asks, i);
            }
        } else {
            // Walk the bids from highest price down; fill whatever is available.
            while (remaining > 0 && bids.length > 0) {
                uint256 i = _bestBidIndex();
                Order storage o = bids[i];
                uint256 fill = remaining < o.amount ? remaining : o.amount;

                require(baseToken.transferFrom(msg.sender, o.maker, fill), "base transfer failed");
                require(quoteToken.transfer(msg.sender, _quoteAmount(fill, o.price)), "quote transfer failed");

                emit OrderFilled(o.id, msg.sender, fill, o.price);
                o.amount -= fill;
                remaining -= fill;
                if (o.amount == 0) _removeOrder(bids, i);
            }
        }
    }

    function clear() external {
        for (uint256 i = 0; i < bids.length; i++) {
            require(quoteToken.transfer(bids[i].maker, _quoteAmount(bids[i].amount, bids[i].price)), "quote refund failed");
        }
        for (uint256 i = 0; i < asks.length; i++) {
            require(baseToken.transfer(asks[i].maker, asks[i].amount), "base refund failed");
        }
        delete bids;
        delete asks;
        emit OrderCleared();
    }

    function getBidsCount() external view returns (uint256) {
        return bids.length;
    }

    function getAsksCount() external view returns (uint256) {
        return asks.length;
    }

    function getMidPrice() external view returns (uint256) {
        require(bids.length > 0, "no bids");
        require(asks.length > 0, "no asks");
        return (bids[_bestBidIndex()].price + asks[_bestAskIndex()].price) / 2;
    }

    /// @dev Quote wei owed for `amount` base wei at `price` quote per 1e18 base wei.
    function _quoteAmount(uint256 amount, uint256 price) private pure returns (uint256) {
        return amount * price / ONE;
    }

    /// @dev Index of the lowest-priced ask; ties broken by lowest order id.
    function _bestAskIndex() private view returns (uint256 best) {
        for (uint256 i = 1; i < asks.length; i++) {
            if (asks[i].price < asks[best].price || (asks[i].price == asks[best].price && asks[i].id < asks[best].id)) {
                best = i;
            }
        }
    }

    /// @dev Index of the highest-priced bid; ties broken by lowest order id.
    function _bestBidIndex() private view returns (uint256 best) {
        for (uint256 i = 1; i < bids.length; i++) {
            if (bids[i].price > bids[best].price || (bids[i].price == bids[best].price && bids[i].id < bids[best].id)) {
                best = i;
            }
        }
    }

    /// @dev Swap-and-pop removal; order within the array does not matter
    ///      because matching always scans for the best price.
    function _removeOrder(Order[] storage orders, uint256 i) private {
        orders[i] = orders[orders.length - 1];
        orders.pop();
    }
}
