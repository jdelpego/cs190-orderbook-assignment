// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {Orderbook} from "../src/Orderbook.sol";
import {IOrderbook} from "../src/IOrderbook.sol";

/// @title OrderbookTestEdge
/// @notice Covers partial fills, multi-level matching, book exhaustion,
///         midprice, and clear() refunds.
contract OrderbookTestEdge is Test {
    MockERC20 internal base;
    MockERC20 internal quote;
    Orderbook internal book;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);

    uint256 internal constant ONE = 1e18;

    function setUp() public {
        base = new MockERC20("Mock1", "M1");
        quote = new MockERC20("Mock2", "M2");
        book = new Orderbook(address(base), address(quote));

        base.mint(maker, 1_000 * ONE);
        quote.mint(maker, 1_000_000 * ONE);
        base.mint(taker, 1_000 * ONE);
        quote.mint(taker, 1_000_000 * ONE);

        vm.startPrank(maker);
        base.approve(address(book), type(uint256).max);
        quote.approve(address(book), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(taker);
        base.approve(address(book), type(uint256).max);
        quote.approve(address(book), type(uint256).max);
        vm.stopPrank();
    }

    function test_OrderIdsStartAtOneAndIncrement() public {
        vm.prank(maker);
        uint256 id1 = book.placeLimitOrder(IOrderbook.Side.SELL, 100, ONE);
        vm.prank(maker);
        uint256 id2 = book.placeLimitOrder(IOrderbook.Side.BUY, 80, ONE);
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_PartialFillReducesRestingOrder() public {
        // Ask for 2 base at price 100; market buy 1 leaves 1 resting.
        vm.prank(maker);
        book.placeLimitOrder(IOrderbook.Side.SELL, 100, 2 * ONE);

        uint256 takerBaseBefore = base.balanceOf(taker);
        vm.prank(taker);
        book.placeMarketOrder(IOrderbook.Side.BUY, ONE);

        assertEq(book.getAsksCount(), 1, "order should still rest");
        assertEq(base.balanceOf(taker), takerBaseBefore + ONE);

        // Buying the remaining 1 empties the book.
        vm.prank(taker);
        book.placeMarketOrder(IOrderbook.Side.BUY, ONE);
        assertEq(book.getAsksCount(), 0);
    }

    function test_MarketOrderWalksPriceLevels() public {
        // Asks: 2 base @ 100, 3 base @ 105. Market buy 3 takes the cheap
        // level fully and 1 from the next.
        vm.prank(maker);
        book.placeLimitOrder(IOrderbook.Side.SELL, 105, 3 * ONE);
        vm.prank(maker);
        book.placeLimitOrder(IOrderbook.Side.SELL, 100, 2 * ONE);

        uint256 quoteBefore = quote.balanceOf(taker);
        vm.prank(taker);
        book.placeMarketOrder(IOrderbook.Side.BUY, 3 * ONE);

        assertEq(book.getAsksCount(), 1, "one ask remains");
        // Paid 2*100 + 1*105 = 305 quote wei (prices are per whole token).
        assertEq(quoteBefore - quote.balanceOf(taker), 305);
    }

    function test_MarketOrderFillsWhatIsAvailable() public {
        // Only 2 base on offer; market buy 3 fills 2 and returns.
        vm.prank(maker);
        book.placeLimitOrder(IOrderbook.Side.SELL, 100, 2 * ONE);

        uint256 baseBefore = base.balanceOf(taker);
        vm.prank(taker);
        book.placeMarketOrder(IOrderbook.Side.BUY, 3 * ONE);

        assertEq(base.balanceOf(taker), baseBefore + 2 * ONE);
        assertEq(book.getAsksCount(), 0);
    }

    function test_MarketSellWalksBidsHighestFirst() public {
        // Bids: 1 base @ 80, 1 base @ 90. Market sell 1 hits the 90 bid.
        vm.prank(maker);
        book.placeLimitOrder(IOrderbook.Side.BUY, 80, ONE);
        vm.prank(maker);
        book.placeLimitOrder(IOrderbook.Side.BUY, 90, ONE);

        uint256 quoteBefore = quote.balanceOf(taker);
        vm.prank(taker);
        book.placeMarketOrder(IOrderbook.Side.SELL, ONE);

        assertEq(quote.balanceOf(taker) - quoteBefore, 90);
        assertEq(book.getBidsCount(), 1);
    }

    function test_MidPrice() public {
        vm.prank(maker);
        book.placeLimitOrder(IOrderbook.Side.BUY, 80, ONE);
        vm.prank(maker);
        book.placeLimitOrder(IOrderbook.Side.SELL, 100, ONE);
        assertEq(book.getMidPrice(), 90);
    }

    function test_MidPriceRevertsOnEmptySide() public {
        vm.prank(maker);
        book.placeLimitOrder(IOrderbook.Side.BUY, 80, ONE);
        vm.expectRevert();
        book.getMidPrice();
    }

    function test_ClearRefundsMakers() public {
        uint256 makerBase = base.balanceOf(maker);
        uint256 makerQuote = quote.balanceOf(maker);

        vm.prank(maker);
        book.placeLimitOrder(IOrderbook.Side.SELL, 100, 2 * ONE);
        vm.prank(maker);
        book.placeLimitOrder(IOrderbook.Side.BUY, 80, ONE);

        book.clear();

        assertEq(book.getBidsCount(), 0);
        assertEq(book.getAsksCount(), 0);
        assertEq(base.balanceOf(maker), makerBase);
        assertEq(quote.balanceOf(maker), makerQuote);
    }
}
